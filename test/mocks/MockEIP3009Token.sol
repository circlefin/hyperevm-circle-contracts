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

import {IEIP3009Token} from "../../src/interfaces/IEIP3009Token.sol";
import {MockMintBurnToken} from "../../lib/evm-cctp-contracts/test/mocks/MockMintBurnToken.sol";

contract MockEIP3009Token is IEIP3009Token, MockMintBurnToken {
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 /* validAfter */,
        uint256 /* validBefore */,
        bytes32 nonce,
        uint8 /* v */,
        bytes32 /* r */,
        bytes32 /* s */
    ) external override {
        emit AuthorizationUsed(from, nonce);
        _transfer(from, to, value);
    }
}
