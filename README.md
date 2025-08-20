# hyperevm-circle-contracts-private

Repository for all HyperEVM contracts developed by Circle

## Deployment

The contracts are deployed using [Forge Scripts](https://book.getfoundry.sh/tutorials/solidity-scripting). The scripts are located in [scripts/](/scripts/).

### Implementation Contracts

Deploy the implementation contracts.

1. Add the following [env](.env) variables:

   - `TOKEN_CONTRACT_ADDRESS`
   - `TOKEN_SYSTEM_ADDRESS`
   - `MESSAGE_TRANSMITTER_ADDRESS`
   - `SUPPORTED_MESSAGE_VERSION`
   - `SUPPORTED_BURN_MESSAGE_VERSION`

2. Run `make simulate-deploy-implementations RPC_URL=<RPC_URL> SENDER=<SENDER> IMPLEMENTATION_DEPLOYER_KEY=<IMPLEMENTATION_DEPLOYER_KEY>` to perform a dry run.

3. Run `make deploy-implementations RPC_URL=<RPC_URL> SENDER=<SENDER> IMPLEMENTATION_DEPLOYER_KEY=<IMPLEMENTATION_DEPLOYER_KEY>` to deploy the CoreDepositWallet and CctpForwarder implementations.

### Proxy Contracts

Deploy and initialize the proxy contracts.

1. Add the following [env](.env) variables:

   - `CORE_DEPOSIT_WALLET_IMPLEMENTATION_ADDRESS`
   - `CORE_DEPOSIT_WALLET_PROXY_ADMIN_ADDRESS`
   - `CORE_DEPOSIT_WALLET_OWNER_ADDRESS`
   - `CORE_DEPOSIT_WALLET_PAUSER_ADDRESS`
   - `CORE_DEPOSIT_WALLET_RESCUER_ADDRESS`

   - `CCTP_FORWARDER_IMPLEMENTATION_ADDRESS`
   - `CCTP_FORWARDER_PROXY_ADMIN_ADDRESS`
   - `CCTP_FORWARDER_OWNER_ADDRESS`
   - `CCTP_FORWARDER_RESCUER_ADDRESS`
   - `CCTP_FORWARDER_TOKEN_ADDRESS`
   - `CCTP_FORWARDER_FORWARDING_ADDRESS`

2. Run `make simulate-deploy-proxies RPC_URL=<RPC_URL> SENDER=<SENDER> PROXY_DEPLOYER_KEY=<PROXY_DEPLOYER_KEY>` to perform a dry run.

3. Run `make deploy-proxies RPC_URL=<RPC_URL> SENDER=<SENDER> PROXY_DEPLOYER_KEY=<PROXY_DEPLOYER_KEY>` to deploy and initialize the proxy contracts.
