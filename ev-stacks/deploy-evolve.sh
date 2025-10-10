#!/bin/bash

# Evolve One-Liner Deployment Script
# This script provides a complete deployment framework for Evolve sequencer nodes and Celestia DA
# Usage: bash -c "bash -i <(curl -s https://raw.githubusercontent.com/evstack/ev-toolbox/refs/heads/main/ev-stacks/deploy-evolve.sh)"
set -euo pipefail

# Script metadata
readonly SCRIPT_VERSION="1.7.0"
readonly SCRIPT_NAME="deploy-evolve"
readonly REPO_URL="https://github.com/evstack/ev-toolbox"
readonly GITHUB_RAW_BASE="https://raw.githubusercontent.com/evstack/ev-toolbox"
readonly BASE_URL="$GITHUB_RAW_BASE/refs/heads/main/ev-stacks"
readonly DEPLOYMENT_DIR="$HOME/evolve-deployment"

# File and directory constants
readonly ENV_FILE=".env"
readonly DOCKER_COMPOSE_FILE="docker-compose.yml"
readonly DOCKER_COMPOSE_DA_CELESTIA_FILE="docker-compose.da.celestia.yml"
readonly DOCKER_COMPOSE_DA_LOCAL_FILE="docker-compose.da.local.yml"
readonly GENESIS_FILE="genesis.json"
readonly SEQUENCER_ENTRYPOINT="entrypoint.sequencer.sh"
readonly FULLNODE_ENTRYPOINT="entrypoint.fullnode.sh"
readonly APPD_ENTRYPOINT="entrypoint.appd.sh"
readonly DA_ENTRYPOINT="entrypoint.da.sh"
readonly SEQUENCER_DOCKERFILE="single-sequencer.Dockerfile"
readonly CELESTIA_DOCKERFILE="celestia-app.Dockerfile"
readonly LOGGING_LIB="logging.sh"

# Directory structure constants
readonly STACKS_DIR="stacks"
readonly LIB_DIR="lib"
readonly SINGLE_SEQUENCER_DIR="single-sequencer"
readonly FULLNODE_DIR="fullnode"
readonly ETH_FAUCET_DIR="eth-faucet"
readonly ETH_EXPLORER_DIR="eth-explorer"
readonly ETH_INDEXER_DIR="eth-indexer"
readonly DA_CELESTIA_DIR="da-celestia"
readonly DA_LOCAL_DIR="da-local"

# Container and service name patterns
readonly SEQUENCER_CONTAINERS="(sequencer|reth-sequencer|jwt-init)"
readonly CELESTIA_CONTAINERS="(celestia-app|celestia-node|da-permission-fix)"
readonly SHARED_VOLUME_NAME="celestia-node-export"

# Configuration constants
readonly DEFAULT_BALANCE="0x4a47e3c12448f4ad000000"
readonly PASSPHRASE_LENGTH=32
readonly NAMESPACE_LENGTH=58
readonly ETH_ADDRESS_PATTERN="^0x[a-fA-F0-9]{40}$"

# Network and service endpoints
readonly SEQUENCER_PROMETHEUS_PORT="9000"
readonly SEQUENCER_NODE_METRICS_PORT="26660"
readonly FULLNODE_RPC_PORT="8545"
readonly FULLNODE_PROMETHEUS_PORT="9002"
readonly FULLNODE_NODE_RPC_PORT="7331"
readonly FULLNODE_NODE_METRICS_PORT="26662"
readonly ETH_FAUCET_PORT="8081"

# Color codes for output
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly NC='\033[0m' # No Color

# Global variables
VERBOSE=false
DRY_RUN=false
FORCE_INSTALL=false
LOG_FILE=""
CLEANUP_ON_EXIT=true
DEPLOY_DA_CELESTIA=false
DEPLOY_DA_LOCAL=false
SELECTED_DA=""
SELECTED_SEQUENCER=""
DEPLOY_FULLNODE=false
DEPLOY_ETH_FAUCET=false
DEPLOY_ETH_EXPLORER=false
DEPLOY_ETH_INDEXER=false

# Enhanced logging function that extends the shared one with colors and file logging
log() {
	local level="$1"
	shift
	local message="$*"
	local timestamp=$(date '+%Y-%m-%d %H:%M:%S')

	# Handle DEBUG level visibility
	if [[ "$level" == "DEBUG" && $VERBOSE != "true" ]]; then
		return 0
	fi

	case "$level" in
	"INFO")
		echo -e "ℹ️  [$timestamp] ${GREEN}INFO${NC}: $message" >&2
		;;
	"SUCCESS")
		echo -e "✅ [$timestamp] ${GREEN}SUCCESS${NC}: $message" >&2
		;;
	"WARN"|"WARNING")
		echo -e "⚠️  [$timestamp] ${YELLOW}WARN${NC}: $message" >&2
		;;
	"ERROR")
		echo -e "❌ [$timestamp] ${RED}ERROR${NC}: $message" >&2
		;;
	"DEBUG")
		echo -e "🔍 [$timestamp] ${BLUE}DEBUG${NC}: $message" >&2
		;;
	"DOWNLOAD")
		echo -e "⬇️  [$timestamp] ${BLUE}DOWNLOAD${NC}: $message" >&2
		;;
	"INIT")
		echo -e "🚀 [$timestamp] ${GREEN}INIT${NC}: $message" >&2
		;;
	"CONFIG")
		echo -e "⚙️  [$timestamp] ${YELLOW}CONFIG${NC}: $message" >&2
		;;
	"DEPLOY")
		echo -e "🚢 [$timestamp] ${GREEN}DEPLOY${NC}: $message" >&2
		;;
	"NETWORK")
		echo -e "🌐 [$timestamp] ${BLUE}NETWORK${NC}: $message" >&2
		;;
	*)
		echo -e "📝 [$timestamp] $level: $message" >&2
		;;
	esac

	# Log to file if specified
	if [[ -n $LOG_FILE ]]; then
		echo "[$timestamp] [$level] $message" >>"$LOG_FILE"
	fi
}

# Error handling
error_exit() {
	log "ERROR" "$1"
	exit "${2:-1}"
}

# Helper function to update environment variables using awk
update_env_var() {
	local env_file="$1"
	local var_name="$2"
	local var_value="$3"
	local temp_file="${env_file}.tmp"

	if [[ ! -f "$env_file" ]]; then
		error_exit "Environment file not found: $env_file"
	fi

	# Use awk to update or add the environment variable
	awk -v var="$var_name" -v val="$var_value" '
	BEGIN { found = 0 }
	$0 ~ "^" var "=" {
		print var "=\"" val "\""
		found = 1
		next
	}
	{ print }
	END {
		if (!found) print var "=\"" val "\""
	}
	' "$env_file" > "$temp_file" || error_exit "Failed to update $var_name in $env_file"

	mv "$temp_file" "$env_file" || error_exit "Failed to replace $env_file"
	log "DEBUG" "Updated $var_name in $env_file"
}

# Helper function to update JSON fields using awk
update_json_field() {
	local json_file="$1"
	local field_pattern="$2"
	local new_value="$3"
	local temp_file="${json_file}.tmp"

	if [[ ! -f "$json_file" ]]; then
		error_exit "JSON file not found: $json_file"
	fi

	# Use awk to update the JSON field
	awk -v pattern="$field_pattern" -v value="$new_value" '
	$0 ~ pattern {
		gsub(pattern "[^,}]*", pattern " " value)
	}
	{ print }
	' "$json_file" > "$temp_file" || error_exit "Failed to update JSON field in $json_file"

	mv "$temp_file" "$json_file" || error_exit "Failed to replace $json_file"
	log "DEBUG" "Updated JSON field in $json_file"
}

# Cleanup function
cleanup() {
	local exit_code=$?
	log "DEBUG" "Cleanup function called with exit code: $exit_code"

	if [[ $CLEANUP_ON_EXIT == "true" && $exit_code -ne 0 ]]; then
		log "INFO" "Cleaning up due to error..."

		# Stop any running containers
		if command -v docker compose >/dev/null 2>&1; then
			if [[ -f "$DEPLOYMENT_DIR/stacks/single-sequencer/docker-compose.yml" ]]; then
				log "DEBUG" "Stopping single-sequencer Docker containers..."
				cd "$DEPLOYMENT_DIR/stacks/single-sequencer" && docker compose down --remove-orphans 2>/dev/null || true
			fi

			if [[ -f "$DEPLOYMENT_DIR/stacks/da-celestia/docker-compose.yml" ]]; then
				log "DEBUG" "Stopping da-celestia Docker containers..."
				cd "$DEPLOYMENT_DIR/stacks/da-celestia" && docker compose down --remove-orphans 2>/dev/null || true
			fi
		fi

		# Remove deployment directory if it was created by this script
		if [[ -d $DEPLOYMENT_DIR && -f "$DEPLOYMENT_DIR/.created_by_script" ]]; then
			log "DEBUG" "Removing deployment directory..."
			rm -rf "$DEPLOYMENT_DIR"
		fi
	fi

	exit $exit_code
}

# Set up signal handlers
trap cleanup EXIT
trap 'error_exit "Script interrupted by user" 130' INT
trap 'error_exit "Script terminated" 143' TERM

# Interactive sequencer topology selection
select_sequencer_topology() {
	log "CONFIG" "Selecting sequencer topology..."

	echo ""
	echo "🔗 Available sequencer topologies:"
	echo "  1) single-sequencer - Single node sequencer setup"
	echo ""
	echo "ℹ️  Note: Additional sequencer topologies may be added in future releases"
	echo ""

	while true; do
		echo -n "Please select a sequencer topology (1): "
		read -r choice

		case $choice in
		1)
			SELECTED_SEQUENCER="single-sequencer"
			log "SUCCESS" "Selected sequencer topology: Single Sequencer"
			break
			;;
		*)
			echo "❌ Invalid choice. Please enter 1."
			;;
		esac
	done

	echo ""
}

