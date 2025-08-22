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
import {CctpForwarder} from "../src/CctpForwarder.sol";
import {SALT_CCTP_FORWARDER} from "./Salts.sol";

contract DeployCctpForwarderScript is Script {
    // Expose for tests
    CctpForwarder public cctpForwarderImpl;
    CctpForwarder public cctpForwarder;

    Create2Factory public create2Factory;

    // Constructor arguments
    address private messageTransmitter;
    uint32 private supportedMessageVersion;
    uint32 private supportedBurnMessageVersion;

    // Init params
    address private cctpForwarderProxyAdminAddress;
    address private cctpForwarderOwnerAddress;
    address private cctpForwarderRescuerAddress;
    address[] private cctpForwarderTokens;
    address[] private cctpForwarderForwardingAddresses;

    function deployImplementation() private {
        // Start recording transactions
        vm.startBroadcast(create2Factory.owner());

        // Deploy CctpForwarder
        cctpForwarderImpl = CctpForwarder(
            create2Factory.deploy(
                0,
                SALT_CCTP_FORWARDER,
                abi.encodePacked(
                    type(CctpForwarder).creationCode,
                    abi.encode(
                        messageTransmitter,
                        supportedMessageVersion,
                        supportedBurnMessageVersion
                    )
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
            CctpForwarder.initialize.selector,
            CctpForwarder.CctpForwarderRoles({
                owner: cctpForwarderOwnerAddress,
                rescuer: cctpForwarderRescuerAddress
            }),
            cctpForwarderTokens,
            cctpForwarderForwardingAddresses
        );

        // Construct upgrade and initialize data
        bytes memory upgradeAndInitializeData = abi.encodeWithSelector(
            AdminUpgradableProxy.upgradeToAndCall.selector,
            cctpForwarderImpl,
            initializer
        );

        // Construct admin rotation data
        bytes memory adminRotationData = abi.encodeWithSelector(
            AdminUpgradableProxy.changeAdmin.selector,
            cctpForwarderProxyAdminAddress
        );

        bytes[] memory multiCallData = new bytes[](2);
        multiCallData[0] = upgradeAndInitializeData;
        multiCallData[1] = adminRotationData;

        // Start recording transactions
        vm.startBroadcast(create2Factory.owner());

        cctpForwarder = CctpForwarder(
            create2Factory.deployAndMultiCall(
                0,
                SALT_CCTP_FORWARDER,
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

        // CctpForwarder constructor arguments
        messageTransmitter = vm.envAddress("MESSAGE_TRANSMITTER_ADDRESS");
        supportedMessageVersion = uint32(
            vm.envUint("SUPPORTED_MESSAGE_VERSION")
        );
        supportedBurnMessageVersion = uint32(
            vm.envUint("SUPPORTED_BURN_MESSAGE_VERSION")
        );

        // CctpForwarder init params
        cctpForwarderProxyAdminAddress = vm.envAddress(
            "CCTP_FORWARDER_PROXY_ADMIN_ADDRESS"
        );
        cctpForwarderOwnerAddress = vm.envAddress(
            "CCTP_FORWARDER_OWNER_ADDRESS"
        );
        cctpForwarderRescuerAddress = vm.envAddress(
            "CCTP_FORWARDER_RESCUER_ADDRESS"
        );
        cctpForwarderTokens = vm.envAddress(
            "CCTP_FORWARDER_TOKEN_ADDRESSES",
            ","
        );
        cctpForwarderForwardingAddresses = vm.envAddress(
            "CCTP_FORWARDER_FORWARDING_ADDRESSES",
            ","
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
