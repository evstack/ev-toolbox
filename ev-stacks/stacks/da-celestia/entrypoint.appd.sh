#!/bin/bash
# Fail on any error
set -e

# Fail on any error in a pipeline
set -o pipefail

# Fail when using undeclared variables
set -u

# Source shared logging utility
. /usr/local/lib/logging.sh

# Check if celestia-appd is available and executable
if ! command -v celestia-appd >/dev/null 2>&1; then
    log "ERROR" "celestia-appd command not found in PATH"
    log "DEBUG" "Current PATH: $PATH"
    log "DEBUG" "Looking for celestia-appd in common locations..."

    # Check common locations
    for path in /usr/local/bin/celestia-appd /usr/bin/celestia-appd /bin/celestia-appd /home/celestia/celestia-appd; do
        if [[ -f "$path" ]]; then
            log "DEBUG" "Found celestia-appd at: $path"
            if [[ -x "$path" ]]; then
                log "SUCCESS" "celestia-appd is executable at: $path"
                # Create symlink if not in PATH
                if [[ ! -L /usr/local/bin/celestia-appd ]]; then
                    ln -sf "$path" /usr/local/bin/celestia-appd
                    log "SUCCESS" "Created symlink for celestia-appd"
                fi
                break
            else
                log "WARNING" "celestia-appd found but not executable at: $path"
            fi
        fi
    done

    # Final check
    if ! command -v celestia-appd >/dev/null 2>&1; then
        log "ERROR" "celestia-appd still not available after search"
        exit 1
    fi
fi

log "SUCCESS" "celestia-appd is available: $(which celestia-appd)"

APPD_NODE_CONFIG_PATH=$HOME/config/app.toml
MONIKER=${MONIKER:-node}

log "INIT" "Starting Celestia App Daemon initialization"
log "INFO" "Using moniker: $MONIKER"
log "INFO" "Using DA network: $DA_NETWORK"
log "INFO" "Config path: $APPD_NODE_CONFIG_PATH"

# Initializing the app node
if [ ! -f "$APPD_NODE_CONFIG_PATH" ]; then
    log "INFO" "Config file does not exist. Initializing the appd node"

    log "INIT" "Initializing celestia-appd with moniker: $MONIKER and chain-id: $DA_NETWORK"
    celestia-appd init ${MONIKER} --chain-id ${DA_NETWORK}
    log "SUCCESS" "celestia-appd initialization completed"

    log "DOWNLOAD" "Downloading genesis file for network: $DA_NETWORK"
    celestia-appd download-genesis ${DA_NETWORK}
    log "SUCCESS" "Genesis file downloaded successfully"

    # Seeds
    log "INFO" "Fetching seeds configuration"
    SEEDS=$(curl -sL https://raw.githubusercontent.com/celestiaorg/networks/master/${DA_NETWORK}/seeds.txt | tr '\n' ',')
    log "SUCCESS" "Seeds fetched: $SEEDS"

    log "INFO" "Updating seeds configuration in config.toml"
    # Escape special characters in SEEDS for sed
    SEEDS_ESCAPED=$(printf '%s\n' "$SEEDS" | sed 's/[[\.*^$()+?{|]/\\&/g')
    sed -i.bak -e "s/^seeds *=.*/seeds = \"$SEEDS_ESCAPED\"/" /home/celestia/.celestia-app/config/config.toml
    log "SUCCESS" "Seeds configuration updated"

    # Quick sync
    log "INFO" "Preparing for quick sync - cleaning existing data"
    rm -rf /home/celestia/.celestia-app/data
    mkdir -p /home/celestia/.celestia-app/data
    log "SUCCESS" "Data directory prepared"

    log "INFO" "Fetching snapshot information"
    snapshot_url="${SNAPSHOT_URL:-https://server-6.itrocket.net/testnet/celestia/.current_state.json}"
    log "DOWNLOAD" "Fetching snapshot metadata from: $snapshot_url"

    if ! response=$(curl -fsSL "$snapshot_url" 2>/dev/null); then
        log "ERROR" "Failed to fetch snapshot information from $snapshot_url"
        exit 1
    fi
    log "SUCCESS" "Snapshot metadata fetched successfully"

    # Extract snapshot name using jq
    log "INFO" "Parsing snapshot information"
    if ! snapshot_name=$(echo "$response" | jq -r '.snapshot_name // empty' 2>/dev/null); then
        log "ERROR" "Failed to parse JSON response with jq"
        exit 1
    fi

    if [[ -z "$snapshot_name" || "$snapshot_name" == "null" ]]; then
        log "ERROR" "Snapshot name not found in response"
        exit 1
    fi

    log "SUCCESS" "Found snapshot: $snapshot_name"

    # Download snapshot using curl instead of aria2c
    snapshot_download_url="https://server-6.itrocket.net/testnet/celestia/$snapshot_name"
    log "DOWNLOAD" "Downloading snapshot from: $snapshot_download_url"
    log "INFO" "This may take several minutes depending on your connection speed..."

    if ! curl -fL --progress-bar -o /tmp/celestia-archive-snap.tar.lz4 "$snapshot_download_url"; then
        log "ERROR" "Failed to download snapshot from $snapshot_download_url"
        exit 1
    fi
    log "SUCCESS" "Snapshot downloaded successfully to /tmp/celestia-archive-snap.tar.lz4"

    log "INFO" "Extracting snapshot archive"
    # Use lz4 to decompress and pipe to tar (BusyBox compatible)
    if ! lz4 -dc /tmp/celestia-archive-snap.tar.lz4 | tar -xvf - -C $HOME; then
        log "ERROR" "Failed to extract snapshot archive"
        exit 1
    fi
    log "SUCCESS" "Snapshot extracted successfully"

    log "INFO" "Cleaning up temporary files"
    rm /tmp/celestia-archive-snap.tar.lz4
    log "SUCCESS" "Temporary files cleaned up"

else
    log "INFO" "Config file already exists at $APPD_NODE_CONFIG_PATH"
    log "INFO" "Skipping initialization - node already configured"
fi

# Configure gRPC server to be accessible from outside container
log "INFO" "Configuring gRPC server"
if [[ -f "$APPD_NODE_CONFIG_PATH" ]]; then
    # Enable gRPC server specifically in the [grpc] section
    sed -i '/^\[grpc\]/,/^\[/ { /^enable = false/s/false/true/ }' "$APPD_NODE_CONFIG_PATH"
    # Replace localhost:9090 with 0.0.0.0:9090 to make gRPC accessible externally
    sed -i 's/localhost:9090/0.0.0.0:9090/g' "$APPD_NODE_CONFIG_PATH"
    log "SUCCESS" "gRPC server enabled and configured to 0.0.0.0:9090"
else
    log "WARNING" "Config file not found, skipping gRPC configuration"
fi

log "INIT" "Starting celestia-appd with chain-id: $DA_NETWORK"
log "INFO" "Node is now starting up..."
celestia-appd start
