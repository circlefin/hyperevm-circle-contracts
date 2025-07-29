.PHONY: build test anvil clean

FOUNDRY := docker run --rm foundry
ANVIL 	:= docker run -d -p 8545:8545 --name anvil --rm foundry

build:
	docker build --no-cache -f Dockerfile -t foundry .

test:
	@${FOUNDRY} "forge test -vv"

anvil:
	docker rm -f anvil || true
	@${ANVIL} "anvil --host 0.0.0.0 -a 10 --code-size-limit 250000"

clean:
	@${FOUNDRY} "forge clean"

simulate-deploy-core-deposit-wallet:
	forge script scripts/DeployCoreDepositWallet.s.sol:DeployCoreDepositWalletScript --rpc-url ${RPC_URL} --sender ${SENDER}

deploy-core-deposit-wallet:
	forge script scripts/DeployCoreDepositWallet.s.sol:DeployCoreDepositWalletScript --rpc-url ${RPC_URL} --private-key ${CREATE2_FACTORY_OWNER_KEY} --broadcast

simulate-deploy-cctp-forwarder:
	forge script scripts/DeployCctpForwarder.s.sol:DeployCctpForwarderScript --rpc-url ${RPC_URL} --sender ${SENDER}

deploy-cctp-forwarder:
	forge script scripts/DeployCctpForwarder.s.sol:DeployCctpForwarderScript --rpc-url ${RPC_URL} --private-key ${CREATE2_FACTORY_OWNER_KEY} --broadcast

simulate-deploy-cctp-extension:
	forge script scripts/DeployCctpExtension.s.sol:DeployCctpExtensionScript --rpc-url ${RPC_URL} --sender ${SENDER}

deploy-cctp-extension:
	forge script scripts/DeployCctpExtension.s.sol:DeployCctpExtensionScript --rpc-url ${RPC_URL} --private-key ${CREATE2_FACTORY_OWNER_KEY} --broadcast