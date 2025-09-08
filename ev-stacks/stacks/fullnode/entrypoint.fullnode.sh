#!/bin/sh
# Fail on any error
set -e

# Fail on any error in a pipeline
set -o pipefail

# Fail when using undeclared variables
set -u

# Source shared logging utility
. /usr/local/lib/logging.sh

log "INIT" "Starting EVM Fullnode initialization"
sleep 5

# Function to extract --home value from arguments
get_home_dir() {
	home_dir="$HOME/.evm-single"

	# Parse arguments to find --home
	while [ $# -gt 0 ]; do
		case "$1" in
		--home)
			if [ -n "$2" ]; then
				home_dir="$2"
				break
			fi
			;;
		--home=*)
			home_dir="${1#--home=}"
			break
			;;
		esac
		shift
	done

	echo "${home_dir}"
}

# Get the home directory (either from --home flag or default)
CONFIG_HOME=$(get_home_dir "$@")
log "INFO" "Using config home directory: $CONFIG_HOME"

if [ ! -f "${CONFIG_HOME}/config/node_key.json" ]; then
	log "INFO" "Node key not found. Initializing new fullnode configuration"

	# Build init flags array
	init_flags="--home=${CONFIG_HOME}"

	INIT_COMMAND="evm-single init ${init_flags}"
	log "INIT" "Initializing fullnode with command: ${INIT_COMMAND}"
	${INIT_COMMAND}
	log "SUCCESS" "Fullnode initialization completed"
else
	log "INFO" "Node key already exists. Skipping initialization"
fi

# Importing genesis
cp -pr /volumes/sequencer_export/genesis.json "${CONFIG_HOME}/config/genesis.json"
log "SUCCESS" "genesis.json copied to: ${CONFIG_HOME}/config/genesis.json"

# Importing DA auth token
log "INFO" "Checking for DA authentication token"
if [ -n "${DA_AUTH_TOKEN_PATH:-}" ]; then
	if [ -f "${DA_AUTH_TOKEN_PATH}" ]; then
		DA_AUTH_TOKEN=$(cat "${DA_AUTH_TOKEN_PATH}")
		log "SUCCESS" "DA auth token loaded from: ${DA_AUTH_TOKEN_PATH}"
	else
		log "WARNING" "DA_AUTH_TOKEN_PATH specified but file not found: ${DA_AUTH_TOKEN_PATH}"
	fi
else
	log "INFO" "No DA_AUTH_TOKEN_PATH specified"
fi

# Importing JWT token
log "INFO" "Checking for JWT secret"
if [ -n "${EVM_JWT_PATH:-}" ]; then
	if [ -f "${EVM_JWT_PATH}" ]; then
		EVM_JWT_SECRET=$(cat "${EVM_JWT_PATH}")
		log "SUCCESS" "JWT secret loaded from: ${EVM_JWT_PATH}"
	else
		log "WARNING" "EVM_JWT_PATH specified but file not found: ${EVM_JWT_PATH}"
	fi
else
	log "INFO" "No EVM_JWT_PATH specified"
fi