# Interactive fullnode selection
select_fullnode_deployment() {
	log "CONFIG" "Selecting fullnode deployment option..."

	echo ""
	echo "🔗 Do you want to deploy a fullnode stack?"
	echo "  1) Yes - Deploy fullnode stack alongside sequencer"
	echo "  2) No - Deploy sequencer only"
	echo ""
	echo "ℹ️  Note: Fullnode provides additional network connectivity and redundancy"
	echo ""

	while true; do
		echo -n "Please select an option (1-2): "
		read -r choice

		case $choice in
		1)
			DEPLOY_FULLNODE=true
			log "SUCCESS" "Selected: Deploy fullnode stack"
			break
			;;
		2)
			DEPLOY_FULLNODE=false
			log "SUCCESS" "Selected: Sequencer only"
			break
			;;
		*)
			echo "❌ Invalid choice. Please enter 1 or 2."
			;;
		esac
	done

	echo ""
}

# Interactive eth-faucet selection
select_eth_faucet_deployment() {
	log "CONFIG" "Selecting eth-faucet deployment option..."

	echo ""
	echo "💰 Do you want to deploy an eth-faucet service?"
	echo "  1) Yes - Deploy eth-faucet for easy token distribution"
	echo "  2) No - Skip eth-faucet deployment"
	echo ""
	echo "ℹ️  Note: Eth-faucet provides a web interface for distributing test tokens"
	echo ""

	while true; do
		echo -n "Please select an option (1-2): "
		read -r choice

		case $choice in
		1)
			DEPLOY_ETH_FAUCET=true
			log "SUCCESS" "Selected: Deploy eth-faucet service"
			break
			;;
		2)
			DEPLOY_ETH_FAUCET=false
			log "SUCCESS" "Selected: Skip eth-faucet"
			break
			;;
		*)
			echo "❌ Invalid choice. Please enter 1 or 2."
			;;
		esac
	done

	echo ""
}

# Show SECRET_KEY_BASE disclaimer for eth-explorer
show_eth_explorer_disclaimer() {
	echo ""
	echo "🔐 =========================================="
	echo "🔐 IMPORTANT SECURITY NOTICE"
	echo "🔐 =========================================="
	echo ""
	echo "⚠️  The eth-explorer (Blockscout) deployment includes a default SECRET_KEY_BASE"
	echo "   for demonstration purposes. For production or secure environments, you"
	echo "   MUST generate your own SECRET_KEY_BASE."
	echo ""
	echo "📖 As documented in the Blockscout manual deployment guide:"
	echo "   https://docs.blockscout.com/setup/deployment/manual-deployment-guide"
	echo ""
	echo "🔧 To generate a new SECRET_KEY_BASE:"
	echo "   1. Use: openssl rand -base64 64"
	echo "   2. Replace the SECRET_KEY_BASE value in:"
	echo "      $DEPLOYMENT_DIR/stacks/eth-explorer/.env"
	echo ""
	echo "🚨 Using the default SECRET_KEY_BASE in production environments"
	echo "   poses a significant security risk!"
	echo ""
	echo "Press any key to acknowledge and continue..."
	read -n 1 -s
	echo ""
	echo "✅ Disclaimer acknowledged. Continuing with deployment..."
	echo ""
}

# Interactive eth-explorer selection
select_eth_explorer_deployment() {
	log "CONFIG" "Selecting eth-explorer deployment option..."

	echo ""
	echo "🔍 Do you want to deploy an eth-explorer service?"
	echo "  1) Yes - Deploy eth-explorer (Blockscout) for blockchain exploration"
	echo "  2) No - Skip eth-explorer deployment"
	echo ""
	echo "ℹ️  Note: Eth-explorer provides a web interface for exploring blockchain data"
	echo ""

	while true; do
		echo -n "Please select an option (1-2): "
		read -r choice

		case $choice in
		1)
			DEPLOY_ETH_EXPLORER=true
			log "SUCCESS" "Selected: Deploy eth-explorer service"
			# Show security disclaimer after user chooses to deploy
			show_eth_explorer_disclaimer
			break
			;;
		2)
			DEPLOY_ETH_EXPLORER=false
			log "SUCCESS" "Selected: Skip eth-explorer"
			break
			;;
		*)
			echo "❌ Invalid choice. Please enter 1 or 2."
			;;
		esac
	done

	echo ""
}

# Interactive eth-indexer selection
select_eth_indexer_deployment() {
	log "CONFIG" "Selecting eth-indexer deployment option..."

	echo ""
	echo "📊 Do you want to deploy an eth-indexer service?"
	echo "  1) Yes - Deploy eth-indexer for blockchain data indexing"
	echo "  2) No - Skip eth-indexer deployment"
	echo ""
	echo "ℹ️  Note: Eth-indexer provides advanced blockchain data indexing and analytics"
	echo ""

	while true; do
		echo -n "Please select an option (1-2): "
		read -r choice

		case $choice in
		1)
			DEPLOY_ETH_INDEXER=true
			log "SUCCESS" "Selected: Deploy eth-indexer service"
			break
			;;
		2)
			DEPLOY_ETH_INDEXER=false
			log "SUCCESS" "Selected: Skip eth-indexer"
			break
			;;
		*)
			echo "❌ Invalid choice. Please enter 1 or 2."
			;;
		esac
	done

	echo ""
}

# Interactive DA selection
select_da_layer() {
	log "CONFIG" "Selecting Data Availability layer..."

	echo ""
	echo "🌌 Available Data Availability (DA) layers:"
	echo "  1) da-local - Local DA for development and testing"
	echo "  2) da-celestia - Celestia modular DA network (mocha-4)"
	echo ""

	while true; do
		echo -n "Please select a DA layer (1-2): "
		read -r choice

		case $choice in
		1)
			SELECTED_DA="da-local"
			DEPLOY_DA_LOCAL=true
			log "SUCCESS" "Selected DA layer: Local DA"
			break
			;;
		2)
			SELECTED_DA="da-celestia"
			DEPLOY_DA_CELESTIA=true
			log "SUCCESS" "Selected DA layer: Celestia (mocha-4)"
			break
			;;
		*)
			echo "❌ Invalid choice. Please enter 1 or 2."
			;;
		esac
	done

	echo ""
}

# Download deployment files for single-sequencer
download_sequencer_files() {
	log "DOWNLOAD" "Downloading single-sequencer deployment files..."

	# Create deployment directory and single-sequencer subfolder
	mkdir -p "$DEPLOYMENT_DIR/stacks/single-sequencer" || error_exit "Failed to create single-sequencer directory"

	cd "$DEPLOYMENT_DIR/stacks/single-sequencer" || error_exit "Failed to change to single-sequencer directory"

	# Choose the appropriate docker-compose file based on DA selection
	local docker_compose_file
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		docker_compose_file="stacks/single-sequencer/docker-compose.da.celestia.yml"
		log "CONFIG" "Using DA Celestia integrated docker-compose file"
	elif [[ $DEPLOY_DA_LOCAL == "true" ]]; then
		docker_compose_file="stacks/single-sequencer/docker-compose.da.local.yml"
		log "CONFIG" "Using DA Local integrated docker-compose file"
	else
		docker_compose_file="stacks/single-sequencer/docker-compose.yml"
		log "CONFIG" "Using standalone docker-compose file"
	fi

	local files=(
		"stacks/single-sequencer/.env"
		"$docker_compose_file"
		"stacks/single-sequencer/entrypoint.sequencer.sh"
		"stacks/single-sequencer/genesis.json"
	)


	for file in "${files[@]}"; do
		log "DEBUG" "Downloading $file..."
		local filename=$(basename "$file")
		# Always save as docker-compose.yml regardless of source file name
		if [[ $filename == "docker-compose.da.celestia.yml" || $filename == "docker-compose.da.local.yml" ]]; then
			filename="docker-compose.yml"
		fi
		curl -fsSL "$BASE_URL/$file" -o "$filename" || error_exit "Failed to download $filename"
	done

	# Make entrypoint scripts executable
	chmod +x entrypoint.sequencer.sh || error_exit "Failed to make sequencer entrypoint script executable"

	log "SUCCESS" "Single-sequencer deployment files downloaded successfully"
}

# Download deployment files for fullnode
download_fullnode_files() {
	log "DOWNLOAD" "Downloading fullnode deployment files..."

	# Create fullnode subfolder
	mkdir -p "$DEPLOYMENT_DIR/stacks/fullnode" || error_exit "Failed to create fullnode directory"

	cd "$DEPLOYMENT_DIR/stacks/fullnode" || error_exit "Failed to change to fullnode directory"

	# Choose the appropriate docker-compose file based on DA selection
	local docker_compose_file
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		docker_compose_file="stacks/fullnode/docker-compose.da.celestia.yml"
		log "CONFIG" "Using DA Celestia integrated docker-compose file for fullnode"
	elif [[ $DEPLOY_DA_LOCAL == "true" ]]; then
		docker_compose_file="stacks/fullnode/docker-compose.da.local.yml"
		log "CONFIG" "Using DA Local integrated docker-compose file for fullnode"
	else
		docker_compose_file="stacks/fullnode/docker-compose.yml"
		log "CONFIG" "Using standalone docker-compose file for fullnode"
	fi

	local files=(
		"stacks/fullnode/.env"
		"$docker_compose_file"
		"stacks/fullnode/entrypoint.ev-reth.sh"
		"stacks/fullnode/entrypoint.fullnode.sh"
	)

	for file in "${files[@]}"; do
		log "DEBUG" "Downloading $file..."
		local filename=$(basename "$file")
		# Always save as docker-compose.yml regardless of source file name
		if [[ $filename == "docker-compose.da.celestia.yml" || $filename == "docker-compose.da.local.yml" ]]; then
			filename="docker-compose.yml"
		fi
		curl -fsSL "$BASE_URL/$file" -o "$filename" || error_exit "Failed to download $filename"
	done

	# Make entrypoint scripts executable
	chmod +x entrypoint.fullnode.sh entrypoint.ev-reth.sh || error_exit "Failed to make fullnode entrypoint script executable"

	log "SUCCESS" "Fullnode deployment files downloaded successfully"
}

