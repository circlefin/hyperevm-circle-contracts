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
import {IDepositableToken} from "./interfaces/IDepositableToken.sol";
import {ICoreWriter} from "./interfaces/ICoreWriter.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/SafeCast.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";

/**
 * @title CoreDepositWallet
 * @notice Contract for managing token deposits and transfers between HyperEVM and HyperCore. This contract is specific to 6 decimals (HyperEVM) tokens that are scaled to 8 decimals (HyperCore).
 */
contract CoreDepositWallet is ICoreDepositWallet, Pausable, Rescuable, Initializable {
    using SafeCast for uint256;
    using SafeMath for uint256;

    // ============ Constants ============
    uint8 private constant CORE_WRITER_ACTION_VERSION = 0x01;
    uint24 private constant CORE_WRITER_SEND_ASSET_ACTION_ID = 0x00000D;
    uint64 private constant CORE_WRITER_TOKEN_INDEX = 0x0000000000000000;
    uint32 private constant CORE_WRITER_SOURCE_SPOT_DEX = type(uint32).max;
    uint32 private constant CORE_WRITER_DESTINATION_PERP_DEX = 0x00000000;
    uint256 private constant CORE_SCALING_FACTOR = 100; // 6 decimals -> 8 decimals (10^(8-6))
    address private constant CORE_WRITER_ADDRESS = 0x3333333333333333333333333333333333333333;
    address private constant CORE_USER_EXISTS_ADDRESS = 0x0000000000000000000000000000000000000810;
    uint64 private constant DEFAULT_NEW_CORE_ACCOUNT_FEE = 100000000; // 1 USDC (core token units, 8 decimals)

    // ============ Structs ============
    struct CoreDepositWalletRoles {
        address owner;
        address pauser;
        address rescuer;
    }

    /**
     * @notice Read-only view of the HyperCore protocol constants
     */
    struct CoreProtocolConstants {
        uint8 coreWriterActionVersion;
        uint24 coreWriterSendAssetActionId;
        uint64 coreWriterTokenIndex;
        uint32 coreWriterSourceSpotDex;
        uint32 coreWriterDestinationPerpDex;
        address coreWriterAddress;
        address coreUserExistsAddress;
        uint256 coreScalingFactor;
    }

    /**
     * @notice Read-only view of the HyperCore user exists precompile return value
     */
    struct CoreUserExists {
        bool exists;
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
    event Withdraw(address indexed to, uint256 value);

    /**
     * @notice Emitted when the newCoreAccountFee is updated
     * @param previousFee Previous fee in core token units (8 decimals)
     * @param newFee New fee in core token units (8 decimals)
     */
    event NewCoreAccountFeeUpdated(uint64 previousFee, uint64 newFee);

    /**
     * @notice Emitted when the newCoreAccountFee is deducted from a deposit to a non-existent HyperCore account.
     * @param coreRecipient The HyperCore recipient address
     * @param newCoreAccountFee The configured newCoreAccountFee in core token units (8 decimals)
     * @param evmDepositAmount The original deposit amount in token units (6 decimals)
     * @param coreSentAmount The amount sent to the recipient on HyperCore after the newCoreAccountFee fee is deducted in core token units (8 decimals)
     */
    event NewCoreAccountFeeApplied(
        address indexed coreRecipient, uint64 newCoreAccountFee, uint256 evmDepositAmount, uint64 coreSentAmount
    );

    /**
     * @notice Emitted when the CoreWriter sendAsset action is called on HyperEVM to send assets to HyperCore.
     * @param coreRecipient The HyperCore recipient address
     * @param coreAmount The amount sent to the recipient on HyperCore in core token units (8 decimals)
     */
    event SendAsset(address indexed coreRecipient, uint64 coreAmount);

    // ============ State Variables ============

    // The contract of the HyperEVM token that can be deposited and withdrawn.
    IDepositableToken public immutable token;

    // The system address for the token spot asset on HyperCore.
    address public immutable tokenSystemAddress;

    // Fee deducted on HyperCore when the recipient has no existing account (core token units, 8 decimals).
    uint64 public newCoreAccountFee;

    // ============ Constructor ============
    /**
     * @notice Constructor
     * @param tokenAddress The address of the managed token on HyperEVM.
     * @param _tokenSystemAddress The system address for the managed token on HyperCore.
     */
    constructor(address tokenAddress, address _tokenSystemAddress) {
        require(tokenAddress != address(0), "Invalid tokenAddress: zero address");
        require(_tokenSystemAddress != address(0), "Invalid _tokenSystemAddress: zero address");

        token = IDepositableToken(tokenAddress);
        tokenSystemAddress = _tokenSystemAddress;
        _disableInitializers();
    }

    /**
     * @notice Initializes the CoreDepositWallet contract
     * @dev Reverts if the tokens and forwarding addresses are not the same length.
     * @param roles Roles configuration
     */
    function initialize(CoreDepositWalletRoles calldata roles) external initializer {
        require(roles.owner != address(0), "Invalid roles.owner: zero address");

        _transferOwnership(roles.owner);
        _updatePauser(roles.pauser);
        _updateRescuer(roles.rescuer);
        _setNewCoreAccountFee(DEFAULT_NEW_CORE_ACCOUNT_FEE);
    }

    // ============ External Functions  ============
    /**
     * @notice Owner-only setter to update the new core account fee
     * @dev This fee is deducted from deposit amounts when _coreUserExists returns false. This fee is in core token units (8 decimals).
     * @param fee New fee amount in core token units (8 decimals).
     */
    function updateNewCoreAccountFee(uint64 fee) external onlyOwner {
        _setNewCoreAccountFee(fee);
    }

    /**
     * @notice Deposits tokens to credit the corresponding address on HyperCore.
     * @param amount The amount of tokens being deposited.
     */
    function deposit(uint256 amount) external override whenNotPaused {
        _deposit(msg.sender, amount);
    }

    /**
     * @notice Deposits tokens to credit a specific recipient on Hypercore.
     * @param recipient The address receiving the tokens on HyperCore.
     * @param amount The amount of tokens being deposited.
     */
    function depositFor(address recipient, uint256 amount) external override whenNotPaused {
        require(recipient != address(0), "Invalid recipient: zero address");
        require(recipient != tokenSystemAddress, "Invalid recipient: system address");
        require(recipient != address(this), "Invalid recipient: CoreDepositWallet");
        require(!token.isBlacklisted(recipient), "Invalid recipient: blacklisted");
        _deposit(recipient, amount);
    }

    /**
     * @notice Deposits tokens with authorization to credit the sender on HyperCore.
     * @param amount The amount of tokens being deposited.
     * @param authValidAfter The timestamp after which the authorization is valid.
     * @param authValidBefore The timestamp before which the authorization is valid.
     * @param authNonce A unique nonce for the authorization.
     * @param v The V value of the signature.
     * @param r The R value of the signature.
     * @param s The S value of the signature.
     */
    function depositWithAuth(
        uint256 amount,
        uint256 authValidAfter,
        uint256 authValidBefore,
        bytes32 authNonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external override whenNotPaused {
        require(amount > 0, "Amount must be greater than zero");
        token.receiveWithAuthorization(
            msg.sender,
            address(this),
            amount,
            authValidAfter,
            authValidBefore,
            authNonce,
            v,
            r,
            s
        );

        emit Transfer(address(this), tokenSystemAddress, amount);
        _sendAsset(msg.sender, amount);
    }

    /**
     * @notice Handles the token transfer from the CoreDepositWallet to the recipient.
     * @dev This function can only be called by the token's system address.
     * @param to The address receiving the tokens.
     * @param amount The amount of tokens being transferred.
     * @return success True if the transfer succeeded.
     */
    function transfer(address to, uint256 amount) external override whenNotPaused returns (bool success) {
        require(msg.sender == tokenSystemAddress, "Caller is not the system address");
        require(to != tokenSystemAddress, "Invalid to: system address");
        require(token.transfer(to, amount), "Transfer operation failed");

        emit Withdraw(to, amount);
        return true;
    }

    /**
     * @notice Returns the HyperCore protocol constants
     */
    function getCoreProtocolConstants() external pure returns (CoreProtocolConstants memory constants) {
        return CoreProtocolConstants({
            coreWriterActionVersion: CORE_WRITER_ACTION_VERSION,
            coreWriterSendAssetActionId: CORE_WRITER_SEND_ASSET_ACTION_ID,
            coreWriterTokenIndex: CORE_WRITER_TOKEN_INDEX,
            coreWriterSourceSpotDex: CORE_WRITER_SOURCE_SPOT_DEX,
            coreWriterDestinationPerpDex: CORE_WRITER_DESTINATION_PERP_DEX,
            coreWriterAddress: CORE_WRITER_ADDRESS,
            coreUserExistsAddress: CORE_USER_EXISTS_ADDRESS,
            coreScalingFactor: CORE_SCALING_FACTOR
        });
    }

    /**
     * @dev Handles the token transfer to the CoreDepositWallet on behalf of recipient.
     * @param _recipient The address receiving the tokens on HyperCore.
     * @param _amount The amount of tokens being deposited.
     */
    function _deposit(address _recipient, uint256 _amount) internal {
        require(_amount > 0, "Amount must be greater than zero");
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer operation failed");

        emit Transfer(address(this), tokenSystemAddress, _amount);

        _sendAsset(_recipient, _amount);
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

    // ============ Internal Functions  ============

    /**
     * @notice Move the tokens from spot to perp on HyperCore via CoreWriter sendAsset action.
     * @dev Uses _coreUserExists() to check HyperCore account status and subtracts newCoreAccountFee from the deposit amount for new users.
     *      Scales the amount from 6 decimals (HyperEVM) to 8 decimals (HyperCore).
     *      Encodes a Hyperliquid CoreWriter sendAsset action:
     *      - Header (packed):
     *        - version: 1 byte (0x01)
     *        - actionId: 3 bytes big-endian (0x00000D = send asset)
     *      - Payload (ABI-encoded):
     *        (address recipient,         // recipient address on HyperCore
     *         address subAccount,        // always address(0) (subaccounts unused)
     *         uint32 sourceDex,          // spot: type(uint32).max
     *         uint32 destinationDex,     // perp: 0
     *         uint64 tokenIndex,         // 0 for USD on the main dex
     *         uint64 amount)             // SafeCast enforces uint64; reverts on overflow
     *
     *      Encoding:
     *        bytes memory payload = abi.encode(
     *            recipient,
     *            address(0),
     *            SOURCE_SPOT_DEX,
     *            DESTINATION_PERP_DEX,
     *            TOKEN_INDEX,
     *            amount.toUint64()
     *        );
     *        bytes memory data = abi.encodePacked(ACTION_VERSION, SEND_ASSET_ACTION_ID, payload);
     *
     * @param recipient The address receiving the tokens on HyperCore.
     * @param evmAmount Amount of tokens to send from HyperCore spot to HyperCore perps in evm token units (6 decimals).
     */
    function _sendAsset(address recipient, uint256 evmAmount) internal {
        uint256 scaledAmount = evmAmount.mul(CORE_SCALING_FACTOR);
        uint64 coreAmount = scaledAmount.toUint64();
        uint64 _newCoreAccountFee = newCoreAccountFee;

        if (_newCoreAccountFee > 0) {
            bool userExists = _coreUserExists(recipient);
            if (!userExists) {
                require(coreAmount > _newCoreAccountFee, "Amount must exceed new account fee");
                coreAmount = coreAmount - _newCoreAccountFee;

                emit NewCoreAccountFeeApplied(recipient, _newCoreAccountFee, evmAmount, coreAmount);
            }
        }

        bytes memory payload = abi.encode(
            recipient,
            address(0),
            CORE_WRITER_SOURCE_SPOT_DEX,
            CORE_WRITER_DESTINATION_PERP_DEX,
            CORE_WRITER_TOKEN_INDEX,
            coreAmount
        );
        bytes memory data = abi.encodePacked(CORE_WRITER_ACTION_VERSION, CORE_WRITER_SEND_ASSET_ACTION_ID, payload);

        ICoreWriter(CORE_WRITER_ADDRESS).sendRawAction(data);

        emit SendAsset(recipient, coreAmount);
    }

    /**
     * @notice Queries the HyperCore precompile to determine if a user account exists.
     * @dev Makes a staticcall to the CORE_USER_EXISTS_ADDRESS precompile at 0x810.
     * @param user The address to check for existence on HyperCore
     * @return exists True if the user exists on HyperCore, false otherwise
     */
    function _coreUserExists(address user) internal view returns (bool) {
        (bool success, bytes memory result) = CORE_USER_EXISTS_ADDRESS.staticcall(abi.encode(user));
        require(success, "Core user exists precompile call failed");
        return abi.decode(result, (CoreUserExists)).exists;
    }

    /**
     * @notice Updates the fee applied to deposits for users who don't exist on HyperCore.
     * @dev This fee is deducted from deposit amounts when _coreUserExists returns false.
     * @param _newCoreAccountFee The new account creation fee in core token units (8 decimals).
     */
    function _setNewCoreAccountFee(uint64 _newCoreAccountFee) internal {
        uint64 previous = newCoreAccountFee;
        newCoreAccountFee = _newCoreAccountFee;
        emit NewCoreAccountFeeUpdated(previous, _newCoreAccountFee);
    }
}
