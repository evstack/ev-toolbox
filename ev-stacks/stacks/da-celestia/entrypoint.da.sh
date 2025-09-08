#!/bin/bash
# Fail on any error
set -e

# Fail on any error in a pipeline
set -o pipefail

# Fail when using undeclared variables
set -u

# Source shared logging utility
. /usr/local/lib/logging.sh

LIGHT_NODE_CONFIG_PATH=/home/celestia/config.toml
TOKEN_PATH=${VOLUME_EXPORT_PATH}/auth_token

log "INIT" "Starting Celestia Light Node initialization"
log "INFO" "Light node config path: $LIGHT_NODE_CONFIG_PATH"
log "INFO" "Token export path: $TOKEN_PATH"
log "INFO" "DA Core IP: ${DA_CORE_IP}"
log "INFO" "DA Core Port: ${DA_CORE_PORT}"
log "INFO" "DA Network: ${DA_NETWORK}"
log "INFO" "DA RPC Port: ${DA_RPC_PORT}"

# Initializing the light node
if [ ! -f "$LIGHT_NODE_CONFIG_PATH" ]; then
    log "INFO" "Config file does not exist. Initializing the light node"

    log "INIT" "Initializing celestia light node with network: ${DA_NETWORK}"
    if ! celestia light init \
        "--core.ip=${DA_CORE_IP}" \
        "--core.port=${DA_CORE_PORT}" \
        "--p2p.network=${DA_NETWORK}"; then
        log "ERROR" "Failed to initialize celestia light node"
        exit 1
    fi
    log "SUCCESS" "Celestia light node initialization completed"

    # Get latest block and update trusted hash
    log "CONFIG" "Setting up trusted hash from latest block"
    consensus_url="https://full.consensus.mocha-4.celestia-mocha.com/block"
    log "DOWNLOAD" "Fetching latest block information from: $consensus_url"

    # Fetch block information with proper error handling
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
    if ! latest_block=$(echo "$block_response" | jq -r '.result.block.header.height' 2>&1); then
        log "ERROR" "Failed to parse block height from response: $latest_block"
        exit 1
    fi

    # Parse block hash with error handling
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

    log "CONFIG" "Updating configuration with latest trusted state"

    # Escape special characters for sed
    latest_hash_escaped=$(printf '%s\n' "$latest_hash" | sed 's/[[\.*^$()+?{|]/\\&/g')
    latest_block_escaped=$(printf '%s\n' "$latest_block" | sed 's/[[\.*^$()+?{|]/\\&/g')

    if ! sed -i.bak \
        -e "s/\(TrustedHash[[:space:]]*=[[:space:]]*\).*/\1\"$latest_hash_escaped\"/" \
        -e "s/\(SampleFrom[[:space:]]*=[[:space:]]*\).*/\1$latest_block_escaped/" \
        "$LIGHT_NODE_CONFIG_PATH"; then
        log "ERROR" "Failed to update config with latest trusted state"
        exit 1
    fi
    log "SUCCESS" "Config updated with latest trusted state"

    # Update DASer.SampleFrom
    log "CONFIG" "Updating DASer.SampleFrom to: $latest_block"
    if ! sed -i 's/^[[:space:]]*SampleFrom = .*/  SampleFrom = '$latest_block'/' "$LIGHT_NODE_CONFIG_PATH"; then
        log "ERROR" "Failed to update DASer.SampleFrom"
        exit 1
    fi
    log "SUCCESS" "DASer.SampleFrom updated successfully"

    # Update Header.TrustedHash
    log "CONFIG" "Updating Header.TrustedHash to: $latest_hash"
    # Escape special characters for sed
    latest_hash_ESCAPED=$(printf '%s\n' "$latest_hash" | sed 's/[[\.*^$()+?{|]/\\&/g')
    if ! sed -i 's/^[[:space:]]*TrustedHash = .*/  TrustedHash = "'"$latest_hash_ESCAPED"'"/' "$LIGHT_NODE_CONFIG_PATH"; then
        log "ERROR" "Failed to update Header.TrustedHash"
        exit 1
    fi
    log "SUCCESS" "Header.TrustedHash updated successfully"

    log "SUCCESS" "Configuration completed - Trusted height: $latest_block, Trusted hash: $latest_hash"


else
    log "INFO" "Config file already exists at $LIGHT_NODE_CONFIG_PATH"
    log "INFO" "Skipping initialization - light node already configured"
fi

# Export AUTH_TOKEN to shared volume
log "AUTH" "Generating and exporting auth token to: $TOKEN_PATH"

if ! TOKEN=$(celestia light auth write "--p2p.network=${DA_NETWORK}"); then
    log "ERROR" "Failed to generate auth token"
    exit 1
fi
log "SUCCESS" "Auth token generated successfully"

log "INFO" "Writing auth token to shared volume"
if ! echo "${TOKEN}" > ${TOKEN_PATH}; then
    log "ERROR" "Failed to write auth token to $TOKEN_PATH"
    exit 1
fi
log "SUCCESS" "Auth token exported to $TOKEN_PATH"

log "INIT" "Starting Celestia light node"
log "INFO" "Light node will be accessible on RPC port: ${DA_RPC_PORT}"
log "INFO" "Starting with skip-auth enabled for RPC access"

celestia light start \
    "--core.ip=${DA_CORE_IP}" \
    "--core.port=${DA_CORE_PORT}" \
    "--p2p.network=${DA_NETWORK}" \
    --rpc.addr=0.0.0.0 \
    "--rpc.port=${DA_RPC_PORT}" \
    --rpc.skip-auth
