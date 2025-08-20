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

simulate-deploy-implementations:
	forge script scripts/DeployImplementations.s.sol:DeployImplementationsScript --rpc-url ${RPC_URL} --sender ${SENDER}

deploy-implementations:
	forge script scripts/DeployImplementations.s.sol:DeployImplementationsScript --rpc-url ${RPC_URL} --sender ${SENDER} --broadcast

simulate-deploy-proxies:
	forge script scripts/DeployProxies.s.sol:DeployProxiesScript --rpc-url ${RPC_URL} --sender ${SENDER}

deploy-proxies:
	forge script scripts/DeployProxies.s.sol:DeployProxiesScript --rpc-url ${RPC_URL} --sender ${SENDER} --broadcast
