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

if [ ! -f /home/celestia/.celestia-app/_created_by_init_script ]; then
    apk add --no-cache lz4

    APPD_NODE_DATA_PATH=/home/celestia/.celestia-app/data

    log "INIT" "Starting snapshot download and configuration (Init Container 2)"

    # Quick sync - prepare data directory
    log "INFO" "Preparing for quick sync - cleaning existing data"
    rm -rf $APPD_NODE_DATA_PATH
    mkdir -p $APPD_NODE_DATA_PATH
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

    # Download snapshot using curl
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
    if ! lz4 -dc /tmp/celestia-archive-snap.tar.lz4 | tar -xvf - -C /home/celestia/.celestia-app; then
        log "ERROR" "Failed to extract snapshot archive"
        exit 1
    fi
    log "SUCCESS" "Snapshot extracted successfully"

    chown -R 10001  /home/celestia/.celestia-app/data

    log "INFO" "Cleaning up temporary files"
    rm /tmp/celestia-archive-snap.tar.lz4
    log "SUCCESS" "Temporary files cleaned up"

    log "SUCCESS" "Init container 3 completed"
    touch /home/celestia/.celestia-app/_created_by_init_script

fi
