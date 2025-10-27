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

import {Script} from "forge-std/Script.sol";
import {Create2Factory} from "@evm-cctp-contracts/v2/Create2Factory.sol";
import {AdminUpgradableProxy} from "@evm-cctp-contracts/proxy/AdminUpgradableProxy.sol";
import {CoreDepositWallet} from "../src/CoreDepositWallet.sol";
import {SALT_CORE_DEPOSIT_WALLET} from "./Salts.sol";

contract DeployCoreDepositWalletScript is Script {
    // Expose for tests
    CoreDepositWallet public coreDepositWalletImpl;
    CoreDepositWallet public coreDepositWallet;

    Create2Factory public create2Factory;

    // Constructor arguments
    address private tokenContractAddress;
    address private tokenSystemAddress;
    address private tokenMessengerAddress;

    // Init params
    address private coreDepositWalletProxyAdminAddress;
    address private coreDepositWalletOwnerAddress;
    address private coreDepositWalletPauserAddress;
    address private coreDepositWalletRescuerAddress;

    function deployImplementation() private {
        // Start recording transactions
        vm.startBroadcast(create2Factory.owner());

        // Deploy CoreDepositWallet
        coreDepositWalletImpl = CoreDepositWallet(
            create2Factory.deploy(
                0,
                SALT_CORE_DEPOSIT_WALLET,
                abi.encodePacked(
                    type(CoreDepositWallet).creationCode,
                    abi.encode(tokenContractAddress, tokenSystemAddress, tokenMessengerAddress)
                )
            )
        );

        // Stop recording transactions
        vm.stopBroadcast();
    }

    function deployProxy() private {
        // Get proxy creation code
        bytes memory proxyCreateCode = abi.encodePacked(
            type(AdminUpgradableProxy).creationCode,
            abi.encode(create2Factory, create2Factory, "")
        );

        // Construct initializer
        bytes memory initializer = abi.encodeWithSelector(
            CoreDepositWallet.initialize.selector,
            CoreDepositWallet.CoreDepositWalletRoles({
                owner: coreDepositWalletOwnerAddress,
                pauser: coreDepositWalletPauserAddress,
                rescuer: coreDepositWalletRescuerAddress
            })
        );

        // Construct upgrade and initialize data
        bytes memory upgradeAndInitializeData = abi.encodeWithSelector(
            AdminUpgradableProxy.upgradeToAndCall.selector,
            coreDepositWalletImpl,
            initializer
        );

        // Construct admin rotation data
        bytes memory adminRotationData = abi.encodeWithSelector(
            AdminUpgradableProxy.changeAdmin.selector,
            coreDepositWalletProxyAdminAddress
        );

        bytes[] memory multiCallData = new bytes[](2);
        multiCallData[0] = upgradeAndInitializeData;
        multiCallData[1] = adminRotationData;

        // Start recording transactions
        vm.startBroadcast(create2Factory.owner());

        coreDepositWallet = CoreDepositWallet(
            create2Factory.deployAndMultiCall(
                0,
                SALT_CORE_DEPOSIT_WALLET,
                proxyCreateCode,
                multiCallData
            )
        );

        // Stop recording transactions
        vm.stopBroadcast();
    }

    /**
     * @notice initialize variables from environment
     */
    function setUp() public {
        create2Factory = Create2Factory(
            vm.envAddress("CREATE2_FACTORY_CONTRACT_ADDRESS")
        );

        // CoreDepositWallet constructor arguments
        tokenContractAddress = vm.envAddress("TOKEN_CONTRACT_ADDRESS");
        tokenSystemAddress = vm.envAddress("TOKEN_SYSTEM_ADDRESS");
        tokenMessengerAddress = vm.envAddress("TOKEN_MESSENGER_ADDRESS");

        // CoreDepositWallet init params
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
    }

    /**
     * @notice main function that will be run by forge
     */
    function run() public {
        deployImplementation();
        deployProxy();
    }
}