# Get sequencer node id
log "NETWORK" "Fetching sequencer P2P information from single-sequencer:7331"
RESPONSE=$(curl -sX POST \
	-H "Content-Type: application/json" \
	-H "Connect-Protocol-Version: 1" \
	-d "{}" \
	http://single-sequencer:7331/evnode.v1.P2PService/GetNetInfo)

if [ $? -eq 0 ] && [ -n "${RESPONSE}" ]; then
	log "SUCCESS" "Received response from sequencer"
	SEQUENCER_P2P_INFO=$(echo "${RESPONSE}" | grep -o '"/ip4/[^"]*"' | grep -v '127\.0\.0\.1' | sed 's/"//g')

	# Validate the format of SEQUENCER_P2P_INFO
	if ! echo "${SEQUENCER_P2P_INFO}" | grep -E '^/ip4/[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/tcp/[0-9]+/p2p/[A-Za-z0-9]+$' >/dev/null; then
		log "ERROR" "SEQUENCER_P2P_INFO is not in the expected format. Got: ${SEQUENCER_P2P_INFO}"
		exit 1
	else
		log "SUCCESS" "SEQUENCER_P2P_INFO is valid: ${SEQUENCER_P2P_INFO}"
	fi
else
	log "ERROR" "Failed to fetch sequencer P2P information"
	exit 1
fi

# Auto-retrieve genesis hash if not provided
log "INFO" "Checking genesis hash configuration"
if [ -z "${EVM_GENESIS_HASH:-}" ] && [ -n "${EVM_ETH_URL:-}" ]; then
	log "INFO" "EVM_GENESIS_HASH not provided, attempting to retrieve from ev-reth-sequencer at: ${EVM_ETH_URL}"

	# Wait for ev-reth-sequencer to be ready (max 60 seconds)
	retry_count=0
	max_retries=12
	while [ "${retry_count}" -lt "${max_retries}" ]; do
		if curl -s --connect-timeout 5 "${EVM_ETH_URL}" >/dev/null 2>&1; then
			log "SUCCESS" "Ev-reth-sequencer is ready, retrieving genesis hash..."
			break
		fi
		log "INFO" "Waiting for ev-reth-sequencer to be ready... (attempt $((retry_count + 1))/${max_retries})"
		sleep 5
		retry_count=$((retry_count + 1))
	done

	if [ "${retry_count}" -eq "${max_retries}" ]; then
		log "WARNING" "Could not connect to ev-reth-sequencer at ${EVM_ETH_URL} after ${max_retries} attempts"
		log "WARNING" "Proceeding without auto-retrieved genesis hash..."
	else
		# Retrieve genesis block hash using curl and shell parsing
		log "NETWORK" "Fetching genesis block from ev-reth-sequencer..."
		genesis_response=$(curl -s -X POST -H "Content-Type: application/json" \
			--data '{"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x0", false],"id":1}' \
			"${EVM_ETH_URL}" 2>/dev/null)

		if [ $? -eq 0 ] && [ -n "${genesis_response}" ]; then
			# Extract hash using shell parameter expansion and sed
			# Look for "hash":"0x..." pattern and extract the hash value
			genesis_hash=$(echo "${genesis_response}" | sed -n 's/.*"hash":"\([^"]*\)".*/\1/p')

			if [ -n "${genesis_hash}" ] && [ "${genesis_hash#0x}" != "${genesis_hash}" ]; then
				EVM_GENESIS_HASH="${genesis_hash}"
				log "SUCCESS" "Successfully retrieved genesis hash: ${EVM_GENESIS_HASH}"
			else
				log "WARNING" "Could not parse genesis hash from response"
				log "DEBUG" "Response: ${genesis_response}"
			fi
		else
			log "WARNING" "Failed to retrieve genesis block from ev-reth-sequencer"
		fi
	fi
elif [ -n "${EVM_GENESIS_HASH}" ]; then
	log "INFO" "Using provided genesis hash: ${EVM_GENESIS_HASH}"
else
	log "INFO" "No genesis hash configuration provided"
fi

# Build start flags array
log "INFO" "Building startup configuration flags"
default_flags=""

# Add required flags if environment variables are set
if [ -n "${EVM_JWT_SECRET:-}" ]; then
	default_flags="${default_flags} --evm.jwt-secret ${EVM_JWT_SECRET}"
	log "DEBUG" "Added JWT secret flag"
fi

if [ -n "${EVM_GENESIS_HASH:-}" ]; then
	default_flags="${default_flags} --evm.genesis-hash ${EVM_GENESIS_HASH}"
	log "DEBUG" "Added genesis hash flag"
fi

if [ -n "${EVM_ENGINE_URL:-}" ]; then
	default_flags="${default_flags} --evm.engine-url ${EVM_ENGINE_URL}"
	log "DEBUG" "Added engine URL flag: ${EVM_ENGINE_URL}"
fi

if [ -n "${EVM_ETH_URL:-}" ]; then
	default_flags="${default_flags} --evm.eth-url ${EVM_ETH_URL}"
	log "DEBUG" "Added ETH URL flag: ${EVM_ETH_URL}"
fi

log "INFO" "Configuring Data Availability (DA) settings"
if [ -n "${SEQUENCER_P2P_INFO:-}" ]; then
	default_flags="${default_flags} --rollkit.p2p.peers ${SEQUENCER_P2P_INFO}"
	log "DEBUG" "Added p2p peer flag: ${SEQUENCER_P2P_INFO}"
fi

# Conditionally add DA-related flags
log "INFO" "Configuring Data Availability (DA) settings"
if [ -n "${DA_ADDRESS:-}" ]; then
	default_flags="${default_flags} --rollkit.da.address ${DA_ADDRESS}"
	log "DEBUG" "Added DA address flag: ${DA_ADDRESS}"
fi

if [ -n "${DA_AUTH_TOKEN:-}" ]; then
	default_flags="${default_flags} --rollkit.da.auth_token ${DA_AUTH_TOKEN}"
	log "DEBUG" "Added DA auth token flag"
fi

if [ -n "${DA_DATA_NAMESPACE:-}" ]; then
	default_flags="${default_flags} --rollkit.da.data_namespace ${DA_DATA_NAMESPACE}"
	log "DEBUG" "Added DA data namespace flag: ${DA_DATA_NAMESPACE}"
fi

if [ -n "${DA_HEADER_NAMESPACE:-}" ]; then
	default_flags="${default_flags} --rollkit.da.namespace ${DA_HEADER_NAMESPACE}"
	log "DEBUG" "Added DA header namespace flag: ${DA_HEADER_NAMESPACE}"
fi

if [ -n "${DA_START_HEIGHT:-}" ]; then
	default_flags="${default_flags} --rollkit.da.start_height ${DA_START_HEIGHT}"
	log "DEBUG" "Added DA start height flag: ${DA_START_HEIGHT}"
fi

default_flags="${default_flags} --home=${CONFIG_HOME}"

log "SUCCESS" "Configuration flags prepared successfully"

# If no arguments passed, show help
if [ $# -eq 0 ]; then
	log "INFO" "No arguments provided, showing help"
	exec evm-single
fi

# If first argument is "start", apply default flags
if [ "$1" = "start" ]; then
	shift
	log "INIT" "Starting EVM fullnode with command: evm-single start ${default_flags} $*"
	log "INFO" "Fullnode is now starting up..."
	eval "exec evm-single start ${default_flags} \"\$@\""
else
	# For any other command/subcommand, pass through directly
	log "INFO" "Executing command: evm-single $*"
	exec evm-single "$@"
fi
