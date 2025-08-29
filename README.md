# hyperevm-circle-contracts-private

Repository for all HyperEVM contracts developed by Circle

## Deployment

The contracts are deployed using [Forge Scripts](https://book.getfoundry.sh/tutorials/solidity-scripting). The scripts are located in [scripts/](/scripts/).

### CoreDepositWallet

Deploy the CoreDepositWallet implementation, deploy the proxy, and initialize the proxy.

1. Deploy Create2Factory first if not yet deployed. See the [evm-cctp-contracts](https://github.com/circlefin/evm-cctp-contracts) repository for more details.

2. Add the following [env](.env) variables:

   - `CREATE2_FACTORY_CONTRACT_ADDRESS`

   - `TOKEN_CONTRACT_ADDRESS`
   - `TOKEN_SYSTEM_ADDRESS`
   - `CORE_DEPOSIT_WALLET_PROXY_ADMIN_ADDRESS`
   - `CORE_DEPOSIT_WALLET_OWNER_ADDRESS`
   - `CORE_DEPOSIT_WALLET_PAUSER_ADDRESS`
   - `CORE_DEPOSIT_WALLET_RESCUER_ADDRESS`

3. Run `make simulate-deploy-core-deposit-wallet RPC_URL=<RPC_URL> SENDER=<SENDER>` to perform a dry run.

4. Run `make deploy-core-deposit-wallet RPC_URL=<RPC_URL> CREATE2_FACTORY_OWNER_KEY=<CREATE2_FACTORY_OWNER_KEY>` to deploy the CoreDepositWallet implementation, deploy the proxy, and initialize the proxy.

### CctpForwarder

Deploy the CctpForwarder implementation, deploy the proxy, and initialize the proxy.

1. Deploy Create2Factory first if not yet deployed. See the [evm-cctp-contracts](https://github.com/circlefin/evm-cctp-contracts) repository for more details.

2. Add the following [env](.env) variables:

   - `CREATE2_FACTORY_CONTRACT_ADDRESS`

   - `MESSAGE_TRANSMITTER_ADDRESS`
   - `TOKEN_MESSENGER_ADDRESS`
   - `SUPPORTED_MESSAGE_VERSION`
   - `SUPPORTED_BURN_MESSAGE_VERSION`

   - `CCTP_FORWARDER_PROXY_ADMIN_ADDRESS`
   - `CCTP_FORWARDER_OWNER_ADDRESS`
   - `CCTP_FORWARDER_RESCUER_ADDRESS`
   - `CCTP_FORWARDER_TOKEN_ADDRESSES` (comma-separated list of token addresses)
   - `CCTP_FORWARDER_FORWARDING_ADDRESSES` (comma-separated list of forwarding addresses)

3. Run `make simulate-deploy-cctp-forwarder RPC_URL=<RPC_URL> SENDER=<SENDER>` to perform a dry run.

4. Run `make deploy-cctp-forwarder RPC_URL=<RPC_URL> CREATE2_FACTORY_OWNER_KEY=<CREATE2_FACTORY_OWNER_KEY>` to deploy the CctpForwarder implementation, deploy the proxy, and initialize the proxy.

### CctpExtension

Deploy the CctpExtension implementation.

1. Deploy Create2Factory first if not yet deployed. See the [evm-cctp-contracts](https://github.com/circlefin/evm-cctp-contracts) repository for more details.

2. Add the following [env](.env) variables:

   - `CREATE2_FACTORY_CONTRACT_ADDRESS`

   - `CCTP_EXTENSION_OWNER_ADDRESS`
   - `CCTP_EXTENSION_RESCUER_ADDRESS`
   - `TOKEN_MESSENGER_ADDRESS`
   - `TOKEN_CONTRACT_ADDRESS` (ensure only one declaration of `TOKEN_CONTRACT_ADDRESS`)

3. Run `make simulate-deploy-cctp-extension RPC_URL=<RPC_URL> SENDER=<SENDER>` to perform a dry run.

4. Run `make deploy-cctp-extension RPC_URL=<RPC_URL> CREATE2_FACTORY_OWNER_KEY=<CREATE2_FACTORY_OWNER_KEY>` to deploy the CctpExtension implementation.

### Predicting Create2 Deployment Addresses

The [PredictCreate2Deployments.s.sol](scripts/PredictCreate2Deployments.s.sol) script can be used to predict the create2 deployment addresses for the contracts.

- Predicting CoreDepositWallet Proxy: `forge script scripts/PredictCreate2Deployments.s.sol --sig "coreDepositWalletProxy(address)" <create2FactoryAddress>`
- Predicting CctpForwarder Proxy: `forge script scripts/PredictCreate2Deployments.s.sol --sig "cctpForwarderProxy(address)" <create2FactoryAddress>`
- Predicting CctpExtension: `forge script scripts/PredictCreate2Deployments.s.sol --sig "cctpExtension(address)" <create2FactoryAddress>`

- Predicting CoreDepositWallet Implementation: `forge script scripts/PredictCreate2Deployments.s.sol --sig "coreDepositWalletImpl(address,address,address)" <create2FactoryAddress> <tokenContractAddress> <tokenSystemAddress>`
- Predicting CctpForwarder Implementation: `forge script scripts/PredictCreate2Deployments.s.sol --sig "cctpForwarderImpl(address,address,address,uint32,uint32)" <create2FactoryAddress> <messageTransmitterAddress> <tokenMessengerAddress> <supportedMessageVersion> <supportedBurnMessageVersion>`
