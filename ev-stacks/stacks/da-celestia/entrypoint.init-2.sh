#!/bin/bash
# Fail on any error
set -e

# Fail on any error in a pipeline
set -o pipefail

# Fail when using undeclared variables
set -u

# Source shared logging utility
log() {
    level="$1"
    message="$2"
    timestamp=$(date '+%Y-%m-%d %H:%M:%S')

    echo "📝 [$timestamp] $level: $message"
}

log "SUCCESS" "celestia-appd is available: $(which celestia-appd)"

APPD_NODE_CONFIG_PATH=/home/celestia/.celestia-app/config
MONIKER=${MONIKER:-node}

log "INIT" "Starting Celestia App Daemon initialization (Init Container 1)"
log "INFO" "Using moniker: $MONIKER"
log "INFO" "Using DA network: $DA_NETWORK"
log "INFO" "Config path: $APPD_NODE_CONFIG_PATH"

# Check if node is already initialized
if [ ! -f "$APPD_NODE_CONFIG_PATH/app.toml" ]; then
    log "INFO" "Config file does not exist. Initializing the appd node"

    log "INIT" "Initializing celestia-appd with moniker: $MONIKER and chain-id: $DA_NETWORK"
    celestia-appd init ${MONIKER} --chain-id ${DA_NETWORK}
    log "SUCCESS" "celestia-appd initialization completed"

    log "DOWNLOAD" "Downloading genesis file for network: $DA_NETWORK"
    celestia-appd download-genesis ${DA_NETWORK}
    log "SUCCESS" "Genesis file downloaded successfully"

    # Download addrbook
    log "INFO" "Downloading addrbook.json"
    wget -O addrbook.json https://snapshots.polkachu.com/testnet-addrbook/celestia/addrbook.json
    log "SUCCESS" "addrbook.json downloaded"

    log "INFO" "Moving addrbook.json to $APPD_NODE_CONFIG_PATH"
    mv addrbook.json $APPD_NODE_CONFIG_PATH
    log "SUCCESS" "addrbook.json moved to config directory"

    # Configure gRPC server to be accessible from outside container
    log "INFO" "Configuring gRPC server"
    # Enable gRPC server specifically in the [grpc] section
    sed -i '/^\[grpc\]/,/^\[/ { /^enable = false/s/false/true/ }' "$APPD_NODE_CONFIG_PATH/app.toml"
    # Replace localhost:9090 with 0.0.0.0:9090 to make gRPC accessible externally
    sed -i 's/localhost:9090/0.0.0.0:9090/g' "$APPD_NODE_CONFIG_PATH/app.toml"
    log "SUCCESS" "gRPC server enabled and configured to 0.0.0.0:9090"
else
    log "INFO" "Config file already exists at $APPD_NODE_CONFIG_PATH/app.toml"
    log "INFO" "Skipping initialization - node already configured"
fi

log "SUCCESS" "Init container 2 completed"
