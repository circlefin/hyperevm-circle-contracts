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
 * @dev Hook data must follow this format:
 *      Bytes 0-23:  bytes24 - Magic bytes "cctp-forward" (optional - set to 0 to opt out of forwarding)
 *      Bytes 24-27: uint32  - Circle Hook Data Version ID (Set to 0 for this use-case)
 *      Bytes 28-31: uint32  - Length of Circle Hook Data (Set to 20 for this use-case, byte-length of EVM address)
 *      Bytes 32-51: address - forwardRecipient address
 */
library CctpForwarderHookData {
    using TypedMemView for bytes29;

    uint256 private constant HOOK_VERSION = 0;
    uint256 private constant HOOK_VERSION_INDEX = 24;
    uint8 private constant HOOK_VERSION_LENGTH = 4;
    uint256 private constant HOOK_RECIPIENT_INDEX = 32;
    uint256 private constant HOOK_LENGTH = 52;

    /**
     * @notice Get forward recipient from hook data
     * @param hookData Hook data
     * @return forwardRecipient Forward recipient
     */
    function _getForwardRecipient(
        bytes29 hookData
    ) internal pure returns (address forwardRecipient) {
        // Verify hook
        require(hookData.len() == HOOK_LENGTH, "Invalid hook data: too short");
        uint256 hookVersion = hookData.indexUint(
            HOOK_VERSION_INDEX,
            HOOK_VERSION_LENGTH
        );
        require(hookVersion == HOOK_VERSION, "Invalid hook data: version");

        // Get forward recipient
        forwardRecipient = hookData.indexAddress(HOOK_RECIPIENT_INDEX);
    }
}
