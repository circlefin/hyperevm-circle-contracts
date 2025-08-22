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
import {CctpExtension} from "../src/CctpExtension.sol";
import {SALT_CCTP_EXTENSION} from "./Salts.sol";

contract DeployCctpExtensionScript is Script {
    // Expose for tests
    CctpExtension public cctpExtension;

    address private factoryAddress;
    address private owner;
    address private rescuer;
    address private tokenMessenger;
    address private token;

    function deployCctpExtension() private {
        Create2Factory factory = Create2Factory(factoryAddress);

        // Start recording transactions
        vm.startBroadcast(factory.owner());

        // Deploy CctpExtension
        cctpExtension = CctpExtension(
            factory.deploy(
                0,
                SALT_CCTP_EXTENSION,
                abi.encodePacked(
                    type(CctpExtension).creationCode,
                    abi.encode(
                        CctpExtension.ConstructorParams({
                            owner: owner,
                            rescuer: rescuer,
                            tokenMessenger: tokenMessenger,
                            token: token
                        })
                    )
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
        factoryAddress = vm.envAddress("CREATE2_FACTORY_CONTRACT_ADDRESS");

        owner = vm.envAddress("CCTP_EXTENSION_OWNER_ADDRESS");
        rescuer = vm.envAddress("CCTP_EXTENSION_RESCUER_ADDRESS");
        tokenMessenger = vm.envAddress("TOKEN_MESSENGER_ADDRESS");
        token = vm.envAddress("TOKEN_CONTRACT_ADDRESS");
    }

    /**
     * @notice main function that will be run by forge
     */
    function run() public {
        deployCctpExtension();
    }
}
