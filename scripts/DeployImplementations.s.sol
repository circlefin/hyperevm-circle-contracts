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

import {Script} from "forge-std/Script.sol";
import {CctpForwarder} from "../src/CctpForwarder.sol";
import {CoreDepositWallet} from "../src/CoreDepositWallet.sol";

contract DeployImplementationsScript is Script {
    // Expose for tests
    CoreDepositWallet public coreDepositWalletImpl;
    CctpForwarder public cctpForwarderImpl;

    // CoreDepositWallet constructor arguments
    address private tokenContractAddress;
    address private tokenSystemAddress;

    // CctpForwarder constructor arguments
    uint256 private implementationDeployerKey;
    address private messageTransmitter;
    uint32 private supportedMessageVersion;
    uint32 private supportedBurnMessageVersion;

    function deployImplementations() private {
        // Start recording transactions
        vm.startBroadcast(implementationDeployerKey);

        // Deploy CoreDepositWallet
        coreDepositWalletImpl = new CoreDepositWallet(
            tokenContractAddress,
            tokenSystemAddress
        );

        // Deploy CctpForwarder
        cctpForwarderImpl = new CctpForwarder(
            messageTransmitter,
            supportedMessageVersion,
            supportedBurnMessageVersion
        );

        // Stop recording transactions
        vm.stopBroadcast();
    }

    /**
     * @notice initialize variables from environment
     */
    function setUp() public {
        implementationDeployerKey = vm.envUint("IMPLEMENTATION_DEPLOYER_KEY");

        // CoreDepositWallet constructor arguments
        tokenContractAddress = vm.envAddress("TOKEN_CONTRACT_ADDRESS");
        tokenSystemAddress = vm.envAddress("TOKEN_SYSTEM_ADDRESS");

        // CctpForwarder constructor arguments
        messageTransmitter = vm.envAddress("MESSAGE_TRANSMITTER_ADDRESS");
        supportedMessageVersion = uint32(
            vm.envUint("SUPPORTED_MESSAGE_VERSION")
        );
        supportedBurnMessageVersion = uint32(
            vm.envUint("SUPPORTED_BURN_MESSAGE_VERSION")
        );
    }

    /**
     * @notice main function that will be run by forge
     */
    function run() public {
        deployImplementations();
    }
}
