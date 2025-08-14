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
import {ICoreDepositWallet} from "./interfaces/ICoreDepositWallet.sol";

/**
 * @title CoreDepositWallet
 * @notice Contract for managing token deposits and transfers between HyperEVM and HyperCore.
 */
contract CoreDepositWallet is ICoreDepositWallet {
    // ============ Events ============
    /**
     * @notice Emitted when tokens are transferred into the contract.
     * @dev Required for HyperCore to correctly process deposits from HyperEVM.
     * @param from The address initiating the transfer.
     * @param to The address receiving the tokens.
     * @param amount The amount of tokens being transferred.
     */
    event Transfer(address indexed from, address indexed to, uint256 amount);

    /**
     * @notice Emitted when tokens are withdrawn from the contract.
     * @param to The address receiving the withdrawn tokens.
     * @param value The amount of tokens being withdrawn.
     */
    event Withdraw(address to, uint256 value);

    // ============ State Variables ============
    
    // The contract of the HyperEVM token that can be deposited and withdrawn.
    IERC20 public immutable TOKEN_CONTRACT;
    
    // The system address for the token spot asset on HyperCore.
    address public immutable TOKEN_SYSTEM_ADDRESS;

    // ============ Constructor ============
    /**
     * @param tokenContractAddress The address of the token contract.
     * @param tokenSystemAddress The system address for the token on HyperCore.
     */
    constructor (address tokenContractAddress, address tokenSystemAddress) public {
        TOKEN_CONTRACT = IERC20(tokenContractAddress);
        TOKEN_SYSTEM_ADDRESS = tokenSystemAddress;
    }

    // ============ External Functions  ============
    /**
     * @notice Deposits tokens to credit the corresponding address on HyperCore.
     * @param amount The amount of tokens being deposited.
     */
    function deposit(uint256 amount) external override 
    {
        _deposit(msg.sender, msg.sender, amount);
    }

    /**
    * @notice Deposits tokens from one address on HyperEVM to credit another address on HyperCore.
    * @param sender The address sending the tokens on HyperEVM.
    * @param recipient The address receiving the tokens on HyperCore.
    * @param amount The amount of tokens being deposited.
    */
    function depositFor(
        address sender,
        address recipient,
        uint256 amount
    ) 
        external 
        override 
    {
        require(recipient != address(0), "Cannot deposit to zero address");
        require(recipient != TOKEN_SYSTEM_ADDRESS, "Cannot deposit to system address");
        require(recipient != address(this), "Cannot deposit to wallet address");
        _deposit(sender, recipient, amount);
    }

    /**
    * @notice Handles the token transfer from the wallet contract to the recipient.
    * @dev This function can only be called by the token's system address. This ensures
    *      this is only used to receive tokens after a spotSend has been executed on HyperCore.
    * @param to The address receiving the tokens.
    * @param amount The amount of tokens being transferred.
    */
    function transfer(address to, uint256 amount) external override 
    {
        require(msg.sender == TOKEN_SYSTEM_ADDRESS, "Only system address can transfer");
        require(to != TOKEN_SYSTEM_ADDRESS, "Cannot transfer to system address");
        require(TOKEN_CONTRACT.transfer(to, amount), "Transfer operation failed");
        
        emit Withdraw(to, amount);
    }

    /** 
     * @dev Handles the token transfer from the sender to the wallet contract.
     * @param _sender The address initiating the deposit on HyperCore.
     * @param _recipient The address receiving the tokens on HyperEVM.
     * @param _amount The amount of tokens being deposited.
     */
    function _deposit(address _sender, address _recipient, uint256 _amount) internal {
        require(_amount > 0, "Amount must be greater than zero");
        require(TOKEN_CONTRACT.transferFrom(_sender, address(this), _amount), "Transfer operation failed");

        emit Transfer(_recipient, TOKEN_SYSTEM_ADDRESS, _amount);
    }
}
