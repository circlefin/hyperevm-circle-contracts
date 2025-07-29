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

/**
 * @title ICctpExtension
 * @notice Interface for CctpExtension contract that enables cross-chain token transfers
 *         by combining ERC-3009 authorization signatures with CCTP deposit-for-burn operations.
 *         Supports batched operations for gas optimization.
 */
interface ICctpExtension {
    /**
     * @notice The data needed to call receiveWithAuthorization on the IEIP3009Token contract.
     * @param amount                Total amount to authorize and transfer via ERC-3009. Must be > 0.
     * @param authValidAfter        The time after which the authorization is valid (unix time)
     * @param authValidBefore       The time before which authorization is valid (unix time)
     * @param authNonce             The authorization unique nonce
     * @param v                     v of the authorization signature
     * @param r                     r of the authorization signature
     * @param s                     s of the authorization signature
     */
    struct ReceiveWithAuthorizationData {
        uint256 amount;
        uint256 authValidAfter;
        uint256 authValidBefore;
        bytes32 authNonce;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    /**
     * @notice The data needed to call depositForBurn on the ITokenMessenger contract.
     * @param amount                Per-burn amount (batch size). Must be > 0 and evenly divide
     *                              the total authorized amount in batchDepositForBurnWithAuth.
     * @param destinationDomain     Domain of the chain where the tokens will be minted
     * @param mintRecipient         Recipient of the tokens on the destination chain
     * @param destinationCaller     Authorized caller on the destination domain, as bytes32. If equal to bytes32(0),
     *                              any address can broadcast the message.
     * @param maxFee                Maximum fee to pay on the destination domain, specified in units of burnToken.
     * @param minFinalityThreshold  The minimum finality at which a burn message will be attested to.
     * @param hookData              CCTP V2 hook data parameter - optional bytes passed to destination chain logic.
     */
    struct DepositForBurnWithHookData {
        uint256 amount;
        uint32 destinationDomain;
        bytes32 mintRecipient;
        bytes32 destinationCaller;
        uint256 maxFee;
        uint32 minFinalityThreshold;
        bytes hookData;
    }

    /**
     * @notice Executes CCTP burns using an ERC-3009 authorization. Runs either a single burn or
     *         multiple equal-sized burns based on the provided batch size.
     * @dev Caller must be the ERC-3009 authorization signer.
     *
     * Validation (checked before any token movement):
     * - `_receiveWithAuthorizationData.amount` must be > 0.
     * - `_depositForBurnData.amount` (batch size) must be > 0.
     * - `_receiveWithAuthorizationData.amount` must be evenly divisible by `_depositForBurnData.amount`.
     *
     * Batching semantics:
     * - Total authorized amount: `_receiveWithAuthorizationData.amount`.
     * - Batch size (per burn): `_depositForBurnData.amount`.
     * - Number of burns: total / batch size. Each burn uses the same batch size.
     *
     *
     * @param _receiveWithAuthorizationData ERC-3009 authorization data (see ReceiveWithAuthorizationData).
     *                                      Its `amount` is the total to be authorized and burned.
     * @param _depositForBurnData           CCTP parameters for burn operations (see DepositForBurnWithHookData).
     *                                      Its `amount` is the per-burn batch size.
     */
    function batchDepositForBurnWithAuth(
        ReceiveWithAuthorizationData calldata _receiveWithAuthorizationData,
        DepositForBurnWithHookData calldata _depositForBurnData
    ) external;
}
