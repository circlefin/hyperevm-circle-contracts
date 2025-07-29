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
import {AdminUpgradableProxy} from "@evm-cctp-contracts/proxy/AdminUpgradableProxy.sol";
import {CctpForwarder} from "../src/CctpForwarder.sol";
import {CoreDepositWallet} from "../src/CoreDepositWallet.sol";
import {CctpExtension} from "../src/CctpExtension.sol";
import {SALT_CORE_DEPOSIT_WALLET, SALT_CCTP_FORWARDER, SALT_CCTP_EXTENSION} from "./Salts.sol";

contract PredictCreate2Deployments is Script {
    // =========================== CoreDepositWallet ============================
    function coreDepositWalletProxy(
        address create2Factory
    ) public returns (address) {
        return
            vm.computeCreate2Address(
                SALT_CORE_DEPOSIT_WALLET,
                keccak256(
                    abi.encodePacked(
                        type(AdminUpgradableProxy).creationCode,
                        abi.encode(create2Factory, create2Factory, "")
                    )
                ),
                create2Factory
            );
    }

    function coreDepositWalletImpl(
        address create2Factory,
        address tokenContractAddress,
        address tokenSystemAddress,
        address tokenMessengerAddress
    ) public returns (address) {
        return
            vm.computeCreate2Address(
                SALT_CORE_DEPOSIT_WALLET,
                keccak256(
                    abi.encodePacked(
                        type(CoreDepositWallet).creationCode,
                        abi.encode(tokenContractAddress, tokenSystemAddress, tokenMessengerAddress)
                    )
                ),
                create2Factory
            );
    }

    // =========================== CctpForwarder ============================
    function cctpForwarderProxy(
        address create2Factory
    ) public returns (address) {
        return
            vm.computeCreate2Address(
                SALT_CCTP_FORWARDER,
                keccak256(
                    abi.encodePacked(
                        type(AdminUpgradableProxy).creationCode,
                        abi.encode(create2Factory, create2Factory, "")
                    )
                ),
                create2Factory
            );
    }

    function cctpForwarderImpl(
        address create2Factory,
        address messageTransmitter,
        address tokenMessenger,
        uint32 supportedMessageVersion,
        uint32 supportedBurnMessageVersion
    ) public returns (address) {
        return
            vm.computeCreate2Address(
                SALT_CCTP_FORWARDER,
                keccak256(
                    abi.encodePacked(
                        type(CctpForwarder).creationCode,
                        abi.encode(
                            messageTransmitter,
                            tokenMessenger,
                            supportedMessageVersion,
                            supportedBurnMessageVersion
                        )
                    )
                ),
                create2Factory
            );
    }

    // =========================== CctpExtension ============================
    function cctpExtension(address create2Factory) public returns (address) {
        return
            vm.computeCreate2Address(
                SALT_CCTP_EXTENSION,
                keccak256(abi.encodePacked(type(CctpExtension).creationCode)),
                create2Factory
            );
    }
}
