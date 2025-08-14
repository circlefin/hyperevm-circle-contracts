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

import {ICoreDepositWallet} from "./interfaces/ICoreDepositWallet.sol";

contract CoreDepositWallet is ICoreDepositWallet {
    function deposit(uint256 amount) external override 
    {
        revert("deposit: not implemented");
    }

    function depositFor(
        address sender,
        address recipient,
        uint256 amount
    ) 
        external 
        override 
    {
        revert("depositFor: not implemented");
    }

    function transfer(address to, uint256 amount) external override 
    {
        revert("transfer: not implemented");
    }
}
