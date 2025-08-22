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
import {CctpExtension} from "../../src/CctpExtension.sol";
import {PredictCreate2Deployments} from "../../scripts/PredictCreate2Deployments.s.sol";

contract DeployCctpExtensionTest is DeployScriptTestUtils {
    function setUp() public {
        _deployCreate2Factory();
        _deployCctpExtension();
    }

    function test_DeployImplementations_deploysCctpExtensionSuccessfully()
        public
    {
        // check token messenger
        assertEq(address(cctpExtension.tokenMessenger()), TOKEN_MESSENGER);

        // check token
        assertEq(address(cctpExtension.token()), TOKEN);

        // check owner
        assertEq(cctpExtension.owner(), cctpExtensionOwner);

        // check rescuer
        assertEq(cctpExtension.rescuer(), cctpExtensionRescuer);

        // Verify matches with predicted address
        PredictCreate2Deployments predictCreate2Deployments = new PredictCreate2Deployments();
        address predictedCctpExtension = predictCreate2Deployments
            .cctpExtension(address(create2Factory));
        assertEq(address(cctpExtension), predictedCctpExtension);
    }
}
