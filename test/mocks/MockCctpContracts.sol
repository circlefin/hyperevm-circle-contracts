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

import {MockMintBurnToken} from "lib/evm-cctp-contracts/test/mocks/MockMintBurnToken.sol";
import {ITokenMinterV2} from "@evm-cctp-contracts/interfaces/v2/ITokenMinterV2.sol";

contract MockMessageTransmitterV2 {
    MockMintBurnToken public immutable localToken;

    constructor(address _localToken) {
        localToken = MockMintBurnToken(_localToken);
    }

    function receiveMessage(
        bytes calldata message,
        bytes calldata signature
    ) external returns (bool) {
        // revert if signature is 'revert', otherwise do nothing
        require(
            keccak256(signature) != keccak256(bytes("revert")),
            "mock revert"
        );

        if (keccak256(signature) == keccak256(bytes("return false"))) {
            return false;
        }

        // Mint tokens
        uint256 amountIndex = 148 + 68;
        uint256 feeIndex = amountIndex + 96;
        uint256 amount;
        uint256 feeExecuted;
        assembly {
            amount := calldataload(add(message.offset, amountIndex))
            feeExecuted := calldataload(add(message.offset, feeIndex))
        }
        uint256 amountToMint = amount - feeExecuted;
        localToken.mint(msg.sender, amountToMint);

        return true;
    }
}

contract MockTokenMessengerV2 {
    ITokenMinterV2 public immutable localMinter;

    constructor(address _localMinter) {
        localMinter = ITokenMinterV2(_localMinter);
    }
}

contract MockTokenMinterV2 {
    address public immutable localToken;

    constructor(address _localToken) {
        localToken = _localToken;
    }

    function getLocalToken(uint32, bytes32) external view returns (address) {
        return localToken;
    }
}

contract MockStatefulTokenMessengerV2 {
    ITokenMinterV2 private immutable localMinter_;
    uint256 public counter;

    constructor(address _localMinter) {
        localMinter_ = ITokenMinterV2(_localMinter);
    }

    function localMinter() external returns (ITokenMinterV2) {
        counter++;
        return localMinter_;
    }
}
