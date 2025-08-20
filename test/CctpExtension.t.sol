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

import {Test, console} from "forge-std/Test.sol";
import {MockMintBurnToken} from "lib/evm-cctp-contracts/test/mocks/MockMintBurnToken.sol";
import {CctpExtension} from "../src/CctpExtension.sol";
import {MockEIP3009Token} from "./mocks/MockEIP3009Token.sol";

contract CctpExtensionTest is Test {
    MockEIP3009Token public EIP3009_TOKEN = new MockEIP3009Token();
    CctpExtension public cctpExtension;

    address public owner = address(10);
    address public rescuer = address(11);
    address public tokenMessenger = address(12);

    function setUp() public {
        cctpExtension = new CctpExtension(
            owner,
            rescuer,
            tokenMessenger,
            address(EIP3009_TOKEN)
        );
    }

    //=========================== Constructor Tests ============================

    function testConstructor_revertsIfOwnerIsZeroAddress() public {
        vm.expectRevert("Invalid owner address");
        new CctpExtension(
            address(0),
            rescuer,
            tokenMessenger,
            address(EIP3009_TOKEN)
        );
    }

    function testConstructor_revertsIfRescuerIsZeroAddress() public {
        vm.expectRevert("Invalid rescuer address");
        new CctpExtension(
            owner,
            address(0),
            tokenMessenger,
            address(EIP3009_TOKEN)
        );
    }

    function testConstructor_revertsIfTokenMessengerIsZeroAddress() public {
        vm.expectRevert("Invalid tokenMessenger");
        new CctpExtension(owner, rescuer, address(0), address(EIP3009_TOKEN));
    }

    function testConstructor_revertsIfTokenIsZeroAddress() public {
        vm.expectRevert("Invalid token address");
        new CctpExtension(owner, rescuer, tokenMessenger, address(0));
    }

    function testConstructor_setsStateVariablesCorrectly() public view {
        assertEq(cctpExtension.owner(), owner);
        assertEq(cctpExtension.rescuer(), rescuer);
        assertEq(cctpExtension.TOKEN_MESSENGER(), tokenMessenger);
        assertEq(cctpExtension.TOKEN(), address(EIP3009_TOKEN));
    }

    function testConstructor_increasesAllowanceForTokenMessenger() public view {
        assertEq(
            EIP3009_TOKEN.allowance(address(cctpExtension), tokenMessenger),
            type(uint256).max
        );
    }

    function testConstructor_emitsOwnershipTransferredEvents() public {
        // The constructor emits two OwnershipTransferred events in sequence:
        // 1. Initial ownership to deployer (msg.sender = this test contract)
        // 2. Transfer ownership to specified owner

        // Expect first event: address(0) -> address(this)
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(address(0), address(this));

        // Expect second event: address(this) -> owner
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(address(this), owner);

        new CctpExtension(
            owner,
            rescuer,
            tokenMessenger,
            address(EIP3009_TOKEN)
        );
    }

    function testConstructor_emitsRescuerChangedEvent() public {
        vm.expectEmit(true, true, true, true);
        emit RescuerChanged(rescuer);
        new CctpExtension(
            owner,
            rescuer,
            tokenMessenger,
            address(EIP3009_TOKEN)
        );
    }

    //=========================== Event Declarations ============================

    // Event declarations to match the expected event signatures
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    event RescuerChanged(address indexed newRescuer);
}
