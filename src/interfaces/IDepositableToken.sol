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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IEIP3009Token} from "./IEIP3009Token.sol";

/**
 * @title IDepositableToken
 * @notice Interface for a token that can be deposited into a CoreDepositWallet
 */
interface IDepositableToken is IERC20, IEIP3009Token {

    /**
     * @notice Checks if an account is blacklisted
     * @param _account The address to check
     */
    function isBlacklisted(address _account) external view returns (bool);
}