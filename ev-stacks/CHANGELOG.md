# Changelog

All notable changes to the EV-Stacks deployment framework will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.6.0] - 2025-09-12

### Changed
- **Ev-reth Flag**: More performance on ev-reth
  - Added launch argument `--engine.always-process-payload-attributes-on-canonical-head`

## [1.5.0] - 2025-09-08

### Added
- **Dynamic Celestia Start Height Configuration**: Automatic fetching and setting of start height from latest Celestia block at the time of deployment

### Fixed
- **DA Namespace Flag**: Corrected flag usage in sequencer and fullnode entrypoints
  - Changed from `--rollkit.da.header_namespace` back to `--rollkit.da.namespace` for proper compatibility

## [1.4.2] - 2025-09-08

### Fixed
- **Fullnode deployment script**: `entrypoint.ev-reth.sh` is now properly deployed and made executable
- **Celestia DA initialization**: Improved trusted state management with dynamic latest block fetching during initial setup only

### Changed
- **Dependencies**:
  - da-celestia: Use `ghcr.io/celestiaorg/celestia-app` instead of `ghcr.io/celestiaorg/celestia-app-standalone`

### Improved
- **Deployment script**: Removed unnecessary shared volume creation logic for cleaner deployment process

## [1.4.1] - 2025-09-02

### Fixed
- **Fullnode deployment script**: `entrypoint.ev-reth.sh` is now deployed as intended

## [1.4.0] - 2025-09-01

### Changed
- **Dependencies**:
  - Upgraded ghcr.io/celestiaorg/celestia-node to `v0.25.3-mocha`
  - Upgraded ghcr.io/celestiaorg/celestia-app-standalone to `v5.0.2-mocha`

## [1.3.0] - 2025-09-01

