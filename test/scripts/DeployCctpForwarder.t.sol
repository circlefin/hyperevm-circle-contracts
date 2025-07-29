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
import {DeployScriptTestUtils} from "../DeployScriptTestUtils.s.sol";
import {CctpForwarder} from "../../src/CctpForwarder.sol";
import {MockMintBurnToken} from "lib/evm-cctp-contracts/test/mocks/MockMintBurnToken.sol";
import {MockMessageTransmitterV2, MockTokenMessengerV2, MockTokenMinterV2, MockStatefulTokenMessengerV2} from "../mocks/MockCctpContracts.sol";
import {PredictCreate2Deployments} from "../../scripts/PredictCreate2Deployments.s.sol";

contract DeployCctpForwarderTest is DeployScriptTestUtils {
    function setUp() public {
        _deployCreate2Factory();
        _deployCctpForwarder();
    }

    function test_DeployImplementations_deploysCctpForwarderImplementationSuccessfully()
        public
    {
        // check message transmitter
        assertEq(
            address(forwarderImpl.messageTransmitter()),
            MESSAGE_TRANSMITTER
        );

        // check supported message version
        assertEq(
            forwarderImpl.supportedMessageVersion(),
            uint256(MESSAGE_VERSION)
        );

        // check supported burn message version
        assertEq(
            forwarderImpl.supportedBurnMessageVersion(),
            uint256(BURN_VERSION)
        );

        // verify initializers are disabled
        vm.expectRevert("Initializable: invalid initialization");
        forwarderImpl.initialize(
            CctpForwarder.CctpForwarderRoles({
                owner: cctpForwarderOwner,
                rescuer: cctpForwarderRescuer
            }),
            new address[](0),
            new address[](0)
        );

        // Verify matches with predicted
        PredictCreate2Deployments predictCreate2Deployments = new PredictCreate2Deployments();
        address predictedCctpForwarderImpl = predictCreate2Deployments
            .cctpForwarderImpl(
                address(create2Factory),
                MESSAGE_TRANSMITTER,
                TOKEN_MESSENGER,
                MESSAGE_VERSION,
                BURN_VERSION
            );
        assertEq(address(forwarderImpl), predictedCctpForwarderImpl);
    }

    function test_DeployProxies_deploysCctpForwarderProxySuccessfully(
        address otherToken
    ) public {
        // Assume otherToken is not TOKEN
        vm.assume(otherToken != TOKEN);

        // check cctp forwarder implementation
        AdminUpgradableProxy forwarderProxy = AdminUpgradableProxy(
            payable(address(forwarder))
        );
        assertEq(forwarderProxy.implementation(), address(forwarderImpl));

        // check cctp forwarder proxy admin
        assertEq(forwarderProxy.admin(), address(cctpForwarderProxyAdmin));

        // check cctp forwarder owner
        assertEq(forwarder.owner(), cctpForwarderOwner);

        // check cctp forwarder tokens and forwarding addresses
        assertEq(
            forwarder.tokenToForwardingAddress(TOKEN),
            address(CORE_DEPOSIT_WALLET)
        );
        assertEq(forwarder.tokenToForwardingAddress(otherToken), address(0)); // Not mapped

        // verify initializers are disabled
        vm.expectRevert("Initializable: invalid initialization");
        forwarder.initialize(
            CctpForwarder.CctpForwarderRoles({
                owner: cctpForwarderOwner,
                rescuer: cctpForwarderRescuer
            }),
            new address[](0),
            new address[](0)
        );

        // Verify matches with predicted
        PredictCreate2Deployments predictCreate2Deployments = new PredictCreate2Deployments();
        address predictedCctpForwarder = predictCreate2Deployments
            .cctpForwarderProxy(address(create2Factory));
        assertEq(address(forwarder), predictedCctpForwarder);
    }
}
