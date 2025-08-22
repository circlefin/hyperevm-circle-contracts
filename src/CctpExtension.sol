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
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Rescuable} from "./roles/Rescuable.sol";
import {Initializable} from "@evm-cctp-contracts/proxy/Initializable.sol";
import {IEIP3009Token} from "./interfaces/IEIP3009Token.sol";
import {TokenMessengerV2} from "@evm-cctp-contracts/v2/TokenMessengerV2.sol";

/**
 * @title CctpExtension
 * @notice Facilitates cross-chain token transfers using ERC-3009 token authorization
 *         combined with CCTP's deposit-for-burn mechanism. Implements batching
 *         to optimize gas costs for multiple burn operations.
 */
contract CctpExtension is ICctpExtension, Rescuable, Initializable {
    using SafeERC20 for IERC20;
    using SafeMath for uint256;

    //=========================== Structs ============================

    /**
     * @notice Initialization parameters for CctpExtension contract
     * @param owner The owner address
     * @param rescuer The rescuer address
     * @param tokenMessenger The CCTP TokenMessenger contract address
     * @param token The token contract address
     */
    struct InitParams {
        address owner;
        address rescuer;
        address tokenMessenger;
        address token;
    }

    //=========================== State Variables ============================

    /// @notice The CCTP TokenMessenger contract address
    address public tokenMessenger;

    /// @notice The token contract address
    address public token;

    //=========================== Initializer ============================

    /**
     * @notice Initializes the CctpExtension contract
     * @param params The initialization parameters struct
     */
    function initialize(InitParams calldata params) external initializer {
        require(params.owner != address(0), "Invalid owner address");
        require(params.rescuer != address(0), "Invalid rescuer address");
        require(params.tokenMessenger != address(0), "Invalid tokenMessenger");
        require(params.token != address(0), "Invalid token address");

        _transferOwnership(params.owner);
        _updateRescuer(params.rescuer);
        tokenMessenger = params.tokenMessenger;
        token = params.token;

        IERC20(params.token).safeIncreaseAllowance(params.tokenMessenger, type(uint256).max);
    }

    //=========================== External Functions ============================

    /// @inheritdoc ICctpExtension
    function batchDepositForBurnWithAuth(
        ReceiveWithAuthorizationData calldata _receiveWithAuthorizationData,
        DepositForBurnWithHookData calldata _depositForBurnData
    ) external override {
        // 1. Pull the total amount from the ERC-3009 authorization
        IEIP3009Token(token).receiveWithAuthorization(
            msg.sender,
            address(this),
            _receiveWithAuthorizationData.amount,
            _receiveWithAuthorizationData.authValidAfter,
            _receiveWithAuthorizationData.authValidBefore,
            _receiveWithAuthorizationData.authNonce,
            _receiveWithAuthorizationData.v,
            _receiveWithAuthorizationData.r,
            _receiveWithAuthorizationData.s
        );

        // 2. Determine the batch size and remaining amount
        uint256 batchSize = _depositForBurnData.amount;
        uint256 remaining = _receiveWithAuthorizationData.amount;

        // 3. Perform the deposit for burn with or without hook data
        if (_depositForBurnData.hookData.length > 0) {
            // Execute batched burns with hook data
            while (remaining > 0) {
                uint256 batchAmount = remaining > batchSize ? batchSize : remaining;
                TokenMessengerV2(tokenMessenger).depositForBurnWithHook(
                    batchAmount,
                    _depositForBurnData.destinationDomain,
                    _depositForBurnData.mintRecipient,
                    token,
                    _depositForBurnData.destinationCaller,
                    _depositForBurnData.maxFee,
                    _depositForBurnData.minFinalityThreshold,
                    _depositForBurnData.hookData
                );
                remaining = remaining.sub(batchAmount);
            }
        } else {
            // Execute batched burns without hook data
            while (remaining > 0) {
                uint256 batchAmount = remaining > batchSize ? batchSize : remaining;
                TokenMessengerV2(tokenMessenger).depositForBurn(
                    batchAmount,
                    _depositForBurnData.destinationDomain,
                    _depositForBurnData.mintRecipient,
                    token,
                    _depositForBurnData.destinationCaller,
                    _depositForBurnData.maxFee,
                    _depositForBurnData.minFinalityThreshold
                );
                remaining = remaining.sub(batchAmount);
            }
        }
    }
}
