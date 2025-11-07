/*
 * Copyright (c) 2025, Circle Internet Financial Limited.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
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
import {TypedMemView} from "@memview-sol/contracts/TypedMemView.sol";
import {CrossChainWithdrawalHookDataHarness} from "./mocks/CrossChainWithdrawalHookDataHarness.sol";

contract CrossChainWithdrawalHookDataTest is Test {
    bytes24 private constant MAGIC = bytes24("cctp-forward");

    function testValidateHookData_revertsOnMalformed() public {
        CrossChainWithdrawalHookDataHarness h = new CrossChainWithdrawalHookDataHarness();
        bytes29 invalid = TypedMemView.nullView();
        vm.expectRevert(bytes("Malformed hook data"));
        h.validateHookData(invalid);
    }

    function testHasForwardingMagicBytes_empty_returnsFalse() public {
        CrossChainWithdrawalHookDataHarness h = new CrossChainWithdrawalHookDataHarness();
        bytes memory data = hex"";
        bool result = h.hasForwardingMagic(data);
        assertEq(result, false);
    }

    function testHasForwardingMagicBytes_short_returnsFalse() public {
        CrossChainWithdrawalHookDataHarness h = new CrossChainWithdrawalHookDataHarness();
        bytes memory data = hex"01"; // < 24 bytes
        bool result = h.hasForwardingMagic(data);
        assertEq(result, false);
    }

    function testHasForwardingMagicBytes_exactMagic_returnsTrue() public {
        CrossChainWithdrawalHookDataHarness h = new CrossChainWithdrawalHookDataHarness();
        bytes memory data = abi.encodePacked(MAGIC);
        bool result = h.hasForwardingMagic(data);
        assertEq(result, true);
    }

    function testHasForwardingMagicBytes_magicPrefixWithPayload_returnsTrue() public {
        CrossChainWithdrawalHookDataHarness h = new CrossChainWithdrawalHookDataHarness();
        bytes memory data = abi.encodePacked(MAGIC, hex"AABBCC");
        bool result = h.hasForwardingMagic(data);
        assertEq(result, true);
    }

    function testHasForwardingMagicBytes_nonMagicPrefix_returnsFalse() public {
        CrossChainWithdrawalHookDataHarness h = new CrossChainWithdrawalHookDataHarness();
        // 24 bytes not equal to MAGIC
        bytes memory data = bytes("this-is-not-the-magic-byt"); // 24 bytes
        bool result = h.hasForwardingMagic(data);
        assertEq(result, false);
    }

    function testGetMagicBytes_returnsMagic() public {
        CrossChainWithdrawalHookDataHarness h = new CrossChainWithdrawalHookDataHarness();
        bytes memory data = abi.encodePacked(MAGIC, hex"DEADBEEF");
        bytes24 got = h.getMagic(data);
        assertEq(bytes32(got), bytes32(MAGIC));
    }

    function testBuild_shouldForwardTrue_encodesCorrectly() public {
        CrossChainWithdrawalHookDataHarness h = new CrossChainWithdrawalHookDataHarness();
        address from = address(0xBEEF);
        uint64 nonce = 123;
        bytes memory userData = hex"01020304";
        bytes memory built = h.buildHook(true, from, nonce, userData);
        bytes memory expected = abi.encodePacked(
            MAGIC,
            uint32(0),
            uint32(20 + 4 + userData.length),
            from,
            nonce,
            userData
        );
        assertEq(keccak256(built), keccak256(expected));
    }

    function testBuild_shouldForwardFalse_encodesCorrectly() public {
        CrossChainWithdrawalHookDataHarness h = new CrossChainWithdrawalHookDataHarness();
        address from = address(0xCAFE);
        uint64 nonce = 9999;
        bytes memory userData = hex"AA";
        bytes memory built = h.buildHook(false, from, nonce, userData);
        bytes memory expected = abi.encodePacked(
            bytes24(0),
            uint32(0),
            uint32(20 + 4 + userData.length),
            from,
            nonce,
            userData
        );
        assertEq(keccak256(built), keccak256(expected));
    }
}


