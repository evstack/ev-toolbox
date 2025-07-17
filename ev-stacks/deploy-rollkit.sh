#!/bin/bash

# Rollkit One-Liner Deployment Script
# This script provides a complete deployment framework for Rollkit sequencer nodes and Celestia DA
# Usage: bash -c "bash -i <(curl -s https://raw.githubusercontent.com/rollkit/ops-toolbox/refs/heads/main/ev-stacks/deploy-rollkit.sh)"

set -euo pipefail

# Script metadata
readonly SCRIPT_VERSION="1.1.0"
readonly SCRIPT_NAME="deploy-rollkit"
readonly REPO_URL="https://github.com/rollkit/ops-toolbox"
readonly DEPLOYMENT_DIR="$HOME/rollkit-deployment"

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
SELECTED_DA=""
SELECTED_SEQUENCER=""
DEPLOY_FULLNODE=false

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

# Interactive DA selection
select_da_layer() {
	log "CONFIG" "Selecting Data Availability layer..."

	echo ""
	echo "🌌 Available Data Availability (DA) layers:"
	echo "  1) da-celestia - Celestia modular DA network (mocha-4)"
	echo ""

	while true; do
		echo -n "Please select a DA layer (1): "
		read -r choice

		case $choice in
		1)
			SELECTED_DA="da-celestia"
			DEPLOY_DA_CELESTIA=true
			log "SUCCESS" "Selected DA layer: Celestia (mocha-4)"
			break
			;;
		*)
			echo "❌ Invalid choice. Please enter 1."
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

	# Download files from the repository
	local base_url="https://raw.githubusercontent.com/rollkit/ops-toolbox/refs/heads/main/ev_stacks"

	# Choose the appropriate docker-compose file based on DA selection
	local docker_compose_file
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		docker_compose_file="stacks/single-sequencer/docker-compose.da.celestia.yml"
		log "CONFIG" "Using DA Celestia integrated docker-compose file"
	else
		docker_compose_file="stacks/single-sequencer/docker-compose.yml"
		log "CONFIG" "Using standalone docker-compose file"
	fi

	local files=(
		"stacks/single-sequencer/.env"
		"$docker_compose_file"
		"stacks/single-sequencer/entrypoint.sequencer.sh"
		"stacks/single-sequencer/genesis.json"
		"stacks/single-sequencer/single-sequencer.Dockerfile"
	)


	for file in "${files[@]}"; do
		log "DEBUG" "Downloading $file..."
		local filename=$(basename "$file")
		# Always save as docker-compose.yml regardless of source file name
		if [[ $filename == "docker-compose.da.celestia.yml" ]]; then
			filename="docker-compose.yml"
		fi
		curl -fsSL "$base_url/$file" -o "$filename" || error_exit "Failed to download $filename"
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

	# Download files from the repository
	local base_url="https://raw.githubusercontent.com/rollkit/ops-toolbox/main/ev-stack"

	local files=(
		"stacks/fullnode/.env"
		"stacks/fullnode/docker-compose.da.celestia.yml"
		"stacks/fullnode/entrypoint.fullnode.sh"
	)

	for file in "${files[@]}"; do
		log "DEBUG" "Downloading $file..."
		local filename=$(basename "$file")
		# Always save as docker-compose.yml regardless of source file name
		if [[ $filename == "docker-compose.da.celestia.yml" ]]; then
			filename="docker-compose.yml"
		fi
		curl -fsSL "$base_url/$file" -o "$filename" || error_exit "Failed to download $filename"
	done

	# Make entrypoint scripts executable
	chmod +x entrypoint.fullnode.sh || error_exit "Failed to make fullnode entrypoint script executable"

	log "SUCCESS" "Fullnode deployment files downloaded successfully"
}

# Download deployment files for da-celestia
download_da_celestia_files() {
	log "DOWNLOAD" "Downloading da-celestia deployment files..."

	# Create da-celestia subfolder
	mkdir -p "$DEPLOYMENT_DIR/stacks/da-celestia" || error_exit "Failed to create da-celestia directory"

	cd "$DEPLOYMENT_DIR/stacks/da-celestia" || error_exit "Failed to change to da-celestia directory"

	# Download files from the repository
	local base_url="https://raw.githubusercontent.com/rollkit/ops-toolbox/main/ev-stack"

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
		curl -fsSL "$base_url/$file" -o "$filename" || error_exit "Failed to download $filename"
	done

	# Make entrypoint scripts executable
	chmod +x entrypoint.appd.sh entrypoint.da.sh || error_exit "Failed to make entrypoint scripts executable"

	log "SUCCESS" "DA-Celestia deployment files downloaded successfully"
}