# Download deployment files for da-celestia
download_da_celestia_files() {
	log "DOWNLOAD" "Downloading da-celestia deployment files..."

	# Create da-celestia subfolder
	mkdir -p "$DEPLOYMENT_DIR/stacks/da-celestia" || error_exit "Failed to create da-celestia directory"

	cd "$DEPLOYMENT_DIR/stacks/da-celestia" || error_exit "Failed to change to da-celestia directory"

	local files=(
		"stacks/da-celestia/.env"
		"stacks/da-celestia/celestia-app.Dockerfile"
		"stacks/da-celestia/docker-compose.yml"
		"stacks/da-celestia/entrypoint.appd.sh"
		"stacks/da-celestia/entrypoint.da.sh"
	)

	for file in "${files[@]}"; do
		log "DEBUG" "Downloading $file..."
		local filename=$(basename "$file")
		curl -fsSL "$BASE_URL/$file" -o "$filename" || error_exit "Failed to download $filename"
	done

	# Make entrypoint scripts executable
	chmod +x entrypoint.appd.sh entrypoint.da.sh || error_exit "Failed to make entrypoint scripts executable"

	log "SUCCESS" "DA-Celestia deployment files downloaded successfully"
}

# Download deployment files for da-local
download_da_local_files() {
	log "DOWNLOAD" "Downloading da-local deployment files..."

	# Create da-local subfolder
	mkdir -p "$DEPLOYMENT_DIR/stacks/da-local" || error_exit "Failed to create da-local directory"

	cd "$DEPLOYMENT_DIR/stacks/da-local" || error_exit "Failed to change to da-local directory"

	local files=(
		"stacks/da-local/.env"
		"stacks/da-local/docker-compose.yml"
	)

	for file in "${files[@]}"; do
		log "DEBUG" "Downloading $file..."
		local filename=$(basename "$file")
		curl -fsSL "$BASE_URL/$file" -o "$filename" || error_exit "Failed to download $filename"
	done

	log "SUCCESS" "DA-Local deployment files downloaded successfully"
}

# Download deployment files for eth-faucet
download_eth_faucet_files() {
	log "DOWNLOAD" "Downloading eth-faucet deployment files..."

	# Create eth-faucet subfolder
	mkdir -p "$DEPLOYMENT_DIR/stacks/eth-faucet" || error_exit "Failed to create eth-faucet directory"

	cd "$DEPLOYMENT_DIR/stacks/eth-faucet" || error_exit "Failed to change to eth-faucet directory"

	local files=(
		"stacks/eth-faucet/.env"
		"stacks/eth-faucet/docker-compose.yml"
	)

	for file in "${files[@]}"; do
		log "DEBUG" "Downloading $file..."
		local filename=$(basename "$file")
		curl -fsSL "$BASE_URL/$file" -o "$filename" || error_exit "Failed to download $filename"
	done

	log "SUCCESS" "Eth-faucet deployment files downloaded successfully"
}

# Download deployment files for eth-explorer
download_eth_explorer_files() {
	log "DOWNLOAD" "Downloading eth-explorer deployment files..."

	# Create eth-explorer subfolder
	mkdir -p "$DEPLOYMENT_DIR/stacks/eth-explorer" || error_exit "Failed to create eth-explorer directory"

	cd "$DEPLOYMENT_DIR/stacks/eth-explorer" || error_exit "Failed to change to eth-explorer directory"

	local files=(
		"stacks/eth-explorer/.env"
		"stacks/eth-explorer/docker-compose.yml"
	)

	for file in "${files[@]}"; do
		log "DEBUG" "Downloading $file..."
		local filename=$(basename "$file")
		curl -fsSL "$BASE_URL/$file" -o "$filename" || error_exit "Failed to download $filename"
	done

	log "SUCCESS" "Eth-explorer deployment files downloaded successfully"
}

# Download deployment files for eth-indexer
download_eth_indexer_files() {
	log "DOWNLOAD" "Downloading eth-indexer deployment files..."

	# Create eth-indexer subfolder
	mkdir -p "$DEPLOYMENT_DIR/stacks/eth-indexer" || error_exit "Failed to create eth-indexer directory"

	cd "$DEPLOYMENT_DIR/stacks/eth-indexer" || error_exit "Failed to change to eth-indexer directory"

	local files=(
		"stacks/eth-indexer/.env"
		"stacks/eth-indexer/docker-compose.yml"
	)

	for file in "${files[@]}"; do
		log "DEBUG" "Downloading $file..."
		local filename=$(basename "$file")
		curl -fsSL "$BASE_URL/$file" -o "$filename" || error_exit "Failed to download $filename"
	done

	log "SUCCESS" "Eth-indexer deployment files downloaded successfully"
}

# Download shared library files
download_shared_files() {
	log "DOWNLOAD" "Downloading shared library files..."

	# Create lib directory
	mkdir -p "$DEPLOYMENT_DIR/lib" || error_exit "Failed to create lib directory"

	cd "$DEPLOYMENT_DIR/lib" || error_exit "Failed to change to lib directory"

	local files=(
		"lib/logging.sh"
	)

	for file in "${files[@]}"; do
		log "DEBUG" "Downloading $file..."
		local filename=$(basename "$file")
		curl -fsSL "$BASE_URL/$file" -o "$filename" || error_exit "Failed to download $filename"
	done

	# Make shared library files executable
	chmod +x $DEPLOYMENT_DIR/lib/logging.sh || error_exit "Failed to make logging.sh executable"

	log "SUCCESS" "Shared library files downloaded successfully"
}

# Download deployment files
download_deployment_files() {
	log "INIT" "Downloading deployment files..."

	# Create main deployment directory
	mkdir -p "$DEPLOYMENT_DIR" || error_exit "Failed to create deployment directory"
	touch "$DEPLOYMENT_DIR/.created_by_script"

	# Download shared library files first
	download_shared_files

	# Download single-sequencer files
	download_sequencer_files

	# Download fullnode files if requested
	if [[ $DEPLOY_FULLNODE == "true" ]]; then
		download_fullnode_files
	fi

	# Download da-celestia files if requested
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		download_da_celestia_files
	fi

	# Download da-local files if requested
	if [[ $DEPLOY_DA_LOCAL == "true" ]]; then
		download_da_local_files
	fi

	# Download eth-faucet files if requested
	if [[ $DEPLOY_ETH_FAUCET == "true" ]]; then
		download_eth_faucet_files
	fi

	# Download eth-explorer files if requested
	if [[ $DEPLOY_ETH_EXPLORER == "true" ]]; then
		download_eth_explorer_files
	fi

	# Download eth-indexer files if requested
	if [[ $DEPLOY_ETH_INDEXER == "true" ]]; then
		download_eth_indexer_files
	fi

	log "SUCCESS" "All deployment files downloaded successfully"
}

# Update genesis.json with new chain ID
update_genesis_chain_id() {
	local chain_id="$1"
	local genesis_file="genesis.json"

	if [[ ! -f $genesis_file ]]; then
		log "WARN" "Genesis file not found: $genesis_file"
		return 0
	fi

	log "CONFIG" "Updating genesis.json with chain ID: $chain_id"

	# Use jq to update the chainId in the genesis file
	if command -v jq >/dev/null 2>&1; then
		# Create a temporary file for the updated genesis
		local temp_genesis=$(mktemp)
		jq ".config.chainId = $chain_id" "$genesis_file" > "$temp_genesis" || error_exit "Failed to update chain ID in genesis.json"
		mv "$temp_genesis" "$genesis_file" || error_exit "Failed to replace genesis.json"
		log "SUCCESS" "Genesis chain ID updated to: $chain_id"
	else
		# Fallback to awk if jq is not available
		local temp_genesis="${genesis_file}.tmp"
		awk -v chain_id="$chain_id" '
		/"chainId":/ {
			gsub(/"chainId": [0-9]*/, "\"chainId\": " chain_id)
		}
		{ print }
		' "$genesis_file" > "$temp_genesis" || error_exit "Failed to update chain ID in genesis.json"
		mv "$temp_genesis" "$genesis_file" || error_exit "Failed to replace genesis.json"
		log "SUCCESS" "Genesis chain ID updated to: $chain_id (using awk fallback)"
	fi
}

# Validate Ethereum address format
validate_eth_address() {
	local address="$1"

	# Check if address starts with 0x and is 42 characters long (0x + 40 hex chars)
	if [[ $address =~ ^0x[a-fA-F0-9]{40}$ ]]; then
		return 0
	else
		return 1
	fi
}

