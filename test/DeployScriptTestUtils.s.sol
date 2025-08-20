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

import {Test} from "forge-std/Test.sol";
import {DeployImplementationsScript} from "../scripts/DeployImplementations.s.sol";
import {DeployProxiesScript} from "../scripts/DeployProxies.s.sol";
import {CoreDepositWallet} from "../src/CoreDepositWallet.sol";
import {CctpForwarder} from "../src/CctpForwarder.sol";
import {MockBlacklistableMintBurnToken} from "./mocks/MockBlacklistableMintBurnToken.sol";
import {MockMessageTransmitterV2, MockTokenMinterV2, MockTokenMessengerV2} from "./mocks/MockCctpContracts.sol";
import {MockCoreDepositWallet} from "./mocks/MockCoreDepositWallet.sol";

contract DeployScriptTestUtils is Test {
    // CoreDepositWallet test constants
    address public TOKEN_SYSTEM_ADDRESS = address(0x1111);

    // CctpForwarder test constants
    uint32 public MESSAGE_VERSION = 1;
    uint32 public BURN_VERSION = 2; // Set to 2 to differentiate from MESSAGE_VERSION

    address public TOKEN = address(new MockBlacklistableMintBurnToken());
    address public TOKEN_MINTER = address(new MockTokenMinterV2(TOKEN));
    address public TOKEN_MESSENGER =
        address(new MockTokenMessengerV2(address(TOKEN_MINTER)));
    address public MESSAGE_TRANSMITTER =
        address(new MockMessageTransmitterV2(TOKEN));

    MockCoreDepositWallet public CORE_DEPOSIT_WALLET =
        new MockCoreDepositWallet();

    CoreDepositWallet public coreDepositWallet;
    CctpForwarder public forwarder;

    // Roles
    address public coreDepositWalletProxyAdmin = address(0x2222);
    address public coreDepositWalletOwner = address(0x3333);
    address public coreDepositWalletPauser = address(0x4444);
    address public coreDepositWalletRescuer = address(0x5555);
    CoreDepositWallet.CoreDepositWalletRoles public coreDepositWalletRoles =
        CoreDepositWallet.CoreDepositWalletRoles({
            owner: coreDepositWalletOwner,
            pauser: coreDepositWalletPauser,
            rescuer: coreDepositWalletRescuer
        });
    address public cctpForwarderOwner = address(0x6666);
    address public cctpForwarderProxyAdmin = address(0x7777);
    address public cctpForwarderRescuer = address(0x8888);
    CctpForwarder.CctpForwarderRoles public cctpForwarderRoles =
        CctpForwarder.CctpForwarderRoles({
            owner: cctpForwarderOwner,
            rescuer: cctpForwarderRescuer
        });

    // Implementations
    CoreDepositWallet public coreDepositWalletImpl;
    CctpForwarder public forwarderImpl;

    function _deployImplementations() internal {
        // Set env vars
        vm.setEnv(
            "IMPLEMENTATION_DEPLOYER_KEY",
            vm.toString(keccak256("IMPLEMENTATION_DEPLOYER_KEY"))
        );
        vm.setEnv(
            "MESSAGE_TRANSMITTER_ADDRESS",
            vm.toString(MESSAGE_TRANSMITTER)
        );
        vm.setEnv(
            "SUPPORTED_MESSAGE_VERSION",
            vm.toString(uint256(MESSAGE_VERSION))
        );
        vm.setEnv(
            "SUPPORTED_BURN_MESSAGE_VERSION",
            vm.toString(uint256(BURN_VERSION))
        );

        vm.setEnv("TOKEN_CONTRACT_ADDRESS", vm.toString(TOKEN));
        vm.setEnv("TOKEN_SYSTEM_ADDRESS", vm.toString(TOKEN_SYSTEM_ADDRESS));

        // Deploy
        DeployImplementationsScript deployImplementationsScript = new DeployImplementationsScript();
        deployImplementationsScript.setUp();
        deployImplementationsScript.run();
        coreDepositWalletImpl = deployImplementationsScript
            .coreDepositWalletImpl();
        forwarderImpl = deployImplementationsScript.cctpForwarderImpl();
    }

    function _deployProxies() internal {
        // Set env vars
        vm.setEnv(
            "PROXY_DEPLOYER_KEY",
            vm.toString(keccak256("PROXY_DEPLOYER_KEY"))
        );
        vm.setEnv(
            "CORE_DEPOSIT_WALLET_IMPLEMENTATION_ADDRESS",
            vm.toString(address(coreDepositWalletImpl))
        );
        vm.setEnv(
            "CORE_DEPOSIT_WALLET_PROXY_ADMIN_ADDRESS",
            vm.toString(coreDepositWalletProxyAdmin)
        );
        vm.setEnv(
            "CORE_DEPOSIT_WALLET_OWNER_ADDRESS",
            vm.toString(coreDepositWalletOwner)
        );
        vm.setEnv(
            "CORE_DEPOSIT_WALLET_PAUSER_ADDRESS",
            vm.toString(coreDepositWalletPauser)
        );
        vm.setEnv(
            "CORE_DEPOSIT_WALLET_RESCUER_ADDRESS",
            vm.toString(coreDepositWalletRescuer)
        );
        vm.setEnv(
            "CCTP_FORWARDER_IMPLEMENTATION_ADDRESS",
            vm.toString(address(forwarderImpl))
        );
        vm.setEnv(
            "CCTP_FORWARDER_PROXY_ADMIN_ADDRESS",
            vm.toString(cctpForwarderProxyAdmin)
        );
        vm.setEnv(
            "CCTP_FORWARDER_OWNER_ADDRESS",
            vm.toString(cctpForwarderOwner)
        );
        vm.setEnv(
            "CCTP_FORWARDER_RESCUER_ADDRESS",
            vm.toString(cctpForwarderRescuer)
        );
        vm.setEnv("CCTP_FORWARDER_TOKEN_ADDRESS", vm.toString(TOKEN));
        vm.setEnv(
            "CCTP_FORWARDER_FORWARDING_ADDRESS",
            vm.toString(address(CORE_DEPOSIT_WALLET))
        );

        // Deploy
        DeployProxiesScript deployProxiesScript = new DeployProxiesScript();
        deployProxiesScript.setUp();
        deployProxiesScript.run();
        coreDepositWallet = deployProxiesScript.coreDepositWallet();
        forwarder = deployProxiesScript.cctpForwarder();
    }
}