# Download shared library files
download_shared_files() {
	log "DOWNLOAD" "Downloading shared library files..."

	# Create lib directory
	mkdir -p "$DEPLOYMENT_DIR/lib" || error_exit "Failed to create lib directory"

	cd "$DEPLOYMENT_DIR/lib" || error_exit "Failed to change to lib directory"

	# Download files from the repository
	local base_url="https://raw.githubusercontent.com/rollkit/ops-toolbox/main/ev-stack"

	local files=(
		"lib/logging.sh"
	)

	for file in "${files[@]}"; do
		log "DEBUG" "Downloading $file..."
		local filename=$(basename "$file")
		curl -fsSL "$base_url/$file" -o "$filename" || error_exit "Failed to download $filename"
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

	log "SUCCESS" "All deployment files downloaded successfully"
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
		# Escape special characters for sed and use | as delimiter to avoid conflicts with /
		local passphrase_escaped=$(printf '%s\n' "$passphrase" | sed 's/[\\/&]/\\&/g')
		sed -i "s|^EVM_SIGNER_PASSPHRASE=.*|EVM_SIGNER_PASSPHRASE=\"$passphrase_escaped\"|" "$env_file"
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
		# Escape special characters for sed and use | as delimiter
		local chain_id_escaped=$(printf '%s\n' "$chain_id" | sed 's/[[\.*^$()+?{|]/\\&/g')
		sed -i "s|^CHAIN_ID=.*|CHAIN_ID=\"$chain_id_escaped\"|" "$env_file"

		log "SUCCESS" "Chain ID set to: $chain_id"
	fi

	# If DA Celestia is deployed, add DA configuration to single-sequencer
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		log "CONFIG" "Configuring single-sequencer for DA Celestia integration..."

		# Get DA_NAMESPACE from da-celestia .env file
		local da_celestia_env="$DEPLOYMENT_DIR/stacks/da-celestia/.env"
		if [[ -f $da_celestia_env ]]; then
			local da_namespace=$(grep "^DA_NAMESPACE=" "$da_celestia_env" | cut -d'=' -f2 | tr -d '"')

			if [[ -n $da_namespace ]]; then
				# Add or update DA_NAMESPACE in single-sequencer .env
				if grep -q "^DA_NAMESPACE=" "$env_file"; then
					sed -i "s|^DA_NAMESPACE=.*|DA_NAMESPACE=\"$da_namespace\"|" "$env_file"
				else
					echo "DA_NAMESPACE=\"$da_namespace\"" >>"$env_file"
				fi
				log "SUCCESS" "DA_NAMESPACE set to: $da_namespace"
			else
				log "WARN" "DA_NAMESPACE is empty in da-celestia .env file. Single-sequencer may show warnings."
				# Still add the empty DA_NAMESPACE to single-sequencer .env to avoid undefined variable warnings
				if ! grep -q "^DA_NAMESPACE=" "$env_file"; then
					echo "DA_NAMESPACE=" >>"$env_file"
				fi
			fi
		else
			log "WARN" "DA-Celestia .env file not found. Adding empty DA_NAMESPACE to prevent warnings."
			# Add empty DA_NAMESPACE to single-sequencer .env to avoid undefined variable warnings
			if ! grep -q "^DA_NAMESPACE=" "$env_file"; then
				echo "DA_NAMESPACE=" >>"$env_file"
			fi
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

	# If DA Celestia is deployed, add DA configuration to fullnode
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		log "CONFIG" "Configuring fullnode for DA Celestia integration..."

		# Get DA_NAMESPACE from da-celestia .env file
		local da_celestia_env="$DEPLOYMENT_DIR/da-celestia/.env"
		if [[ -f $da_celestia_env ]]; then
			local da_namespace=$(grep "^DA_NAMESPACE=" "$da_celestia_env" | cut -d'=' -f2 | tr -d '"')

			if [[ -n $da_namespace ]]; then
				# Add or update DA_NAMESPACE in fullnode .env
				if grep -q "^DA_NAMESPACE=" "$env_file"; then
					sed -i "s|^DA_NAMESPACE=.*|DA_NAMESPACE=\"$da_namespace\"|" "$env_file"
				else
					echo "DA_NAMESPACE=\"$da_namespace\"" >>"$env_file"
				fi
				log "SUCCESS" "DA_NAMESPACE set to: $da_namespace"
			else
				log "WARN" "DA_NAMESPACE is empty in da-celestia .env file. Fullnode may show warnings."
				# Still add the empty DA_NAMESPACE to fullnode .env to avoid undefined variable warnings
				if ! grep -q "^DA_NAMESPACE=" "$env_file"; then
					echo "DA_NAMESPACE=" >>"$env_file"
				fi
			fi
		else
			log "WARN" "DA-Celestia .env file not found. Adding empty DA_NAMESPACE to prevent warnings."
			# Add empty DA_NAMESPACE to fullnode .env to avoid undefined variable warnings
			if ! grep -q "^DA_NAMESPACE=" "$env_file"; then
				echo "DA_NAMESPACE=" >>"$env_file"
			fi
		fi
	fi

	log "SUCCESS" "Fullnode configuration setup completed"
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

	# Check for missing DA_NAMESPACE and prompt user
	if grep -q "^DA_NAMESPACE=$" "$env_file" || ! grep -q "^DA_NAMESPACE=" "$env_file"; then
		echo ""
		echo "🌌 Namespace is required for Celestia data availability."
		echo "This should be a 28-byte identifier used to categorize and retrieve blobs, composed of a 1-byte version and a 27-byte ID. (Full documentation: https://celestiaorg.github.io/celestia-app/specs/namespace.html)."
		echo "Example: '000000000000000000000000000000000000002737d4d967c7ca526dd5'"
		read -r da_namespace

		# Validate DA namespace (alphanumeric only)
		if ! [[ $da_namespace =~ ^[a-zA-Z0-9]+$ ]]; then
			error_exit "DA namespace must contain only alphanumeric characters"
		fi

		# Update DA_NAMESPACE in .env file
		# Use a simpler approach that doesn't require complex escaping
		if grep -q "^DA_NAMESPACE=" "$env_file"; then
			# Replace existing line
			sed -i "s/^DA_NAMESPACE=.*/DA_NAMESPACE=\"$da_namespace\"/" "$env_file"
		else
			# Add new line
			echo "DA_NAMESPACE=\"$da_namespace\"" >> "$env_file"
		fi

		log "SUCCESS" "DA namespace set to: $da_namespace"
	fi

	log "SUCCESS" "DA-Celestia configuration setup completed"
}