# Setup genesis allocation with user-provided addresses
setup_genesis_allocation() {
	log "CONFIG" "Setting up genesis block allocation..."

	echo ""
	echo "💰 Genesis Block Token Allocation"
	echo "=================================="
	echo ""
	echo "You can specify Ethereum addresses that will receive initial token balances in the genesis block."
	echo ""
	echo "⚠️  IMPORTANT: You must possess the private keys for these addresses to make transactions"
	echo "   when the blockchain is live. If you don't have the private keys, you won't be able"
	echo "   to access the funds allocated to these addresses."
	echo ""
	echo "📝 Please enter Ethereum addresses (one per line). You must provide at least one valid address:"
	echo "   Example: 0x61F929626841DC9ed2268e62Ef408Bd29d995293"
	echo ""

	local user_addresses=()
	local address_count=0

	while true; do
		if [[ ${#user_addresses[@]} -eq 0 ]]; then
			echo -n "Address $((address_count + 1)) (required): "
		else
			echo -n "Address $((address_count + 1)) (optional): "
		fi
		read -r address

		# If empty input and no addresses added yet, require input
		if [[ -z "$address" ]]; then
			if [[ ${#user_addresses[@]} -eq 0 ]]; then
				echo "❌ Error: At least one valid Ethereum address is required."
				echo "   You cannot proceed without providing a valid address."
				continue
			else
				# User has provided at least one address, allow them to finish
				break
			fi
		fi

		# Validate the address format
		if validate_eth_address "$address"; then
			user_addresses+=("$address")
			address_count=$((address_count + 1))
			echo "✅ Valid address added: $address"
			echo ""
			echo "💡 You can add more addresses or press Enter to continue with the current addresses."
		else
			echo "❌ Invalid Ethereum address format. Please enter a valid address starting with 0x followed by 40 hexadecimal characters."
			echo "   Example: 0x61F929626841DC9ed2268e62Ef408Bd29d995293"
		fi
	done

	# Update genesis.json with user addresses (guaranteed to have at least one)
	log "CONFIG" "Updating genesis.json with ${#user_addresses[@]} user-provided address(es)..."
	update_genesis_allocation "${user_addresses[@]}"
	echo ""
	echo "✅ Genesis block updated with your addresses:"
	for addr in "${user_addresses[@]}"; do
		echo "   - $addr"
	done
	echo ""
	echo "💡 Each address will receive a large initial balance for testing purposes."

	echo ""
}

# Update genesis.json allocation section with user addresses
update_genesis_allocation() {
	local addresses=("$@")
	local genesis_file="genesis.json"
	local default_balance="0x4a47e3c12448f4ad000000"  # Large balance for testing

	if [[ ! -f $genesis_file ]]; then
		log "WARN" "Genesis file not found: $genesis_file"
		return 0
	fi

	log "CONFIG" "Updating genesis allocation with ${#addresses[@]} address(es)..."

	if command -v jq >/dev/null 2>&1; then
		# Use jq to update the allocation
		local temp_genesis=$(mktemp)

		# Start with empty alloc object
		jq '.alloc = {}' "$genesis_file" > "$temp_genesis" || error_exit "Failed to clear genesis allocation"

		# Add each address with the default balance
		for address in "${addresses[@]}"; do
			jq --arg addr "$address" --arg balance "$default_balance" \
				'.alloc[$addr] = {"balance": $balance}' "$temp_genesis" > "${temp_genesis}.tmp" || error_exit "Failed to add address $address to genesis"
			mv "${temp_genesis}.tmp" "$temp_genesis"
			log "DEBUG" "Added address $address with balance $default_balance"
		done

		mv "$temp_genesis" "$genesis_file" || error_exit "Failed to replace genesis.json"
		log "SUCCESS" "Genesis allocation updated with ${#addresses[@]} address(es)"
	else
		# Fallback method using awk (more robust than sed)
		log "WARN" "jq not available, using awk fallback for genesis allocation update"

		local temp_genesis="${genesis_file}.tmp"
		local alloc_entries=""
		local first=true

		# Build the allocation entries
		for address in "${addresses[@]}"; do
			if [[ $first == true ]]; then
				first=false
			else
				alloc_entries+=",\n"
			fi
			alloc_entries="$alloc_entries    \"$address\": {\n      \"balance\": \"$default_balance\"\n    }"
		done

		# Use awk to replace the alloc section
		awk -v alloc_entries="$alloc_entries" '
		{
			# Handle both single-line and multi-line alloc formats
			if (/"alloc": \{\}/ || /"alloc": \{[^}]*\}/) {
				# Single-line alloc format - replace entire line
				gsub(/"alloc": \{[^}]*\}/, "\"alloc\": {\n" alloc_entries "\n  }")
				print
			} else if (/"alloc":/) {
				# Multi-line alloc format - start replacement
				print "  \"alloc\": {"
				printf "%s", alloc_entries
				print "\n  },"
				# Skip until we find the closing brace
				while ((getline) > 0) {
					if (/^  }/) break
				}
			} else {
				print
			}
		}
		' "$genesis_file" > "$temp_genesis" || error_exit "Failed to update genesis allocation using awk"

		# Verify the result contains expected JSON structure
		if grep -q '"number":' "$temp_genesis" && grep -q '"gasUsed":' "$temp_genesis" && grep -q '"parentHash":' "$temp_genesis"; then
			mv "$temp_genesis" "$genesis_file" || error_exit "Failed to replace genesis.json"
			log "SUCCESS" "Genesis allocation updated with ${#addresses[@]} address(es) using awk fallback"
		else
			log "ERROR" "Generated genesis.json appears to be incomplete"
			rm -f "$temp_genesis"
			error_exit "Failed to properly update genesis allocation using awk fallback"
		fi
	fi
}

# Configuration management for single-sequencer
setup_sequencer_configuration() {
	log "CONFIG" "Setting up single-sequencer configuration..."

	# Change to single-sequencer directory
	cd "$DEPLOYMENT_DIR/stacks/single-sequencer" || error_exit "Failed to change to single-sequencer directory"

	local env_file=".env"

	if [[ ! -f $env_file ]]; then
		error_exit "Environment file not found: $env_file"
	fi

	if [[ ! -r $env_file ]]; then
		error_exit "Environment file is not readable: $env_file"
	fi

	# Check for missing EVM_SIGNER_PASSPHRASE and generate if empty
	if grep -q "^EVM_SIGNER_PASSPHRASE=$" "$env_file" || ! grep -q "^EVM_SIGNER_PASSPHRASE=" "$env_file"; then
		log "CONFIG" "Generating random EVM signer passphrase..."
		local passphrase=$(openssl rand -base64 32 | tr -d '\n')
		update_env_var "$env_file" "EVM_SIGNER_PASSPHRASE" "$passphrase"
		log "SUCCESS" "EVM signer passphrase generated and set"
	fi

	# Check for missing CHAIN_ID and prompt user
	if grep -q "^CHAIN_ID=$" "$env_file" || ! grep -q "^CHAIN_ID=" "$env_file"; then
		echo "Chain ID is required for the deployment."
		echo "Please enter a chain ID (e.g., 1234 for development, or your custom chain ID):"
		read -r chain_id

		# Validate chain ID is not empty
		if [[ -z "$chain_id" ]]; then
			error_exit "Chain ID cannot be empty"
		fi

		# Update chain ID in .env file
		update_env_var "$env_file" "CHAIN_ID" "$chain_id"
		log "SUCCESS" "Chain ID set to: $chain_id"

		# Update genesis.json with the new chain ID
		update_genesis_chain_id "$chain_id"
	fi

	# Prompt user for Ethereum addresses for genesis allocation
	setup_genesis_allocation

	# If DA Celestia is deployed, add DA configuration to single-sequencer
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		log "CONFIG" "Configuring single-sequencer for DA Celestia integration..."

		# Get DA_HEADER_NAMESPACE and DA_DATA_NAMESPACE from da-celestia .env file
		local da_celestia_env="$DEPLOYMENT_DIR/stacks/da-celestia/.env"
		if [[ -f $da_celestia_env ]]; then
			local da_header_namespace=$(grep "^DA_HEADER_NAMESPACE=" "$da_celestia_env" | cut -d'=' -f2 | tr -d '"')
			local da_data_namespace=$(grep "^DA_DATA_NAMESPACE=" "$da_celestia_env" | cut -d'=' -f2 | tr -d '"')

			if [[ -n $da_header_namespace ]]; then
				# Add or update SEQUENCER_DA_HEADER_NAMESPACE in single-sequencer .env
				update_env_var "$env_file" "SEQUENCER_DA_HEADER_NAMESPACE" "$da_header_namespace"
				log "SUCCESS" "SEQUENCER_DA_HEADER_NAMESPACE set to: $da_header_namespace"
			else
				log "WARN" "DA_HEADER_NAMESPACE is empty in da-celestia .env file. Single-sequencer may show warnings."
				# Still add the empty SEQUENCER_DA_HEADER_NAMESPACE to single-sequencer .env to avoid undefined variable warnings
				update_env_var "$env_file" "SEQUENCER_DA_HEADER_NAMESPACE" ""
			fi

			if [[ -n $da_data_namespace ]]; then
				# Add or update SEQUENCER_DA_DATA_NAMESPACE in single-sequencer .env
				update_env_var "$env_file" "SEQUENCER_DA_DATA_NAMESPACE" "$da_data_namespace"
				log "SUCCESS" "SEQUENCER_DA_DATA_NAMESPACE set to: $da_data_namespace"
			else
				log "WARN" "DA_DATA_NAMESPACE is empty in da-celestia .env file. Single-sequencer may show warnings."
				# Still add the empty SEQUENCER_DA_DATA_NAMESPACE to single-sequencer .env to avoid undefined variable warnings
				update_env_var "$env_file" "SEQUENCER_DA_DATA_NAMESPACE" ""
			fi
		else
			log "WARN" "DA-Celestia .env file not found. Adding empty DA namespaces to prevent warnings."
			# Add empty DA namespaces to single-sequencer .env to avoid undefined variable warnings
			update_env_var "$env_file" "SEQUENCER_DA_HEADER_NAMESPACE" ""
			update_env_var "$env_file" "SEQUENCER_DA_DATA_NAMESPACE" ""
		fi

		# Update SEQUENCER_DA_START_HEIGHT with latest block height from Celestia
		if [[ -n "$CELESTIA_LATEST_BLOCK" ]]; then
			update_env_var "$env_file" "SEQUENCER_DA_START_HEIGHT" "$CELESTIA_LATEST_BLOCK"
			log "SUCCESS" "SEQUENCER_DA_START_HEIGHT set to: $CELESTIA_LATEST_BLOCK"
		else
			log "WARN" "CELESTIA_LATEST_BLOCK is not available. SEQUENCER_DA_START_HEIGHT not updated."
		fi
	fi

	log "SUCCESS" "Single-sequencer configuration setup completed"
}

# Configuration management for fullnode
setup_fullnode_configuration() {
	log "CONFIG" "Setting up fullnode configuration..."

	# Change to fullnode directory
	cd "$DEPLOYMENT_DIR/stacks/fullnode" || error_exit "Failed to change to fullnode directory"

	local env_file=".env"

	if [[ ! -f $env_file ]]; then
		error_exit "Fullnode environment file not found: $env_file"
	fi

	if [[ ! -r $env_file ]]; then
		error_exit "Fullnode environment file is not readable: $env_file"
	fi

	# Check for missing CHAIN_ID and get it from sequencer configuration
	if grep -q "^CHAIN_ID=$" "$env_file" || ! grep -q "^CHAIN_ID=" "$env_file"; then
		log "CONFIG" "Setting CHAIN_ID for fullnode from sequencer configuration..."

		# Get CHAIN_ID from single-sequencer .env file
		local sequencer_env="$DEPLOYMENT_DIR/stacks/single-sequencer/.env"
		if [[ -f $sequencer_env ]]; then
			local chain_id=$(grep "^CHAIN_ID=" "$sequencer_env" | cut -d'=' -f2 | tr -d '"')

			if [[ -n $chain_id ]]; then
				# Update CHAIN_ID in fullnode .env file
				update_env_var "$env_file" "CHAIN_ID" "$chain_id"
				log "SUCCESS" "CHAIN_ID set to: $chain_id"
			else
				log "WARN" "CHAIN_ID is empty in sequencer .env file. Fullnode may not start properly."
				# Still add the empty CHAIN_ID to fullnode .env to avoid undefined variable warnings
				update_env_var "$env_file" "CHAIN_ID" ""
			fi
		else
			log "WARN" "Sequencer .env file not found. Adding empty CHAIN_ID to prevent warnings."
			# Add empty CHAIN_ID to fullnode .env to avoid undefined variable warnings
			update_env_var "$env_file" "CHAIN_ID" ""
		fi
	fi

	# If DA Celestia is deployed, add DA configuration to fullnode
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		log "CONFIG" "Configuring fullnode for DA Celestia integration..."

		# Get DA_HEADER_NAMESPACE and DA_DATA_NAMESPACE from da-celestia .env file
		local da_celestia_env="$DEPLOYMENT_DIR/stacks/da-celestia/.env"
		if [[ -f $da_celestia_env ]]; then
			local da_header_namespace=$(grep "^DA_HEADER_NAMESPACE=" "$da_celestia_env" | cut -d'=' -f2 | tr -d '"')
			local da_data_namespace=$(grep "^DA_DATA_NAMESPACE=" "$da_celestia_env" | cut -d'=' -f2 | tr -d '"')

			if [[ -n $da_header_namespace ]]; then
				# Add or update FULLNODE_DA_HEADER_NAMESPACE in fullnode .env
				update_env_var "$env_file" "FULLNODE_DA_HEADER_NAMESPACE" "$da_header_namespace"
				log "SUCCESS" "FULLNODE_DA_HEADER_NAMESPACE set to: $da_header_namespace"
			else
				log "WARN" "DA_HEADER_NAMESPACE is empty in da-celestia .env file. Fullnode may show warnings."
				# Still add the empty FULLNODE_DA_HEADER_NAMESPACE to fullnode .env to avoid undefined variable warnings
				update_env_var "$env_file" "FULLNODE_DA_HEADER_NAMESPACE" ""
			fi

			if [[ -n $da_data_namespace ]]; then
				# Add or update FULLNODE_DA_DATA_NAMESPACE in fullnode .env
				update_env_var "$env_file" "FULLNODE_DA_DATA_NAMESPACE" "$da_data_namespace"
				log "SUCCESS" "FULLNODE_DA_DATA_NAMESPACE set to: $da_data_namespace"
			else
				log "WARN" "DA_DATA_NAMESPACE is empty in da-celestia .env file. Fullnode may show warnings."
				# Still add the empty FULLNODE_DA_DATA_NAMESPACE to fullnode .env to avoid undefined variable warnings
				update_env_var "$env_file" "FULLNODE_DA_DATA_NAMESPACE" ""
			fi
		else
			log "WARN" "DA-Celestia .env file not found. Adding empty DA namespaces to prevent warnings."
			# Add empty DA namespaces to fullnode .env to avoid undefined variable warnings
			update_env_var "$env_file" "FULLNODE_DA_HEADER_NAMESPACE" ""
			update_env_var "$env_file" "FULLNODE_DA_DATA_NAMESPACE" ""
		fi

		# Update FULLNODE_DA_START_HEIGHT with latest block height from Celestia
		if [[ -n "$CELESTIA_LATEST_BLOCK" ]]; then
			update_env_var "$env_file" "FULLNODE_DA_START_HEIGHT" "$CELESTIA_LATEST_BLOCK"
			log "SUCCESS" "FULLNODE_DA_START_HEIGHT set to: $CELESTIA_LATEST_BLOCK"
		else
			log "WARN" "CELESTIA_LATEST_BLOCK is not available. FULLNODE_DA_START_HEIGHT not updated."
		fi
	fi

	log "SUCCESS" "Fullnode configuration setup completed"
}

# Helper function to prompt and validate namespace input
prompt_namespace_input() {
	local namespace_type="$1"
	local env_var_name="$2"
	local env_file="$3"
	local example_value="$4"

	local namespace_type_lower=$(echo "$namespace_type" | tr '[:upper:]' '[:lower:]')

	echo ""
	echo "🌌 $namespace_type namespace is required for Celestia data availability."
	echo "This should be an encoded string identifier used to categorize and retrieve ${namespace_type_lower} blobs."
	echo "Example: '$example_value'"

	while true; do
		echo -n "Please enter the ${namespace_type_lower} namespace: "
		read -r namespace_value

		# Validate namespace format
		if [[ -z "$namespace_value" ]]; then
			echo "❌ Error: $namespace_type namespace cannot be empty."
			continue
		fi

		# Check if it's a valid encoded string
		if [[ $namespace_value =~ ^[a-zA-Z0-9_-]+$ ]]; then
			echo "✅ Valid ${namespace_type_lower} namespace format."
			break
		else
			echo "❌ Error: Namespace must be an encoded string with alphanumeric characters, underscores, and hyphens."
			continue
		fi
	done

	# Update namespace in .env file
	update_env_var "$env_file" "$env_var_name" "$namespace_value"
	log "SUCCESS" "DA ${namespace_type_lower} namespace set to: $namespace_value"
}

# Fetch latest block information from Celestia consensus endpoint
fetch_celestia_latest_block() {
	log "CONFIG" "Setting up trusted hash from latest block"
	local consensus_url="https://full.consensus.mocha-4.celestia-mocha.com/block"
	log "DOWNLOAD" "Fetching latest block information from: $consensus_url"

	# Fetch block information with proper error handling
	local block_response
	if ! block_response=$(curl -ks "$consensus_url" --max-time 30); then
		log "ERROR" "Failed to fetch latest block information from consensus endpoint"
		exit 1
	fi

	# Validate that we received a response
	if [ -z "$block_response" ]; then
		log "ERROR" "Received empty response from consensus endpoint"
		exit 1
	fi

	log "SUCCESS" "Latest block information fetched successfully"

	log "INFO" "Parsing block response for height and hash"

	# Parse block height with error handling
	local latest_block
	if ! latest_block=$(echo "$block_response" | jq -r '.result.block.header.height' 2>&1); then
		log "ERROR" "Failed to parse block height from response: $latest_block"
		exit 1
	fi

	# Parse block hash with error handling
	local latest_hash
	if ! latest_hash=$(echo "$block_response" | jq -r '.result.block_id.hash' 2>&1); then
		log "ERROR" "Failed to parse block hash from response: $latest_hash"
		exit 1
	fi

	# Validate parsed values are not null or empty
	if [ -z "$latest_block" ] || [ "$latest_block" = "null" ]; then
		log "ERROR" "Invalid or missing block height in response"
		exit 1
	fi

	if [ -z "$latest_hash" ] || [ "$latest_hash" = "null" ]; then
		log "ERROR" "Invalid or missing block hash in response"
		exit 1
	fi

	# Validate block height is a number
	if ! [[ "$latest_block" =~ ^[0-9]+$ ]]; then
		log "ERROR" "Block height is not a valid number: $latest_block"
		exit 1
	fi

	# Validate hash format (should be 64 character hex string)
	if ! [[ "$latest_hash" =~ ^[A-Fa-f0-9]{64}$ ]]; then
		log "ERROR" "Block hash is not a valid 64-character hex string: $latest_hash"
		exit 1
	fi

	log "SUCCESS" "Parsed latest block - Height: $latest_block, Hash: $latest_hash"

	# Escape special characters for sed
	latest_hash_escaped=$(printf '%s\n' "$latest_hash" | sed 's/[[\.*^$()+?{|]/\\&/g')
	latest_block_escaped=$(printf '%s\n' "$latest_block" | sed 's/[[\.*^$()+?{|]/\\&/g')

	log "SUCCESS" "Escaped values - Height: $latest_block_escaped, Hash: $latest_hash_escaped"

	# Export values for use in other functions
	export CELESTIA_LATEST_BLOCK="$latest_block_escaped"
	export CELESTIA_LATEST_HASH="$latest_hash_escaped"
}

# Configuration management for da-celestia
setup_da_celestia_configuration() {
	log "CONFIG" "Setting up da-celestia configuration..."

	# Change to da-celestia directory
	cd "$DEPLOYMENT_DIR/stacks/da-celestia" || error_exit "Failed to change to da-celestia directory"

	local env_file=".env"

	if [[ ! -f $env_file ]]; then
		error_exit "DA-Celestia environment file not found: $env_file"
	fi

	if [[ ! -r $env_file ]]; then
		error_exit "DA-Celestia environment file is not readable: $env_file"
	fi

	# Fetch latest block information from Celestia consensus endpoint
	fetch_celestia_latest_block

	# Check for missing DA_HEADER_NAMESPACE and prompt user
	if grep -q "^DA_HEADER_NAMESPACE=$" "$env_file" || ! grep -q "^DA_HEADER_NAMESPACE=" "$env_file"; then
		prompt_namespace_input "Header" "DA_HEADER_NAMESPACE" "$env_file" "namespace_test_header"
	fi

	# Add trusted hash and block height to da-celestia .env
	update_env_var "$env_file" "DA_TRUSTED_HASH" "$CELESTIA_LATEST_HASH"
	update_env_var "$env_file" "DA_TRUSTED_HEIGHT" "$CELESTIA_LATEST_BLOCK"
	log "SUCCESS" "Added trusted hash and height to da-celestia .env"

	# Check for missing DA_DATA_NAMESPACE and prompt user
	if grep -q "^DA_DATA_NAMESPACE=$" "$env_file" || ! grep -q "^DA_DATA_NAMESPACE=" "$env_file"; then
		prompt_namespace_input "Data" "DA_DATA_NAMESPACE" "$env_file" "namespace_test_data"
	fi

	log "SUCCESS" "DA-Celestia configuration setup completed"
}

# Helper function to validate private key format
validate_private_key() {
	local private_key="$1"

	# Check if private key is 64 hex characters (without 0x prefix) or 66 characters (with 0x prefix)
	if [[ $private_key =~ ^0x[a-fA-F0-9]{64}$ ]] || [[ $private_key =~ ^[a-fA-F0-9]{64}$ ]]; then
		return 0
	else
		return 1
	fi
}

# Configuration management for eth-faucet
setup_eth_faucet_configuration() {
	log "CONFIG" "Setting up eth-faucet configuration..."

	# Change to eth-faucet directory
	cd "$DEPLOYMENT_DIR/stacks/eth-faucet" || error_exit "Failed to change to eth-faucet directory"

	local env_file=".env"

	if [[ ! -f $env_file ]]; then
		error_exit "Eth-faucet environment file not found: $env_file"
	fi

	if [[ ! -r $env_file ]]; then
		error_exit "Eth-faucet environment file is not readable: $env_file"
	fi

	# Check for missing PRIVATE_KEY and prompt user
	if grep -q "^PRIVATE_KEY=$" "$env_file" || ! grep -q "^PRIVATE_KEY=" "$env_file"; then
		echo ""
		echo "🔑 Private Key Configuration for Eth-Faucet"
		echo "============================================"
		echo ""
		echo "The eth-faucet service requires a private key to sign transactions and distribute tokens."
		echo ""
		echo "⚠️  SECURITY WARNING:"
		echo "   • This private key will control the faucet's funds"
		echo "   • Make sure this account has sufficient balance for token distribution"
		echo "   • Use a dedicated account for the faucet, not your main wallet"
		echo "   • The private key will be stored in the .env file"
		echo ""
		echo "📝 Private key format:"
		echo "   • 64 hexadecimal characters (without 0x prefix)"
		echo "   • OR 66 characters (with 0x prefix)"
		echo "   • Example: 0x11f736e572551c472f4308299735c718447b0d03980b18c951950bbc5beb3ebb"
		echo ""

		while true; do
			echo -n "Please enter the private key for the eth-faucet: "
			read -r private_key

			# Validate private key format
			if [[ -z "$private_key" ]]; then
				echo "❌ Error: Private key cannot be empty."
				continue
			fi

			if validate_private_key "$private_key"; then
				# Ensure private key has 0x prefix for consistency
				if [[ ! $private_key =~ ^0x ]]; then
					private_key="0x$private_key"
				fi
				echo "✅ Valid private key format."
				break
			else
				echo "❌ Error: Invalid private key format."
				echo "   Private key must be 64 hexadecimal characters (optionally prefixed with 0x)."
				echo "   Example: 0x11f736e572551c472f4308299735c718447b0d03980b18c951950bbc5beb3ebb"
			fi
		done

		# Update private key in .env file
		update_env_var "$env_file" "PRIVATE_KEY" "$private_key"
		log "SUCCESS" "Private key configured for eth-faucet"

		echo ""
		echo "✅ Eth-faucet private key has been configured."
		echo "💡 Make sure the corresponding address has sufficient balance for token distribution."
		echo ""
	fi

	log "SUCCESS" "Eth-faucet configuration setup completed"
}

# Configuration management for eth-explorer
setup_eth_explorer_configuration() {
	log "CONFIG" "Setting up eth-explorer configuration..."

	# Change to eth-explorer directory
	cd "$DEPLOYMENT_DIR/stacks/eth-explorer" || error_exit "Failed to change to eth-explorer directory"

	local env_file=".env"

	if [[ ! -f $env_file ]]; then
		error_exit "Eth-explorer environment file not found: $env_file"
	fi

	if [[ ! -r $env_file ]]; then
		error_exit "Eth-explorer environment file is not readable: $env_file"
	fi

	# Check for missing CHAIN_ID and get it from sequencer configuration
	if grep -q "^CHAIN_ID=$" "$env_file" || ! grep -q "^CHAIN_ID=" "$env_file"; then
		log "CONFIG" "Setting CHAIN_ID for eth-explorer from sequencer configuration..."

		# Get CHAIN_ID from single-sequencer .env file
		local sequencer_env="$DEPLOYMENT_DIR/stacks/single-sequencer/.env"
		if [[ -f $sequencer_env ]]; then
			local chain_id=$(grep "^CHAIN_ID=" "$sequencer_env" | cut -d'=' -f2 | tr -d '"')

			if [[ -n $chain_id ]]; then
				# Update CHAIN_ID in eth-explorer .env file
				update_env_var "$env_file" "CHAIN_ID" "$chain_id"
				log "SUCCESS" "CHAIN_ID set to: $chain_id"
			else
				log "WARN" "CHAIN_ID is empty in sequencer .env file. Eth-explorer may not start properly."
				# Still add the empty CHAIN_ID to eth-explorer .env to avoid undefined variable warnings
				update_env_var "$env_file" "CHAIN_ID" ""
			fi
		else
			log "WARN" "Sequencer .env file not found. Adding empty CHAIN_ID to prevent warnings."
			# Add empty CHAIN_ID to eth-explorer .env to avoid undefined variable warnings
			update_env_var "$env_file" "CHAIN_ID" ""
		fi
	fi

	# Check for missing EXPLORER_POSTGRES_PASSWORD and generate if empty
	if grep -q "^EXPLORER_POSTGRES_PASSWORD=$" "$env_file" || ! grep -q "^EXPLORER_POSTGRES_PASSWORD=" "$env_file"; then
		log "CONFIG" "Generating random PostgreSQL password for eth-explorer..."
		local postgres_password=$(openssl rand -hex 16 | tr -d '\n')
		update_env_var "$env_file" "EXPLORER_POSTGRES_PASSWORD" "$postgres_password"
		log "SUCCESS" "PostgreSQL password generated and set for eth-explorer"
	fi

	# Check for missing SECRET_KEY_BASE and generate if empty
	if grep -q "^SECRET_KEY_BASE=$" "$env_file" || ! grep -q "^SECRET_KEY_BASE=" "$env_file"; then
		log "CONFIG" "Generating random secret key base for eth-explorer..."
		local secret_key_base=$(openssl rand -base64 64 | tr -d '\n')
		update_env_var "$env_file" "SECRET_KEY_BASE" "$secret_key_base"
		log "SUCCESS" "Secret key base generated and set for eth-explorer"
	fi

	log "SUCCESS" "Eth-explorer configuration setup completed"
}

# Configuration management for eth-indexer
setup_eth_indexer_configuration() {
	log "CONFIG" "Setting up eth-indexer configuration..."

	# Change to eth-indexer directory
	cd "$DEPLOYMENT_DIR/stacks/eth-indexer" || error_exit "Failed to change to eth-indexer directory"

	local env_file=".env"

	if [[ ! -f $env_file ]]; then
		error_exit "Eth-indexer environment file not found: $env_file"
	fi

	if [[ ! -r $env_file ]]; then
		error_exit "Eth-indexer environment file is not readable: $env_file"
	fi

	# Check for missing CHAIN_ID and get it from sequencer configuration
	if grep -q "^CHAIN_ID=$" "$env_file" || ! grep -q "^CHAIN_ID=" "$env_file"; then
		log "CONFIG" "Setting CHAIN_ID for eth-indexer from sequencer configuration..."

		# Get CHAIN_ID from single-sequencer .env file
		local sequencer_env="$DEPLOYMENT_DIR/stacks/single-sequencer/.env"
		if [[ -f $sequencer_env ]]; then
			local chain_id=$(grep "^CHAIN_ID=" "$sequencer_env" | cut -d'=' -f2 | tr -d '"')

			if [[ -n $chain_id ]]; then
				# Update CHAIN_ID in eth-indexer .env file
				update_env_var "$env_file" "CHAIN_ID" "$chain_id"
				log "SUCCESS" "CHAIN_ID set to: $chain_id"
			else
				log "WARN" "CHAIN_ID is empty in sequencer .env file. Eth-indexer may not start properly."
				# Still add the empty CHAIN_ID to eth-indexer .env to avoid undefined variable warnings
				update_env_var "$env_file" "CHAIN_ID" ""
			fi
		else
			log "WARN" "Sequencer .env file not found. Adding empty CHAIN_ID to prevent warnings."
			# Add empty CHAIN_ID to eth-indexer .env to avoid undefined variable warnings
			update_env_var "$env_file" "CHAIN_ID" ""
		fi
	fi

	# Check for missing INDEXER_POSTGRES_PASSWORD and generate if empty
	if grep -q "^INDEXER_POSTGRES_PASSWORD=$" "$env_file" || ! grep -q "^INDEXER_POSTGRES_PASSWORD=" "$env_file"; then
		log "CONFIG" "Generating random PostgreSQL password for eth-indexer..."
		local postgres_password=$(openssl rand -hex 16 | tr -d '\n')
		update_env_var "$env_file" "INDEXER_POSTGRES_PASSWORD" "$postgres_password"
		log "SUCCESS" "PostgreSQL password generated and set for eth-indexer"
	fi

	log "SUCCESS" "Eth-indexer configuration setup completed"
}

# Configuration management
setup_configuration() {
	log "CONFIG" "Setting up configuration..."

	# Setup da-celestia configuration first if deployed (so DA namespaces are available for single-sequencer and fullnode)
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		setup_da_celestia_configuration
	fi

	# Setup single-sequencer configuration
	setup_sequencer_configuration

	# Setup fullnode configuration if deployed
	if [[ $DEPLOY_FULLNODE == "true" ]]; then
		setup_fullnode_configuration
	fi

	# Setup eth-faucet configuration if deployed
	if [[ $DEPLOY_ETH_FAUCET == "true" ]]; then
		setup_eth_faucet_configuration
	fi

	# Setup eth-explorer configuration if deployed
	if [[ $DEPLOY_ETH_EXPLORER == "true" ]]; then
		setup_eth_explorer_configuration
	fi

	# Setup eth-indexer configuration if deployed
	if [[ $DEPLOY_ETH_INDEXER == "true" ]]; then
		setup_eth_indexer_configuration
	fi

	log "SUCCESS" "All configuration setup completed"
}

# Deployment preparation
prepare_deployment() {
	log "DEPLOY" "Preparing deployment files..."

	if [[ $DRY_RUN == "true" ]]; then
		log "INFO" "DRY RUN: Deployment files prepared. Ready to run services"
		return 0
	fi

	log "SUCCESS" "Deployment files prepared successfully"
}

# Validate deployment files for single-sequencer
validate_sequencer_files() {
	log "DEBUG" "Validating single-sequencer deployment files..."

	# Change to single-sequencer directory
	cd "$DEPLOYMENT_DIR/stacks/single-sequencer" || error_exit "Failed to change to single-sequencer directory"

	local required_files=(
		"docker-compose.yml"
		".env"
		"genesis.json"
		"entrypoint.sequencer.sh"
	)

	for file in "${required_files[@]}"; do
		if [[ ! -f $file ]]; then
			error_exit "Required single-sequencer file not found: $file"
		fi
	done

	log "SUCCESS" "Single-sequencer files validation completed"
}

# Validate deployment files for da-celestia
validate_da_celestia_files() {
	log "DEBUG" "Validating da-celestia deployment files..."

	# Change to da-celestia directory
	cd "$DEPLOYMENT_DIR/stacks/da-celestia" || error_exit "Failed to change to da-celestia directory"

	local required_files=(
		"docker-compose.yml"
		".env"
		"entrypoint.appd.sh"
		"entrypoint.da.sh"
	)

	for file in "${required_files[@]}"; do
		if [[ ! -f $file ]]; then
			error_exit "Required da-celestia file not found: $file"
		fi
	done

	log "SUCCESS" "DA-Celestia files validation completed"
}

# Validate deployment files
validate_deployment_files() {
	log "INFO" "Validating deployment files..."

	# Validate single-sequencer files
	validate_sequencer_files

	# Validate da-celestia files if deployed
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		validate_da_celestia_files
	fi

	log "SUCCESS" "All deployment files validation completed successfully"
}

# Progress reporting
show_deployment_status() {
	log "SUCCESS" "Deployment Setup Complete"
	echo "🎉 =========================="
	echo "📁 Deployment Directory: $DEPLOYMENT_DIR"
	echo ""
	echo "🚀 Available Stacks:"

	if [[ $SELECTED_SEQUENCER == "single-sequencer" ]]; then
		echo "  📡 Single Sequencer: $DEPLOYMENT_DIR/stacks/single-sequencer"
	fi

	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		echo "  🌌 Celestia Data Availability: $DEPLOYMENT_DIR/stacks/da-celestia"
	fi

	if [[ $DEPLOY_DA_LOCAL == "true" ]]; then
		echo "  🏠 Local Data Availability: $DEPLOYMENT_DIR/stacks/da-local"
	fi

	if [[ $DEPLOY_FULLNODE == "true" ]]; then
		echo "  🔗 Fullnode: $DEPLOYMENT_DIR/stacks/fullnode"
	fi

	if [[ $DEPLOY_ETH_FAUCET == "true" ]]; then
		echo "  💰 Eth-Faucet: $DEPLOYMENT_DIR/stacks/eth-faucet"
	fi

	if [[ $DEPLOY_ETH_EXPLORER == "true" ]]; then
		echo "  🔍 Eth-Explorer: $DEPLOYMENT_DIR/stacks/eth-explorer"
	fi

	if [[ $DEPLOY_ETH_INDEXER == "true" ]]; then
		echo "  📊 Eth-Indexer: $DEPLOYMENT_DIR/stacks/eth-indexer"
	fi

	echo ""
	echo "▶️  Next Steps:"
	echo ""

	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		echo "🚀 Start the Celestia Data Availability stack first:"
		echo "  1. cd $DEPLOYMENT_DIR/stacks/da-celestia"
		echo "  2. docker compose up -d"
		echo ""
		echo "💸 Do not forget to fund the default account on the Celestia node with TIA tokens. Retrive the default account address:"
		echo "  1. docker exec -it celestia-node cel-key list --node.type=light"
		echo ""
	fi

	if [[ $DEPLOY_DA_LOCAL == "true" ]]; then
		echo "🚀 Start the Local Data Availability stack first:"
		echo "  1. cd $DEPLOYMENT_DIR/stacks/da-local"
		echo "  2. docker compose up -d"
		echo ""
	fi

	if [[ $SELECTED_SEQUENCER == "single-sequencer" ]]; then
		echo "🚀 Start the Single Sequencer stack:"
		echo "  1. cd $DEPLOYMENT_DIR/stacks/single-sequencer"
		echo "  2. docker compose up -d"
		echo ""
	fi

	if [[ $DEPLOY_FULLNODE == "true" ]]; then
		echo "🚀 Start the Fullnode stack:"
		echo "  1. cd $DEPLOYMENT_DIR/stacks/fullnode"
		echo "  2. docker compose up -d"
		echo ""
	fi

	if [[ $DEPLOY_ETH_FAUCET == "true" ]]; then
		echo "🚀 Start the Eth-Faucet stack:"
		echo "  1. cd $DEPLOYMENT_DIR/stacks/eth-faucet"
		echo "  2. docker compose up -d"
		echo ""
	fi

	if [[ $DEPLOY_ETH_EXPLORER == "true" ]]; then
		echo "🚀 Start the Eth-Explorer stack:"
		echo "  1. cd $DEPLOYMENT_DIR/stacks/eth-explorer"
		echo "  2. docker compose up -d"
		echo ""
	fi

	if [[ $DEPLOY_ETH_INDEXER == "true" ]]; then
		echo "🚀 Start the Eth-Indexer stack:"
		echo "  1. cd $DEPLOYMENT_DIR/stacks/eth-indexer"
		echo "  2. docker compose up -d"
		echo ""
	fi

	echo "🌐 Service Endpoints:"

	if [[ $SELECTED_SEQUENCER == "single-sequencer" ]]; then
		echo "  📡 Single Sequencer:"
		echo "    - Ev-reth Prometheus Metrics: http://localhost:9000"
		echo "    - Ev-node Prometheus Metrics: http://localhost:26660/metrics"
		echo ""
	fi

	if [[ $DEPLOY_FULLNODE == "true" ]]; then
		echo "  🔗 Fullnode:"
		echo "    - Ev-reth RPC: http://localhost:8545"
		echo "    - Ev-reth Prometheus Metrics: http://localhost:9002"
        echo "    - Ev-node RPC: http://localhost:7331"
		echo "    - Ev-node Prometheus Metrics: http://localhost:26662/metrics"
		echo ""
	fi

	if [[ $DEPLOY_ETH_FAUCET == "true" ]]; then
		echo "  💰 Eth-Faucet:"
		echo "    - Faucet Web Interface: http://localhost:8081"
		echo ""
	fi

	if [[ $DEPLOY_ETH_EXPLORER == "true" ]]; then
		echo "  🔍 Eth-Explorer:"
		echo "    - Blockscout Web Interface: http://localhost:3000"
		echo ""
	fi

	if [[ $DEPLOY_ETH_INDEXER == "true" ]]; then
		echo "  📊 Eth-Indexer:"
		echo "    - Indexer API: http://localhost:42069"
		echo ""
	fi

	echo "�️  Service Management:"
	echo "  - View status: docker compose ps"
	echo "  - View logs: docker compose logs -f"
	echo "  - Stop services: docker compose down"
	echo "  - Restart services: docker compose restart"
	echo ""
	echo "�🔍 Health Monitoring:"
	echo "  - Check service status: docker compose ps"
	echo "  - Test endpoints manually using curl"
	echo "  - View service logs: docker compose logs -f"
}

# Usage information
show_usage() {
	cat <<EOF
Usage: $0 [OPTIONS]

Evolve One-Liner Deployment Script v$SCRIPT_VERSION

OPTIONS:
    -h, --help              Show this help message
    -v, --verbose           Enable verbose output
    -d, --dry-run           Show what would be done without executing
    -f, --force             Force installation even if components exist
    -l, --log-file FILE     Log output to specified file
    --no-cleanup            Don't cleanup on error
    --deployment-dir DIR    Use custom deployment directory (default: $DEPLOYMENT_DIR)

EXAMPLES:
    # Basic deployment (will prompt for DA selection)
    $0

    # Verbose deployment with logging
    $0 --verbose --log-file deployment.log

    # Dry run to see what would be done
    $0 --dry-run

    # One-liner remote execution
    curl -fsSL $GITHUB_RAW_BASE/main/ev-stack/deploy-evolve.sh | bash

EOF
}

# Parse command line arguments
parse_arguments() {
	while [[ $# -gt 0 ]]; do
		case $1 in
		-h | --help)
			show_usage
			exit 0
			;;
		-v | --verbose)
			VERBOSE=true
			shift
			;;
		-d | --dry-run)
			DRY_RUN=true
			shift
			;;
		-f | --force)
			FORCE_INSTALL=true
			shift
			;;
		-l | --log-file)
			LOG_FILE="$2"
			shift 2
			;;
		--no-cleanup)
			CLEANUP_ON_EXIT=false
			shift
			;;
		--deployment-dir)
			DEPLOYMENT_DIR="$2"
			shift 2
			;;
		*)
			error_exit "Unknown option: $1"
			;;
		esac
	done
}

