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

import {TypedMemView} from "@memview-sol/contracts/TypedMemView.sol";

/**
 * @title CrossChainWithdrawalHookData Library
 * @notice Library for parsing and building CrossChainWithdrawal hook data
 *
 * @dev The user provided hook data is expected to follow the following format:
 *      - bytes24 - Magic bytes "cctp-forward" (optional - set to 0 to opt out of CCTP cross-chain withdrawal forwarding.)
 *      - any custom protocol-specific data
 *
 * @dev The final hook data format that will be included in the CCTP message payload hook data follows the following format:
 *      Bytes 0-23:  bytes24 - Magic bytes "cctp-forward" or 0 if not forwarding
 *      Bytes 24-27: uint32  - CrossChainWithdrawal Hook Data Version ID (0)
 *      Bytes 28-31: uint32  - Length of CrossChainWithdrawal Hook Data (20 bytes for EVM address + 4 bytes for nonce + length of the data field)
 *      Bytes 32-51: address - from address
 *      Bytes 52-55: nonce - HyperCore nonce
 *      Bytes 56+: the user provided hook data
 */
library CrossChainWithdrawalHookData {
    using TypedMemView for bytes29;

    uint8 private constant HOOK_MAGIC_BYTES_INDEX = 0;
    uint8 private constant HOOK_MAGIC_BYTES_LENGTH = 24;
    uint32 private constant HOOK_VERSION = 0;
    bytes24 private constant HOOK_MAGIC_BYTES = bytes24("cctp-forward");
    uint8 private constant HOOK_EVM_ADDRESS_LENGTH = 20;
    uint8 private constant HOOK_NONCE_LENGTH = 4;

    /**
     * @notice Get magic bytes from hook data.
     * @dev Gets the magic bytes from bytes 0-23 of hook data.
     * @param hookData Hook data
     * @return bytes24 Magic bytes
     */
    function _getMagicBytes(bytes29 hookData) internal pure returns (bytes24) {
        return bytes24(hookData.index(HOOK_MAGIC_BYTES_INDEX, HOOK_MAGIC_BYTES_LENGTH));
    }

    /**
     * @notice Checks if the data has the forwarding magic bytes.
     * @param data The user provided hook data
     * @return True if the data has forwarding magic bytes, false otherwise.
     */
    function _hasForwardingMagicBytes(bytes29 data) internal pure returns (bool) {
        if (data.len() < HOOK_MAGIC_BYTES_LENGTH) return false;
        return _getMagicBytes(data) == HOOK_MAGIC_BYTES;
    }

    /**
     * @notice Reverts if hook data is malformed
     * @param data The hook data as bytes29
     */
    function _validateHookData(bytes29 data) internal pure {
        require(data.isValid(), "Malformed hook data");
    }

    /**
     * @notice Builds the CCTP message payload hook data.
     * @dev If shouldForward is true, the hook data is built with the magic bytes and the data.
     * @dev If shouldForward is false, the hook data is built with the magic bytes set to 0.
     * @dev The hook data is built with the following format:
     *      - bytes24 - Magic bytes "cctp-forward" (optional - set to 0 to opt out of CCTP cross-chain withdrawal forwarding.)
     *      - uint32  - CrossChainWithdrawal Hook Data Version ID (0)
     *      - uint32  - Length of CrossChainWithdrawal Hook Data (20 bytes for EVM address + 4 bytes for nonce + length of the data field)
     *      - address - from address
     *      - nonce - HyperCore nonce
     *      - bytes - the user provided hook data
     * @param shouldForward True if cross-chain forwarding should be performed, false otherwise.
     * @param from The address from which the cross-chain withdrawal is being made.
     * @param nonce The HyperCore transaction nonce.
     * @param data The user provided hook data.
     * @return bytes The built CCTP message payload hook data.
     */
    function _build(bool shouldForward, address from, uint64 nonce, bytes calldata data)
        internal
        pure
        returns (bytes memory)
    {
        bytes24 magic = shouldForward ? HOOK_MAGIC_BYTES : bytes24(0);
        return abi.encodePacked(magic, HOOK_VERSION, uint32(data.length + HOOK_EVM_ADDRESS_LENGTH + HOOK_NONCE_LENGTH), from, nonce, data);
    }
}
