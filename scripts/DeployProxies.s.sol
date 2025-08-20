/*
 * Copyright 2025 Circle Internet Group, Inc. All rights reserved.
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *      http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
pragma solidity 0.7.6;
pragma abicoder v2;

import {AdminUpgradableProxy} from "@evm-cctp-contracts/proxy/AdminUpgradableProxy.sol";
import {Script} from "forge-std/Script.sol";
import {CctpForwarder} from "../src/CctpForwarder.sol";
import {CoreDepositWallet} from "../src/CoreDepositWallet.sol";

contract DeployProxiesScript is Script {
    // Expose for tests
    CoreDepositWallet public coreDepositWallet;
    CctpForwarder public cctpForwarder;

    uint256 private proxyDeployerKey;

    // CoreDepositWallet
    address private coreDepositWalletImplementation;
    address private coreDepositWalletProxyAdminAddress;
    address private coreDepositWalletOwnerAddress;
    address private coreDepositWalletPauserAddress;
    address private coreDepositWalletRescuerAddress;

    // CctpForwarder
    address private cctpForwarderImplementation;
    address private cctpForwarderProxyAdminAddress;
    address private cctpForwarderOwnerAddress;
    address private cctpForwarderRescuerAddress;
    address[] private cctpForwarderTokens = new address[](1);
    address[] private cctpForwarderForwardingAddresses = new address[](1);

    function deployCoreDepositWallet() private {
        // Construct initializer
        bytes memory initializer = abi.encodeWithSelector(
            CoreDepositWallet.initialize.selector,
            CoreDepositWallet.CoreDepositWalletRoles({
                owner: coreDepositWalletOwnerAddress,
                pauser: coreDepositWalletPauserAddress,
                rescuer: coreDepositWalletRescuerAddress
            })
        );

        // Start recording transactions
        vm.startBroadcast(proxyDeployerKey);

        coreDepositWallet = CoreDepositWallet(
            address(
                new AdminUpgradableProxy(
                    coreDepositWalletImplementation,
                    coreDepositWalletProxyAdminAddress,
                    initializer
                )
            )
        );

        // Stop recording transactions
        vm.stopBroadcast();
    }

    function deployCctpForwarder() private {
        // Construct initializer
        bytes memory initializer = abi.encodeWithSelector(
            CctpForwarder.initialize.selector,
            CctpForwarder.CctpForwarderRoles({
                owner: cctpForwarderOwnerAddress,
                rescuer: cctpForwarderRescuerAddress
            }),
            cctpForwarderTokens,
            cctpForwarderForwardingAddresses
        );

        // Start recording transactions
        vm.startBroadcast(proxyDeployerKey);

        cctpForwarder = CctpForwarder(
            address(
                new AdminUpgradableProxy(
                    cctpForwarderImplementation,
                    cctpForwarderProxyAdminAddress,
                    initializer
                )
            )
        );

        // Stop recording transactions
        vm.stopBroadcast();
    }

    /**
     * @notice initialize variables from environment
     */
    function setUp() public {
        proxyDeployerKey = vm.envUint("PROXY_DEPLOYER_KEY");

        // CoreDepositWallet init params
        coreDepositWalletImplementation = vm.envAddress(
            "CORE_DEPOSIT_WALLET_IMPLEMENTATION_ADDRESS"
        );
        coreDepositWalletProxyAdminAddress = vm.envAddress(
            "CORE_DEPOSIT_WALLET_PROXY_ADMIN_ADDRESS"
        );
        coreDepositWalletOwnerAddress = vm.envAddress(
            "CORE_DEPOSIT_WALLET_OWNER_ADDRESS"
        );
        coreDepositWalletPauserAddress = vm.envAddress(
            "CORE_DEPOSIT_WALLET_PAUSER_ADDRESS"
        );
        coreDepositWalletRescuerAddress = vm.envAddress(
            "CORE_DEPOSIT_WALLET_RESCUER_ADDRESS"
        );

        // CctpForwarder init params
        cctpForwarderImplementation = vm.envAddress(
            "CCTP_FORWARDER_IMPLEMENTATION_ADDRESS"
        );
        cctpForwarderProxyAdminAddress = vm.envAddress(
            "CCTP_FORWARDER_PROXY_ADMIN_ADDRESS"
        );
        cctpForwarderOwnerAddress = vm.envAddress(
            "CCTP_FORWARDER_OWNER_ADDRESS"
        );
        cctpForwarderRescuerAddress = vm.envAddress(
            "CCTP_FORWARDER_RESCUER_ADDRESS"
        );
        cctpForwarderTokens[0] = vm.envAddress("CCTP_FORWARDER_TOKEN_ADDRESS");
        cctpForwarderForwardingAddresses[0] = vm.envAddress(
            "CCTP_FORWARDER_FORWARDING_ADDRESS"
        );
    }

    /**
     * @notice main function that will be run by forge
     */
    function run() public {
        deployCoreDepositWallet();
        deployCctpForwarder();
    }
}
