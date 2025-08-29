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
import {Create2Factory} from "@evm-cctp-contracts/v2/Create2Factory.sol";
import {CoreDepositWallet} from "../src/CoreDepositWallet.sol";
import {CctpForwarder} from "../src/CctpForwarder.sol";
import {CctpExtension} from "../src/CctpExtension.sol";
import {MockDepositableToken} from "./mocks/MockDepositableToken.sol";
import {MockMessageTransmitterV2, MockTokenMinterV2, MockTokenMessengerV2} from "./mocks/MockCctpContracts.sol";
import {MockCoreDepositWallet} from "./mocks/MockCoreDepositWallet.sol";
import {DeployCoreDepositWalletScript} from "../scripts/DeployCoreDepositWallet.s.sol";
import {DeployCctpForwarderScript} from "../scripts/DeployCctpForwarder.s.sol";
import {DeployCctpExtensionScript} from "../scripts/DeployCctpExtension.s.sol";
import {PredictCreate2Deployments} from "../scripts/PredictCreate2Deployments.s.sol";

contract DeployScriptTestUtils is Test {
    uint256 deployerPK;
    address deployer;
    Create2Factory create2Factory;

    // =========================== Deployed Contracts ============================
    CoreDepositWallet public coreDepositWallet;
    CctpForwarder public forwarder;
    CctpExtension public cctpExtension;

    // =========================== Implementations ============================
    CoreDepositWallet public coreDepositWalletImpl;
    CctpForwarder public forwarderImpl;

    // =========================== Test Constants ============================
    // CoreDepositWallet
    address public TOKEN_SYSTEM_ADDRESS = address(0x1111);

    // CctpForwarder
    uint32 public MESSAGE_VERSION = 1;
    uint32 public BURN_VERSION = 2; // Set to 2 to differentiate from MESSAGE_VERSION

    address public TOKEN = address(new MockDepositableToken());
    address public TOKEN_MINTER = address(new MockTokenMinterV2(TOKEN));
    address public TOKEN_MESSENGER =
        address(new MockTokenMessengerV2(address(TOKEN_MINTER)));
    address public MESSAGE_TRANSMITTER =
        address(new MockMessageTransmitterV2(TOKEN));

    MockCoreDepositWallet public CORE_DEPOSIT_WALLET =
        new MockCoreDepositWallet();

    // =========================== Roles ============================
    // CoreDepositWallet
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

    // CctpForwarder
    address public cctpForwarderOwner = address(0x6666);
    address public cctpForwarderProxyAdmin = address(0x7777);
    address public cctpForwarderRescuer = address(0x8888);
    CctpForwarder.CctpForwarderRoles public cctpForwarderRoles =
        CctpForwarder.CctpForwarderRoles({
            owner: cctpForwarderOwner,
            rescuer: cctpForwarderRescuer
        });

    // CctpExtension
    address public cctpExtensionOwner = address(0x9999);
    address public cctpExtensionRescuer = address(0xaaaa);

    function _deployCreate2Factory() internal {
        deployerPK = uint256(keccak256("DEPLOYTEST_DEPLOYER_PK"));
        deployer = vm.addr(deployerPK);
        vm.startBroadcast(deployerPK);
        create2Factory = new Create2Factory();
        vm.stopBroadcast();
    }

    function _deployCoreDepositWallet() internal {
        // Set env vars
        vm.setEnv(
            "CREATE2_FACTORY_CONTRACT_ADDRESS",
            vm.toString(address(create2Factory))
        );
        vm.setEnv("TOKEN_CONTRACT_ADDRESS", vm.toString(TOKEN));
        vm.setEnv("TOKEN_SYSTEM_ADDRESS", vm.toString(TOKEN_SYSTEM_ADDRESS));
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

        // Deploy
        DeployCoreDepositWalletScript deployCoreDepositWalletScript = new DeployCoreDepositWalletScript();
        deployCoreDepositWalletScript.setUp();
        deployCoreDepositWalletScript.run();
        coreDepositWalletImpl = deployCoreDepositWalletScript
            .coreDepositWalletImpl();
        coreDepositWallet = deployCoreDepositWalletScript.coreDepositWallet();
    }

    function _deployCctpForwarder() internal {
        // Set env vars
        vm.setEnv(
            "CREATE2_FACTORY_CONTRACT_ADDRESS",
            vm.toString(address(create2Factory))
        );
        vm.setEnv(
            "MESSAGE_TRANSMITTER_ADDRESS",
            vm.toString(MESSAGE_TRANSMITTER)
        );
        vm.setEnv("TOKEN_MESSENGER_ADDRESS", vm.toString(TOKEN_MESSENGER));
        vm.setEnv(
            "SUPPORTED_MESSAGE_VERSION",
            vm.toString(uint256(MESSAGE_VERSION))
        );
        vm.setEnv(
            "SUPPORTED_BURN_MESSAGE_VERSION",
            vm.toString(uint256(BURN_VERSION))
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
        vm.setEnv("CCTP_FORWARDER_TOKEN_ADDRESSES", vm.toString(TOKEN));
        vm.setEnv(
            "CCTP_FORWARDER_FORWARDING_ADDRESSES",
            vm.toString(address(CORE_DEPOSIT_WALLET))
        );

        // Deploy
        DeployCctpForwarderScript deployCctpForwarderScript = new DeployCctpForwarderScript();
        deployCctpForwarderScript.setUp();
        deployCctpForwarderScript.run();
        forwarderImpl = deployCctpForwarderScript.cctpForwarderImpl();
        forwarder = deployCctpForwarderScript.cctpForwarder();
    }

    function _deployCctpExtension() internal {
        // Set env vars
        vm.setEnv(
            "CREATE2_FACTORY_CONTRACT_ADDRESS",
            vm.toString(address(create2Factory))
        );
        vm.setEnv(
            "CCTP_EXTENSION_OWNER_ADDRESS",
            vm.toString(cctpExtensionOwner)
        );
        vm.setEnv(
            "CCTP_EXTENSION_RESCUER_ADDRESS",
            vm.toString(cctpExtensionRescuer)
        );
        vm.setEnv("TOKEN_MESSENGER_ADDRESS", vm.toString(TOKEN_MESSENGER));
        vm.setEnv("TOKEN_CONTRACT_ADDRESS", vm.toString(TOKEN));

        // Deploy
        DeployCctpExtensionScript deployCctpExtensionScript = new DeployCctpExtensionScript();
        deployCctpExtensionScript.setUp();
        deployCctpExtensionScript.run();
        cctpExtension = deployCctpExtensionScript.cctpExtension();
    }
}