# Configuration management
setup_configuration() {
	log "CONFIG" "Setting up configuration..."

	# Setup da-celestia configuration first if deployed (so DA_NAMESPACE is available for single-sequencer and fullnode)
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		setup_da_celestia_configuration
	fi

	# Setup single-sequencer configuration
	setup_sequencer_configuration

	# Setup fullnode configuration if deployed
	if [[ $DEPLOY_FULLNODE == "true" ]]; then
		setup_fullnode_configuration
	fi

	log "SUCCESS" "All configuration setup completed"
}

# Create shared volume for DA auth token
create_shared_volume() {
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		log "CONFIG" "Creating shared volume for DA auth token..."

		# Create the celestia-node-export volume if it doesn't exist
		if ! docker volume inspect celestia-node-export >/dev/null 2>&1; then
			if ! docker volume create celestia-node-export; then
				error_exit "Failed to create shared volume celestia-node-export"
			fi
			log "SUCCESS" "Created shared volume: celestia-node-export"
		else
			log "INFO" "Shared volume celestia-node-export already exists"
		fi
	fi
}

# Deployment preparation
prepare_deployment() {
	log "DEPLOY" "Preparing deployment files..."

	if [[ $DRY_RUN == "true" ]]; then
		log "INFO" "DRY RUN: Deployment files prepared. Ready to run services"
		return 0
	fi

	# Create shared volume for DA integration
	create_shared_volume

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
		"single-sequencer.Dockerfile"
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
	echo "  📡 Single Sequencer: $DEPLOYMENT_DIR/single-sequencer"

	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		echo "  🌌 Celestia Data Availability: $DEPLOYMENT_DIR/da-celestia"
	fi

	if [[ $SELECTED_SEQUENCER == "single-sequencer" ]]; then
		echo "  📡 Single Sequencer: $DEPLOYMENT_DIR/da-celestia"
	fi

	if [[ $DEPLOY_FULLNODE == "true" ]]; then
		echo "  🔗 Fullnode: $DEPLOYMENT_DIR/fullnode"
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

	if [[ $SELECTED_SEQUENCER == "single-sequencer" ]]; then
		echo "🚀 Start the Sequencer Single Sequencer stack:"
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

	echo "🌐 Service Endpoints:"
	if [[ $SELECTED_SEQUENCER == "single-sequencer" ]]; then
		echo "  📡 Single Sequencer:"
		echo "    - Reth Prometheus Metrics: http://localhost:9000"
		echo "    - Single Sequencer Prometheus Metrics: http://localhost:26660"
	fi

	if [[ $DEPLOY_FULLNODE == "true" ]]; then
		echo "  🔗 Fullnode:"
		echo "    - Reth RPC: http://localhost:8545"
		echo "    - Reth Prometheus Metrics: http://localhost:9002"
        echo "    - Rollkit RPC: http://localhost:7331"
		echo "    - Rollkit Prometheus Metrics: http://localhost:26662"
	fi

	echo ""
	echo "🛠️  Service Management:"
	echo "  - View status: docker compose ps"
	echo "  - View logs: docker compose logs -f"
	echo "  - Stop services: docker compose down"
	echo "  - Restart services: docker compose restart"
	echo ""
	echo "🔍 Health Monitoring:"
	echo "  - Check service status: docker compose ps"
	echo "  - Test endpoints manually using curl"
	echo "  - View service logs: docker compose logs -f"
}

