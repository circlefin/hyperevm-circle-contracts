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
import {CoreDepositWallet} from "../../src/CoreDepositWallet.sol";
import {MockMintBurnToken} from "lib/evm-cctp-contracts/test/mocks/MockMintBurnToken.sol";
import {MockMessageTransmitterV2, MockTokenMessengerV2, MockTokenMinterV2, MockStatefulTokenMessengerV2} from "../mocks/MockCctpContracts.sol";

contract DeployImplementationsTest is DeployScriptTestUtils {
    function setUp() public {
        _deployImplementations();
    }

    function test_DeployImplementations_deploysCctpForwarderSuccessfully()
        public
    {
        // check message transmitter
        assertEq(
            address(forwarderImpl.messageTransmitter()),
            address(MESSAGE_TRANSMITTER)
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
            address(123),
            new address[](0),
            new address[](0)
        );
    }

    function test_DeployImplementations_deploysCoreDepositWalletSuccessfully()
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
    }
}
