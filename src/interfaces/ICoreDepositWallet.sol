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

import {IForwardDepositReceiver} from "./IForwardDepositReceiver.sol";

/**
 * @title ICoreDepositWallet
 * @notice Interface for the core deposit wallet
 */
interface ICoreDepositWallet is IForwardDepositReceiver {
    /**
     * @notice Deposits tokens for the sender.
     * @param amount The amount of tokens being deposited.
     * @param destinationDex The destination dex on HyperCore.
     */
    function deposit(uint256 amount, uint32 destinationDex) external;

    /**
     * @notice Handles the token transfer from the ICoreDepositWallet to the recipient.
     * @param to The address receiving the tokens.
     * @param amount The amount of tokens being transferred.
     * @return success True if the transfer succeeded.
     */
    function transfer(address to, uint256 amount) external returns (bool success);

    /**
     * @notice Handles the token transfer from the CoreDepositWallet to the recipient and initiates a cross-chain burn via CCTP.
     * @dev This function can only be called by the token's system address.
     * @param from The Hypercore address debited by the cross-chain withdrawal.
     * @param destinationRecipient The address receiving the minted tokens on the destination chain, as bytes32
     * @param destinationChainId The CCTP domain ID of the destination chain.
     * @param amount The amount of tokens being transferred.
     * @param data Optional additional data. If provided, it is used in depositForBurnWithHook; otherwise, a default hook is created to request a relay on the destination chain.
     */
    function coreReceiveWithData(address from, bytes32 destinationRecipient, uint32 destinationChainId, uint256 amount, bytes calldata data) external;

    /**
     * @notice Deposits tokens with authorization.
     * @param amount The amount of tokens being deposited.
     * @param authValidAfter The timestamp after which the authorization is valid.
     * @param authValidBefore The timestamp before which the authorization is valid.
     * @param authNonce A unique nonce for the authorization.
     * @param v The V value of the signature.
     * @param r The R value of the signature.
     * @param s The S value of the signature.
     * @param destinationDex The destination dex on HyperCore.
     */
    function depositWithAuth(
        uint256 amount,
        uint256 authValidAfter,
        uint256 authValidBefore,
        bytes32 authNonce,
        uint8 v,
        bytes32 r,
        bytes32 s,
        uint32 destinationDex
    ) external;
}