# Usage information
show_usage() {
	cat <<EOF
Usage: $0 [OPTIONS]

Rollkit One-Liner Deployment Script v$SCRIPT_VERSION

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
    curl -fsSL https://raw.githubusercontent.com/rollkit/ops-toolbox/main/ev-stack/deploy-rollkit.sh | bash

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
		if [[ -f "$DEPLOYMENT_DIR/stacks/single-sequencer/docker-compose.yml" ]]; then
			existing_stacks+=("single-sequencer")
		fi

		# Check for existing da-celestia stack
		if [[ -f "$DEPLOYMENT_DIR/stacks/da-celestia/docker-compose.yml" ]]; then
			existing_stacks+=("da-celestia")
		fi
	fi

	# Check for running containers
	if command -v docker >/dev/null 2>&1; then
		local running_containers=()

		# Check for running single-sequencer containers
		if docker ps --format "table {{.Names}}" | grep -E "(sequencer|reth-sequencer|jwt-init)" >/dev/null 2>&1; then
			running_containers+=("single-sequencer")
		fi

		# Check for running da-celestia containers
		if docker ps --format "table {{.Names}}" | grep -E "(celestia-app|celestia-node|da-permission-fix)" >/dev/null 2>&1; then
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
	log "INIT" "Starting Rollkit deployment v$SCRIPT_VERSION"

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

	# Show what will be deployed
	local deployment_info="$SELECTED_SEQUENCER"
	if [[ $DEPLOY_FULLNODE == "true" ]]; then
		deployment_info="$deployment_info + Fullnode"
	fi
	if [[ $DEPLOY_DA_CELESTIA == "true" ]]; then
		deployment_info="$deployment_info + $SELECTED_DA"
	fi
	log "INFO" "Deploying: $deployment_info"

	# Run deployment steps
	download_deployment_files
	setup_configuration
	validate_deployment_files
	prepare_deployment
	show_deployment_status

	log "SUCCESS" "Rollkit deployment setup completed successfully!"

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
		TEMP_SCRIPT=$(mktemp /tmp/deploy-rollkit.XXXXXX.sh)

		# Download the script
		curl -fsSL "https://raw.githubusercontent.com/rollkit/ops-toolbox/main/ev-stack/deploy-rollkit.sh" -o "$TEMP_SCRIPT" || error_exit "Failed to download script"

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