# Check for existing deployment
check_existing_deployment() {
	local existing_deployment=false
	local existing_stacks=()

	# Check if deployment directory exists
	if [[ -d $DEPLOYMENT_DIR ]]; then
		log "WARN" "Existing deployment directory found: $DEPLOYMENT_DIR"
		existing_deployment=true

		# Check for existing single-sequencer stack
		if [[ -f "$DEPLOYMENT_DIR/$STACKS_DIR/$SINGLE_SEQUENCER_DIR/$DOCKER_COMPOSE_FILE" ]]; then
			existing_stacks+=("single-sequencer")
		fi

		# Check for existing da-celestia stack
		if [[ -f "$DEPLOYMENT_DIR/$STACKS_DIR/$DA_CELESTIA_DIR/$DOCKER_COMPOSE_FILE" ]]; then
			existing_stacks+=("da-celestia")
		fi
	fi

	# Check for running containers
	if command -v docker >/dev/null 2>&1; then
		local running_containers=()

		# Check for running single-sequencer containers
		if docker ps --format "table {{.Names}}" | grep -E "$SEQUENCER_CONTAINERS" >/dev/null 2>&1; then
			running_containers+=("single-sequencer")
		fi

		# Check for running da-celestia containers
		if docker ps --format "table {{.Names}}" | grep -E "$CELESTIA_CONTAINERS" >/dev/null 2>&1; then
			running_containers+=("da-celestia")
		fi

		if [[ ${#running_containers[@]} -gt 0 ]]; then
			log "WARN" "Found running containers from previous deployment: ${running_containers[*]}"
			existing_deployment=true
		fi
	fi

	# If existing deployment found, warn user
	if [[ $existing_deployment == "true" ]]; then
		echo ""
		echo "⚠️  =========================================="
		echo "⚠️  EXISTING DEPLOYMENT DETECTED"
		echo "⚠️  =========================================="
		echo ""

		if [[ ${#existing_stacks[@]} -gt 0 ]]; then
			echo "📁 Found existing deployment files for: ${existing_stacks[*]}"
		fi

		if [[ ${#running_containers[@]} -gt 0 ]]; then
			echo "🐳 Found running containers for: ${running_containers[*]}"
		fi

		echo ""
		echo "🚨 WARNING: Continuing will:"
		echo "   • Overwrite existing deployment files"
		echo "   • Potentially conflict with running containers"
		echo "   • Require manual cleanup of Docker volumes if you want a fresh start"
		echo ""
		echo "💡 To completely reset your deployment:"
		echo "   1. Stop running containers: docker compose down"
		echo "   2. Remove volumes: docker volume prune -f"
		echo "   3. Remove deployment directory: rm -rf $DEPLOYMENT_DIR"
		echo ""

		while true; do
			echo -n "Do you want to continue with the deployment? (y/N): "
			read -r response

			case "$response" in
			[Yy] | [Yy][Ee][Ss])
				log "INFO" "User confirmed to continue with existing deployment"
				echo ""
				echo "⚠️  IMPORTANT: You may need to manually clean up Docker volumes"
				echo "   if you experience issues with persistent data from previous deployments."
				echo "   Use 'docker volume ls' to see volumes and 'docker volume rm <name>' to remove them."
				echo ""
				break
				;;
			[Nn] | [Nn][Oo] | "")
				log "INFO" "User chose to abort deployment"
				echo "Deployment aborted by user."
				exit 0
				;;
			*)
				echo "Please answer 'y' for yes or 'n' for no."
				;;
			esac
		done
	fi
}

# Main deployment function
main() {
	log "INIT" "Starting Evolve deployment v$SCRIPT_VERSION"

	# Initialize log file if specified
	if [[ -n $LOG_FILE ]]; then
		touch "$LOG_FILE" || error_exit "Failed to create log file: $LOG_FILE"
		log "INFO" "Logging to: $LOG_FILE"
	fi

	# Check for existing deployment and warn user
	check_existing_deployment

	# Interactive DA selection (always ask user first)
	select_da_layer

	# Interactive sequencer topology selection if not specified
	if [[ -z $SELECTED_SEQUENCER ]]; then
		select_sequencer_topology
	fi

	# Interactive fullnode selection
	select_fullnode_deployment

	# Interactive eth-faucet selection
	select_eth_faucet_deployment

	# Interactive eth-explorer selection
	select_eth_explorer_deployment

	# Interactive eth-indexer selection
	select_eth_indexer_deployment

	# Show what will be deployed
	local deployment_info="$SELECTED_SEQUENCER"
	if [[ $DEPLOY_FULLNODE == "true" ]]; then
		deployment_info="$deployment_info + Fullnode"
	fi
	if [[ $DEPLOY_ETH_FAUCET == "true" ]]; then
		deployment_info="$deployment_info + Eth-Faucet"
	fi
	if [[ $DEPLOY_ETH_EXPLORER == "true" ]]; then
		deployment_info="$deployment_info + Eth-Explorer"
	fi
	if [[ $DEPLOY_ETH_INDEXER == "true" ]]; then
		deployment_info="$deployment_info + Eth-Indexer"
	fi
	if [[ $DEPLOY_DA_CELESTIA == "true" || $DEPLOY_DA_LOCAL == "true" ]]; then
		deployment_info="$deployment_info + $SELECTED_DA"
	fi
	log "INFO" "Deploying: $deployment_info"

	# Run deployment steps
	download_deployment_files
	setup_configuration
	validate_deployment_files
	prepare_deployment
	show_deployment_status

	log "SUCCESS" "Evolve deployment setup completed successfully!"

	# Disable cleanup on successful exit
	CLEANUP_ON_EXIT=false
}

# Script entry point
# Handle both direct execution and piped execution
if [[ ${BASH_SOURCE[0]:-$0} == "${0}" ]] || [[ -z ${BASH_SOURCE[0]-} ]]; then
	# Check if stdin is available for interactive input
	if [[ ! -t 0 ]] && [[ -z ${FORCE_INTERACTIVE:-} ]]; then
		# Running from pipe (like curl | bash), download and re-execute with proper stdin
		log "INFO" "Detected piped execution, downloading script for interactive mode..."

		# Create temporary script file
		TEMP_SCRIPT=$(mktemp /tmp/deploy-evolve.XXXXXX.sh)

		# Download the script
		curl -fsSL "$GITHUB_RAW_BASE/main/ev-stack/deploy-evolve.sh" -o "$TEMP_SCRIPT" || error_exit "Failed to download script"

		# Make it executable
		chmod +x "$TEMP_SCRIPT"

		# Re-execute with proper stdin and pass all arguments
		log "INFO" "Re-executing script with interactive capabilities..."

		# Set up cleanup for temp script
		trap "rm -f '$TEMP_SCRIPT'" EXIT

		# Set flag to prevent infinite loop and execute with proper stdin
		FORCE_INTERACTIVE=1 exec "$TEMP_SCRIPT" "$@"
	else
		# Normal execution or forced interactive mode
		parse_arguments "$@"
		main
	fi
fi
