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

/**
 * @title ICoreWriter
 * @notice Interface for the CoreWriter precompile contract on HyperEVM.
 */
interface ICoreWriter {
    /**
     * @notice Sends a raw action to the CoreWriter precompile contract.
     * @dev This function is used to send a raw action to the CoreWriter precompile contract. Used by the CoreDepositWallet for asset transfers.
     * @param data The data to send to the CoreWriter precompile contract.
     */
    function sendRawAction(bytes calldata data) external;
}
