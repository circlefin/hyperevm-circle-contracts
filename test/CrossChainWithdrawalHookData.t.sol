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
    
    // Type byte lengths for hook data structure
    uint256 private constant ADDRESS_LENGTH = 20;      // bytes in address type
    uint256 private constant UINT64_LENGTH = 8;        // bytes in uint64 type
    uint256 private constant BYTES24_LENGTH = 24;      // bytes in bytes24 type
    uint256 private constant UINT32_LENGTH = 4;        // bytes in uint32 type

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
            uint32(20 + 8 + userData.length),
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
            uint32(20 + 8 + userData.length),
            from,
            nonce,
            userData
        );
        assertEq(keccak256(built), keccak256(expected));
    }

    function testBuild_structuralValidation_largeValues() public {
        CrossChainWithdrawalHookDataHarness h = new CrossChainWithdrawalHookDataHarness();
        
        // Use max values that would break if fields are undersized
        address from = address(type(uint160).max);
        uint64 nonce = type(uint64).max;
        bytes memory userData = new bytes(100);
        
        bytes memory built = h.buildHook(true, from, nonce, userData);
        
        // Build expected using same field sizes
        bytes memory expected = abi.encodePacked(
            MAGIC,
            uint32(0),
            uint32(ADDRESS_LENGTH + UINT64_LENGTH + userData.length),
            from,
            nonce,
            userData
        );
        
        assertEq(keccak256(built), keccak256(expected), "Hook encoding should match abi.encodePacked for max values");
        assertEq(built.length, expected.length, "Hook length should match expected length");
    }

    function testBuild_lengthFieldAccuracy_fuzzed(uint256 len) public {
        // Bound the length and allocate a buffer of that size
        uint256 maxLen = 8192 - ADDRESS_LENGTH - UINT64_LENGTH;
        len = bound(len, 0, maxLen);
        bytes memory userData = new bytes(len);

        CrossChainWithdrawalHookDataHarness h = new CrossChainWithdrawalHookDataHarness();
        bytes memory built = h.buildHook(true, address(0xBEEF), 12345, userData);

        // Extract length field (after magic + version)
        uint32 encodedLength;
        uint256 magicLen = BYTES24_LENGTH;
        uint256 versionLen = UINT32_LENGTH;
        assembly {
            let lengthFieldOffset := add(add(32, magicLen), versionLen)
            encodedLength := mload(add(built, lengthFieldOffset))
            encodedLength := shr(224, encodedLength)
        }

        // Verify it accounts for address + nonce + userData
        assertEq(encodedLength, ADDRESS_LENGTH + UINT64_LENGTH + userData.length, "Length field must correctly encode total payload size");

        // Verify total hook size matches header + payload
        uint256 expectedTotal = BYTES24_LENGTH + UINT32_LENGTH + UINT32_LENGTH + encodedLength;
        assertEq(built.length, expectedTotal, "Total hook size must match encoded structure");
    }
}