### Added
- **Ethereum Indexer Service**: New `eth-indexer` stack for blockchain data indexing
  - Based on [01builders/eth-indexer](https://github.com/01builders/eth-indexer)
  - Ponder-based indexing service for efficient blockchain data processing
  - PostgreSQL database integration for indexed data storage
  - GraphQL API endpoint for querying indexed blockchain data
  - Configurable indexer port and database credentials
  - Health checks and service dependencies for reliable operation
  - Users can fork the repository to add custom indexing use cases

## [1.2.1] - 2025-08-27

### Fixed
- **Transactions can now be submitted to the fullnode**: ev-reth-fullnode now connects to ev-reth-sequencer as a trusted peer

## [1.2.0] - 2025-08-25

### Added
- **Local Data Availability (DA) Support**: New `da-local` stack for development and testing environments
  - Lightweight local DA layer that doesn't require external dependencies
  - Ideal for rapid development and testing scenarios
- **Ethereum Faucet Service**: New `eth-faucet` stack for easy token distribution
  - Web-based interface for distributing test tokens
  - Configurable private key management for faucet operations
- **Blockchain Explorer Service**: New `eth-explorer` stack powered by Blockscout
  - Complete blockchain exploration capabilities
  - PostgreSQL database integration for data persistence
  - Automatic secret key generation with security disclaimers
  - Chain ID synchronization with sequencer configuration
  - Web interface for exploring transactions, blocks, and addresses
- **Enhanced DA Layer Selection**: Interactive deployment script now supports choosing between:
  - Local DA for development (`da-local`)
  - Celestia DA for production (`da-celestia`)
- **Integrated Docker Compose Files**: New DA-specific compose files for better integration
  - `docker-compose.da.local.yml` for local DA integration
  - `docker-compose.da.celestia.yml` for Celestia DA integration
  - Automatic selection based on chosen DA layer

### Changed
- **Deployment Script Enhancements**:
  - Improved service endpoint documentation in deployment status

### Removed
- **Custom Dockerfile Cleanup**: Removed custom `ev-node-evm-single` Dockerfile in favor of standardized configurations

### Technical Details
- The deployment script now supports up to 6 different service stacks:
  - Single Sequencer (required)
  - Fullnode (optional)
  - DA Celestia (optional)
  - DA Local (optional)
  - Eth-Faucet (optional)
  - Eth-Explorer (optional)

### Migration Guide
Users upgrading from version 1.1.0 can:
1. Run the updated deployment script to access new service options
2. Choose to deploy additional services (faucet, explorer, local DA) alongside existing infrastructure
3. Existing deployments remain fully compatible with no breaking changes

## [1.1.0] - 2025-08-12

### Added
- Support for separate header and data namespaces in Celestia DA integration
- New environment variables `DA_HEADER_NAMESPACE` and `DA_DATA_NAMESPACE`
- Enhanced deployment script prompts for both namespace configurations
- Improved validation for both header and data namespace inputs
- Added `--ev-reth.enable` flag to ev-reth node configurations for proper integration

### Changed
- **BREAKING**: Replaced single `DA_NAMESPACE` environment variable with two separate variables:
  - `DA_HEADER_NAMESPACE` - for header blob categorization on Celestia
  - `DA_DATA_NAMESPACE` - for data blob categorization on Celestia
- **BREAKING**: Changed namespace format from 58-character hex strings to encoded string identifiers:
  - Old format: `000000000000000000000000000000000000002737d4d967c7ca526dd5`
  - New format: `namespace_test_header` or `namespace_test_data`
- Updated Rollkit flags to use new namespace parameters:
  - `--rollkit.da.namespace` → `--rollkit.da.header_namespace` and `--rollkit.da.data_namespace`
- Component naming updates to reflect current project names:
  - Rollkit → Ev-node (consensus layer)
  - Lumen → Ev-reth (execution layer)
- Updated all Docker Compose files to use the new namespace environment variables
- Enhanced deployment script configuration management for namespace propagation
- Updated documentation and examples to reflect the new namespace structure

### Removed
- **BREAKING**: Removed deprecated `DA_NAMESPACE` environment variable
- **BREAKING**: Removed deprecated `--chain_id` flag from ev-node start command
- Removed all references to the old single namespace configuration

### Migration Guide
If you are upgrading from version 1.0.0:

1. **Update Environment Variables**: Replace `DA_NAMESPACE` with both `DA_HEADER_NAMESPACE` and `DA_DATA_NAMESPACE` in your `.env` files
2. **Update Namespace Format**: Convert from 58-character hex strings to encoded string identifiers
3. **Namespace Values**: You can use similar namespace identifiers for both header and data, or specify different namespaces for separation
4. **Redeploy**: Run the deployment script again to ensure all configurations are updated with the new namespace variables

Example migration:
```bash
# Before (v1.0.0)
DA_NAMESPACE="000000000000000000000000000000000000002737d4d967c7ca526dd5"

# After (v1.1.0)
DA_HEADER_NAMESPACE="namespace_test_header"
DA_DATA_NAMESPACE="namespace_test_data"
```

### Technical Details
- The deployment script now prompts users to enter both namespace values separately during setup
- Both namespaces undergo validation for encoded string format (alphanumeric characters, underscores, and hyphens)
- The script automatically propagates namespace values from da-celestia configuration to sequencer and fullnode configurations
- All entrypoint scripts have been updated to handle the new namespace flags correctly

## [1.0.0] - 2025-07-31

### Added
- Initial release of EV-Stacks deployment framework
- Single sequencer deployment stack
- Celestia DA integration support
- Fullnode deployment option
- Interactive deployment script with guided setup
- Docker Compose based deployment architecture
- Automated configuration management
- Genesis block customization
- JWT token generation and management
- Comprehensive documentation and examples

### Features
- One-liner deployment script for easy setup
- Support for Celestia mocha-4 testnet integration
- Automatic service dependency management
- Health monitoring and logging capabilities
- Backup and recovery procedures
- Service management commands
- Network endpoint configuration
