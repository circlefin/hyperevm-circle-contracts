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

import {DeployScriptTestUtils} from "../DeployScriptTestUtils.s.sol";
import {AdminUpgradableProxy} from "@evm-cctp-contracts/proxy/AdminUpgradableProxy.sol";
import {MockMintBurnToken} from "lib/evm-cctp-contracts/test/mocks/MockMintBurnToken.sol";
import {MockMessageTransmitterV2, MockTokenMessengerV2, MockTokenMinterV2, MockStatefulTokenMessengerV2} from "../mocks/MockCctpContracts.sol";
import {CoreDepositWallet} from "../../src/CoreDepositWallet.sol";
import {PredictCreate2Deployments} from "../../scripts/PredictCreate2Deployments.s.sol";

contract DeployCoreDepositWalletTest is DeployScriptTestUtils {
    function setUp() public {
        _deployCreate2Factory();
        _deployCoreDepositWallet();
    }

    function test_DeployImplementations_deploysCoreDepositWalletImplementationSuccessfully()
        public
    {
        // check token contract address
        assertEq(address(coreDepositWalletImpl.token()), TOKEN);

        // check token system address
        assertEq(
            address(coreDepositWalletImpl.tokenSystemAddress()),
            address(TOKEN_SYSTEM_ADDRESS)
        );

        // verify initializers are disabled
        vm.expectRevert("Initializable: invalid initialization");
        coreDepositWalletImpl.initialize(
            CoreDepositWallet.CoreDepositWalletRoles({
                owner: coreDepositWalletOwner,
                pauser: coreDepositWalletPauser,
                rescuer: coreDepositWalletRescuer
            })
        );

        // Verify matches with predicted
        PredictCreate2Deployments predictCreate2Deployments = new PredictCreate2Deployments();
        address predictedCoreDepositWalletImpl = predictCreate2Deployments
            .coreDepositWalletImpl(
                address(create2Factory),
                TOKEN,
                TOKEN_SYSTEM_ADDRESS
            );
        assertEq(
            address(coreDepositWalletImpl),
            predictedCoreDepositWalletImpl
        );
    }

    function test_DeployProxies_deploysCoreDepositWalletProxySuccessfully()
        public
    {
        // check core deposit wallet implementation
        AdminUpgradableProxy coreDepositWalletProxy = AdminUpgradableProxy(
            payable(address(coreDepositWallet))
        );
        assertEq(
            coreDepositWalletProxy.implementation(),
            address(coreDepositWalletImpl)
        );

        // check core deposit wallet proxy admin
        assertEq(
            coreDepositWalletProxy.admin(),
            address(coreDepositWalletProxyAdmin)
        );

        // check core deposit wallet owner
        assertEq(coreDepositWallet.owner(), coreDepositWalletOwner);

        // check core deposit wallet pauser
        assertEq(coreDepositWallet.pauser(), coreDepositWalletPauser);

        // check core deposit wallet rescuer
        assertEq(coreDepositWallet.rescuer(), coreDepositWalletRescuer);

        // verify initializers are disabled
        vm.expectRevert("Initializable: invalid initialization");
        coreDepositWallet.initialize(
            CoreDepositWallet.CoreDepositWalletRoles({
                owner: coreDepositWalletOwner,
                pauser: coreDepositWalletPauser,
                rescuer: coreDepositWalletRescuer
            })
        );

        // Verify matches with predicted
        PredictCreate2Deployments predictCreate2Deployments = new PredictCreate2Deployments();
        address predictedCoreDepositWallet = predictCreate2Deployments
            .coreDepositWalletProxy(address(create2Factory));
        assertEq(address(coreDepositWallet), predictedCoreDepositWallet);
    }
}
