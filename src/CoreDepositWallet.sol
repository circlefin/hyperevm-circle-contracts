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

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICoreDepositWallet} from "./interfaces/ICoreDepositWallet.sol";
import {Pausable} from "@evm-cctp-contracts/roles/Pausable.sol";
import {Rescuable} from "./roles/Rescuable.sol";
import {Initializable} from "@evm-cctp-contracts/proxy/Initializable.sol";
import {IBlacklistableERC20} from "./interfaces/IBlacklistableERC20.sol";

/**
 * @title CoreDepositWallet
 * @notice Contract for managing token deposits and transfers between HyperEVM and HyperCore.
 */
contract CoreDepositWallet is ICoreDepositWallet, Pausable, Rescuable, Initializable {
    // ============ Structs ============
    struct CoreDepositWalletRoles {
        address owner;
        address pauser;
        address rescuer;
    }

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
    IBlacklistableERC20 public immutable token;

    // The system address for the token spot asset on HyperCore.
    address public immutable tokenSystemAddress;

    // ============ Constructor ============
    /**
     * @notice Constructor
     * @param tokenAddress The address of the managed token.
     * @param _tokenSystemAddress The system address for the managed token on HyperCore.
     */
    constructor(address tokenAddress, address _tokenSystemAddress) {
        require(tokenAddress != address(0), "Invalid tokenAddress: zero address");
        require(_tokenSystemAddress != address(0), "Invalid _tokenSystemAddress: zero address");

        token = IBlacklistableERC20(tokenAddress);
        tokenSystemAddress = _tokenSystemAddress;
        _disableInitializers();
    }

    /**
     * @notice Initializes the forwarder contract
     * @dev Reverts if the tokens and forwarding addresses are not the same length
     * @param roles Roles configuration
     */
    function initialize(CoreDepositWalletRoles calldata roles) external initializer {
        require(roles.owner != address(0), "Invalid roles.owner: zero address");

        _transferOwnership(roles.owner);
        _updatePauser(roles.pauser);
        _updateRescuer(roles.rescuer);
    }

    // ============ External Functions  ============
    /**
     * @notice Deposits tokens to credit the corresponding address on HyperCore.
     * @param amount The amount of tokens being deposited.
     */
    function deposit(uint256 amount) external override whenNotPaused {
        _deposit(msg.sender, msg.sender, amount);
    }

    /**
     * @notice Deposits tokens from sender to CoreDepositWallet on HyperEVM and credits recipient on Hypercore.
     * @param sender The address sending the tokens on HyperEVM.
     * @param recipient The address receiving the tokens on HyperCore.
     * @param amount The amount of tokens being deposited.
     */
    function depositFor(address sender, address recipient, uint256 amount) external override whenNotPaused {
        require(recipient != address(0), "Invalid recipient: zero address");
        require(recipient != tokenSystemAddress, "Invalid recipient: system address");
        require(recipient != address(this), "Invalid recipient: CoreDepositWallet");
        require(!token.isBlacklisted(recipient), "Invalid recipient: blacklisted");
        _deposit(sender, recipient, amount);
    }

    /**
     * @notice Handles the token transfer from the CoreDepositWallet to the recipient.
     * @dev This function can only be called by the token's system address.
     * @param to The address receiving the tokens.
     * @param amount The amount of tokens being transferred.
     */
    function transfer(address to, uint256 amount) external override whenNotPaused {
        require(msg.sender == tokenSystemAddress, "Caller is not the system address");
        require(to != tokenSystemAddress, "Invalid to: system address");
        require(token.transfer(to, amount), "Transfer operation failed");

        emit Withdraw(to, amount);
    }

    /**
     * @dev Handles the token transfer from the sender to the CoreDepositWallet.
     * @param _sender The address initiating the deposit on HyperCore.
     * @param _recipient The address receiving the tokens on HyperEVM.
     * @param _amount The amount of tokens being deposited.
     */
    function _deposit(address _sender, address _recipient, uint256 _amount) internal {
        require(_amount > 0, "Amount must be greater than zero");
        require(token.transferFrom(_sender, address(this), _amount), "Transfer operation failed");
        
        emit Transfer(_recipient, tokenSystemAddress, _amount);
    }

    /**
     * @notice Rescue ERC20 tokens locked up in this contract.
     * @dev Reverts if tokenContract matches token.
     * @param tokenContract ERC20 token contract address
     * @param to        Recipient address
     * @param amount    Amount to withdraw
     */
    function _rescueERC20(IERC20 tokenContract, address to, uint256 amount) internal override {
        require(address(tokenContract) != address(token), "Cannot rescue token");
        super._rescueERC20(tokenContract, to, amount);
    }
}
