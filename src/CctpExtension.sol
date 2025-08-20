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

import {ICctpExtension} from "./interfaces/ICctpExtension.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Rescuable} from "./roles/Rescuable.sol";

contract CctpExtension is ICctpExtension, Rescuable {
    using SafeERC20 for IERC20;
    //=========================== State Variables ============================

    /**
     * @notice The tokenMessenger contract address.
     */
    address public immutable TOKEN_MESSENGER;

    /**
     * @notice The token contract address.
     */
    address public immutable TOKEN;

    //=========================== Constructor ============================

    constructor(
        address _owner,
        address _rescuer,
        address _tokenMessenger,
        address _token
    ) {
        require(_owner != address(0), "Invalid owner address");
        require(_rescuer != address(0), "Invalid rescuer address");
        require(_tokenMessenger != address(0), "Invalid tokenMessenger");
        require(_token != address(0), "Invalid token address");

        _transferOwnership(_owner);
        _updateRescuer(_rescuer);
        TOKEN_MESSENGER = _tokenMessenger;
        TOKEN = _token;
        IERC20(_token).safeIncreaseAllowance(
            _tokenMessenger,
            type(uint256).max
        );
    }

    //=========================== External Functions ============================

    /// @inheritdoc ICctpExtension
    function batchDepositForBurnWithAuth(
        ReceiveWithAuthorizationData calldata _receiveWithAuthorizationData,
        DepositForBurnWithHookData calldata _depositForBurnData
    ) external override {
        // TODO: Implement
    }
}
