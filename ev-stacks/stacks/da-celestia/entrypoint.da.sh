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
log "INFO" "DA Trusted Height: ${DA_TRUSTED_HEIGHT}"
log "INFO" "DA Trusted Hash: ${DA_TRUSTED_HASH}"

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

    log "CONFIG" "Updating configuration with latest trusted state"

    if ! sed -i.bak \
        -e "s/\(TrustedHash[[:space:]]*=[[:space:]]*\).*/\1\"$DA_TRUSTED_HASH\"/" \
        -e "s/\(SampleFrom[[:space:]]*=[[:space:]]*\).*/\1$DA_TRUSTED_HEIGHT/" \
        "$LIGHT_NODE_CONFIG_PATH"; then
        log "ERROR" "Failed to update config with latest trusted state"
        exit 1
    fi
    log "SUCCESS" "Config updated with latest trusted state"

    # Update DASer.SampleFrom
    log "CONFIG" "Updating DASer.SampleFrom to: $DA_TRUSTED_HEIGHT"
    if ! sed -i 's/^[[:space:]]*SampleFrom = .*/  SampleFrom = '$DA_TRUSTED_HEIGHT'/' "$LIGHT_NODE_CONFIG_PATH"; then
        log "ERROR" "Failed to update DASer.SampleFrom"
        exit 1
    fi
    log "SUCCESS" "DASer.SampleFrom updated successfully"

    # Update Header.TrustedHash
    log "CONFIG" "Updating Header.TrustedHash to: $DA_TRUSTED_HASH"
    # Escape special characters for sed
    TRUSTED_HASH_ESCAPED=$(printf '%s\n' "$DA_TRUSTED_HASH" | sed 's/[[\.*^$()+?{|]/\\&/g')
    if ! sed -i 's/^[[:space:]]*TrustedHash = .*/  TrustedHash = "'"$TRUSTED_HASH_ESCAPED"'"/' "$LIGHT_NODE_CONFIG_PATH"; then
        log "ERROR" "Failed to update Header.TrustedHash"
        exit 1
    fi
    log "SUCCESS" "Header.TrustedHash updated successfully"

    log "SUCCESS" "Configuration completed - Trusted height: $DA_TRUSTED_HEIGHT, Trusted hash: $DA_TRUSTED_HASH"


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
