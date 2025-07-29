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
import {CrossChainWithdrawalHookData} from "../../src/messages/CrossChainWithdrawalHookData.sol";

contract CrossChainWithdrawalHookDataHarness {
    function getMagic(bytes memory data) external pure returns (bytes24) {
        return CrossChainWithdrawalHookData._getMagicBytes(TypedMemView.ref(data, 0));
    }

    function hasForwardingMagic(bytes memory data) external pure returns (bool) {
        return CrossChainWithdrawalHookData._hasForwardingMagicBytes(TypedMemView.ref(data, 0));
    }

    function validateHookData(bytes29 viewData) external pure {
        CrossChainWithdrawalHookData._validateHookData(viewData);
    }

    function buildHook(bool shouldForward, address from, uint64 nonce, bytes calldata data)
        external
        pure
        returns (bytes memory)
    {
        return CrossChainWithdrawalHookData._build(shouldForward, from, nonce, data);
    }
}


