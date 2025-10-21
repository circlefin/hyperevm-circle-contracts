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
 * @title CctpForwarderHookData Library
 * @notice Library for parsing CctpForwarder hook data
 *
 * @dev Hook data is expected to follow this format:
 *      Bytes 0-23:  bytes24 - Magic bytes "cctp-forward" (optional - set to 0 to opt out of forwarding by Circle.)
 *      Bytes 24-27: uint32  - Circle Hook Data Version ID (Set to 0 for this use-case)
 *      Bytes 28-31: uint32  - Length of Circle Hook Data (Set to 24 for this use-case: 20 bytes for EVM address + 4 bytes for destinationId)
 *      Bytes 32-51: address - forwardRecipient address
 *      Bytes 52-55: destinationId - Forwarding-address-specific id used in conjunction with forwardRecipient to route the deposit to a specific location.
 *      Bytes 56+: Optional additional data
 */
library CctpForwarderHookData {
    using TypedMemView for bytes29;

    uint256 private constant HOOK_VERSION = 0;
    uint256 private constant HOOK_VERSION_INDEX = 24;
    uint8 private constant HOOK_VERSION_LENGTH = 4;
    uint256 private constant HOOK_RECIPIENT_INDEX = 32;
    uint256 private constant HOOK_DESTINATION_ID_INDEX = 52;
    uint8 private constant HOOK_DESTINATION_ID_LENGTH = 4;
    uint256 private constant HOOK_LENGTH = 56;

    /**
     * @notice Get forward recipient from hook data. Note: This function 
     * validates that hook data is at least 56 bytes long,
     * and hook version is 0. Bytes 0-23 (magic bytes) and
     * 28-31 (length) may be used offchain, but are not validated
     * by this library.
     * @param hookData Hook data
     * @return forwardRecipient Forward recipient
     */
    function _getForwardRecipientAndDestinationId(
        bytes29 hookData
    ) internal pure returns (address forwardRecipient, uint32 destinationId) {
        // Verify hook
        require(hookData.len() >= HOOK_LENGTH, "Invalid hook data: too short");
        uint256 hookVersion = hookData.indexUint(
            HOOK_VERSION_INDEX,
            HOOK_VERSION_LENGTH
        );
        require(hookVersion == HOOK_VERSION, "Invalid hook data: version");

        // Get forward recipient
        forwardRecipient = hookData.indexAddress(HOOK_RECIPIENT_INDEX);
        destinationId = uint32(
            hookData.indexUint(HOOK_DESTINATION_ID_INDEX, HOOK_DESTINATION_ID_LENGTH)
        );
    }
}
