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
import {TokenMessengerV2} from "@evm-cctp-contracts/v2/TokenMessengerV2.sol";
import {TypedMemView} from "@memview-sol/contracts/TypedMemView.sol";
import {CrossChainWithdrawalHookData} from "./messages/CrossChainWithdrawalHookData.sol";

/**
 * @title CoreDepositWallet
 * @notice Contract for managing token deposits and transfers between HyperEVM and HyperCore. This contract is specific to 6 decimals (HyperEVM) tokens that are scaled to 8 decimals (HyperCore).
 */
contract CoreDepositWallet is ICoreDepositWallet, Pausable, Rescuable, Initializable {
    // ============ Constants ============

    // CCTP protocol constants.
    uint32 private constant CCTP_FINALIZED_THRESHOLD = 2000; // Ensures CCTP waits for finality before attesting to messages sent by this contract.
    uint256 private constant CCTP_MAX_FEE = 0;
    uint256 private constant CCTP_DEFAULT_FORWARD_FEE = 200000; // 0.2 USDC (6 decimals)
    uint32 private constant CCTP_FEE_LIMIT = type(uint32).max;
    uint256 private constant MAX_HOOK_DATA_SIZE = 1024; // 1 KB The maximum allowed hook data size by this contract.
    // HyperCore protocol constants.
    uint8 private constant CORE_WRITER_ACTION_VERSION = 0x01;
    uint24 private constant CORE_WRITER_SEND_ASSET_ACTION_ID = 0x00000D;
    uint64 private constant CORE_TOKEN_INDEX = 0x0000000000000000;
    uint32 private constant CORE_SPOT_DEX_ID = type(uint32).max;
    uint32 private constant CORE_PERPS_DEX_ID = 0;
    uint256 private constant CORE_SCALING_FACTOR = 100; // 6 decimals -> 8 decimals (10^(8-6))
    address private constant CORE_WRITER_PRECOMPILE_ADDRESS = 0x3333333333333333333333333333333333333333;
    address private constant CORE_USER_EXISTS_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000810;
    uint64 private constant DEFAULT_NEW_CORE_ACCOUNT_FEE = 100000000; // 1 USDC (core asset units, 8 decimals)
    uint256 private constant MAX_TRANSFER_VALUE_FROM_EVM = type(uint64).max / CORE_SCALING_FACTOR; // max HyperCore asset units (uint64.max) / HyperCore -> EVM scaling factor (100)

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
        uint64 coreTokenIndex;
        uint32 coreSpotDexId;
        uint32 corePerpsDexId;
        address coreWriterPrecompileAddress;
        address coreUserExistsPrecompileAddress;
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
     * @notice Emitted when tokens are withdrawn from the contract and burned for cross-chain transfer.
     * @param from The Hypercore address debited by the cross-chain withdrawal.
     * @param to The address receiving the minted tokens on the destination chain, as bytes32.
     * @param value The amount of tokens being withdrawn and burned.
     * @param destinationDomain The CCTP domain ID of the destination chain.
     * @param coreNonce The HyperCore transaction nonce.
     */
    event CrossChainWithdraw(
        address indexed from, bytes32 indexed to, uint256 value, uint32 destinationDomain, uint64 indexed coreNonce
    );

    /**
     * @notice Emitted when the CCTP default maximum fee is updated.
     * @param previousFee The previous default maximum fee.
     * @param newFee The new default maximum fee.
     */
    event CctpMaxFeeUpdated(uint256 previousFee, uint256 newFee);

    /**
     * @notice Emitted when the CCTP default forwarding fee is updated.
     * @param previousFee The previous default forwarding fee.
     * @param newFee The new default forwarding fee.
     */
    event CctpDefaultForwardFeeUpdated(uint256 previousFee, uint256 newFee);

    /**
     * @notice Emitted when the CCTP forwarding fee is updated for a destination domain.
     * @param destinationDomain The CCTP domain ID of the destination chain.
     * @param previousFee The previous forwarding fee.
     * @param newFee The new forwarding fee.
     */
    event CctpForwardFeeUpdated(uint32 indexed destinationDomain, uint256 previousFee, uint256 newFee);

    /**
     * @notice Emitted when the newCoreAccountFee is updated
     * @param previousFee Previous fee in core asset units (8 decimals)
     * @param newFee New fee in core asset units (8 decimals)
     */
    event NewCoreAccountFeeUpdated(uint64 previousFee, uint64 newFee);

    /**
     * @notice Emitted when the newCoreAccountFee is deducted from a deposit to a non-existent HyperCore account.
     * @param coreRecipient The HyperCore recipient address
     * @param newCoreAccountFee The configured newCoreAccountFee in core asset units (8 decimals)
     * @param evmDepositAmount The original deposit amount in EVM token units (6 decimals)
     * @param coreSentAmount The amount sent to the recipient on HyperCore after the newCoreAccountFee fee is deducted in core asset units (8 decimals)
     */
    event NewCoreAccountFeeApplied(
        address indexed coreRecipient, uint64 newCoreAccountFee, uint256 evmDepositAmount, uint64 coreSentAmount
    );

    /**
     * @notice Emitted when a destination dex is disabled.
     * @param dex The disabled destination dex
     */
    event DexDisabled(uint32 indexed dex);

    /**
     * @notice Emitted when a destination dex is enabled.
     * @param dex The enabled destination dex
     */
    event DexEnabled(uint32 indexed dex);

    /**
     * @notice Emitted when dex forwarding is disabled.
     */
    event DexForwardingDisabled();

    /**
     * @notice Emitted when dex forwarding is enabled.
     */
    event DexForwardingEnabled();

    /**
     * @notice Emitted when the CoreWriter sendAsset action is called on HyperEVM to send assets to HyperCore.
     * @param coreRecipient The HyperCore recipient address
     * @param coreAmount The amount sent to the recipient on HyperCore in core token units (8 decimals)
     * @param destinationDex The destination dex on HyperCore
     */
    event SendAsset(address indexed coreRecipient, uint64 coreAmount, uint32 destinationDex);

    // ============ State Variables ============

    // The contract of the HyperEVM token that can be deposited and withdrawn.
    IDepositableToken public immutable token;

    // The contract of the HyperEVM CCTP TokenMessenger for cross-chain withdrawals.
    TokenMessengerV2 public immutable tokenMessenger;

    // The system address for the token spot asset on HyperCore.
    address public immutable tokenSystemAddress;

    // Fee deducted on HyperCore when the recipient has no existing account (core token units, 8 decimals).
    uint64 public newCoreAccountFee;

    // Default maximum fee for unforwarded cross-chain withdrawals via CCTP, initialized at 0 USDC.
    uint256 public cctpMaxFee;

    // Default forwarding fee for cross-chain withdrawals via CCTP, initialized at 0.2 USDC (6 decimals).
    uint256 public cctpDefaultForwardFee;

    // Per-destination domain flag indicating if a CCTP forwarding fee override is set for the destination domain.
    mapping(uint32 => bool) public isCctpForwardFeeSet;

    // Per-destination domain forwarding fee override used by coreReceiveWithData; falls back to cctpDefaultForwardFee if not set.
    mapping(uint32 => uint256) public cctpForwardFees;

    // Enabled destination dexes on HyperCore.
    // Note: Values set to true in this mapping represent dexes on Hypercore which are enabled
    // for forwarding deposits via CoreWriter. If a dex is not enabled,
    // deposits will be sent to the recipient address on Core spot instead.
    // The value of the mapping for the Core spot dex (uint32.max) is always left as false,
    // because deposits to the Core spot dex do not require forwarding by CoreWriter.
    mapping(uint32 => bool) public enabledDestinationDexes;

    // If true, deposits will be sent to the Core spot dex instead of the specified destination dex.
    bool public isDexForwardingDisabled;

    // ============ Constructor ============
    /**
     * @notice Constructor
     * @param tokenAddress The address of the managed token on HyperEVM.
     * @param _tokenSystemAddress The system address for the managed token on HyperCore.
     * @param tokenMessengerAddress The address of the CCTP TokenMessenger on HyperEVM.
     */
    constructor(address tokenAddress, address _tokenSystemAddress, address tokenMessengerAddress) {
        require(tokenAddress != address(0), "Invalid tokenAddress: zero address");
        require(_tokenSystemAddress != address(0), "Invalid _tokenSystemAddress: zero address");
        require(tokenMessengerAddress != address(0), "Invalid tokenMessengerAddress: zero address");

        token = IDepositableToken(tokenAddress);
        tokenSystemAddress = _tokenSystemAddress;
        tokenMessenger = TokenMessengerV2(tokenMessengerAddress);
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
        _setNewCctpMaxFee(CCTP_MAX_FEE);
        _setNewCctpDefaultForwardFee(CCTP_DEFAULT_FORWARD_FEE);
        enabledDestinationDexes[CORE_PERPS_DEX_ID] = true;
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
     * @notice Owner-only setter to update the default cross-chain message fee.
     * @param maxFee The new default maximum fee.
     */
    function updateCctpMaxFee(uint256 maxFee) external onlyOwner {
        _setNewCctpMaxFee(maxFee);
    }

    /**
     * @notice Owner-only setter to update the default cross-chain forwarding fee.
     * @param maxFee The new default forwarding fee.
     */
    function updateCctpDefaultForwardFee(uint256 maxFee) external onlyOwner {
        _setNewCctpDefaultForwardFee(maxFee);
    }

    /**
     * @notice Owner-only setter to update the cross-chain forwarding fee for a specific destination domain.
     * @param destinationDomain The destination domain identifier.
     * @param maxFee The maximum forwarding fee for the destination domain.
     */
    function updateCctpForwardFee(uint32 destinationDomain, uint256 maxFee) external onlyOwner {
        require(maxFee <= CCTP_FEE_LIMIT, "Forward fee exceeds fee limit");

        uint256 previousFee = cctpForwardFees[destinationDomain];
        cctpForwardFees[destinationDomain] = maxFee;
        isCctpForwardFeeSet[destinationDomain] = true;

        emit CctpForwardFeeUpdated(destinationDomain, previousFee, maxFee);
    }

    /**
     * @notice Owner-only function to unset a CCTP forwarding fee override for a destination domain.
     * @param destinationDomain The destination domain to unset the override for.
     */
    function unsetCctpForwardFee(uint32 destinationDomain) external onlyOwner {
        require(isCctpForwardFeeSet[destinationDomain], "Forwarding fee not set");

        uint256 previousFee = cctpForwardFees[destinationDomain];
        delete cctpForwardFees[destinationDomain];
        delete isCctpForwardFeeSet[destinationDomain];

        emit CctpForwardFeeUpdated(destinationDomain, previousFee, 0);
    }

    /**
     * @notice Owner-only function to enable dex forwarding.
     * @dev When dex forwarding is enabled, deposits to enabled destination dexes will be forwarded via CoreWriter.
     */
    function enableDexForwarding() external onlyOwner {
        require(isDexForwardingDisabled, "Dex forwarding already enabled");

        isDexForwardingDisabled = false;
        emit DexForwardingEnabled();
    }

    /**
     * @notice Owner-only function to disable dex forwarding.
     * @dev When dex forwarding is disabled, deposits will be sent to the Core spot dex instead of the specified destination dex.
     */
    function disableDexForwarding() external onlyOwner {
        require(!isDexForwardingDisabled, "Dex forwarding already disabled");

        isDexForwardingDisabled = true;
        emit DexForwardingDisabled();
    }

    /**
     * @notice Owner-only function to enable a destination dex.
     * @dev Cannot enable the Core spot dex (uint32.max.)
     * @param dex The destination dex to enable.
     */
    function enableDex(uint32 dex) external onlyOwner {
        require(dex != CORE_SPOT_DEX_ID, "Cannot enable spot dex");
        require(!enabledDestinationDexes[dex], "Dex already enabled");

        enabledDestinationDexes[dex] = true;
        emit DexEnabled(dex);
    }

    /**
     * @notice Owner-only function to disable a destination dex.
     * @param dex The destination dex to disable.
     */
    function disableDex(uint32 dex) external onlyOwner {
        require(enabledDestinationDexes[dex], "Dex already disabled");

        enabledDestinationDexes[dex] = false;
        emit DexDisabled(dex);
    }

    /**
     * @notice Deposits tokens to credit the corresponding address on HyperCore, on the specified destination dex.
     * @param amount The amount of tokens being deposited.
     * @param destinationDex The destination dex on HyperCore (0 for default Core Perps dex, uint32.max for Core Spot dex.)
     */
    function deposit(uint256 amount, uint32 destinationDex) external override whenNotPaused {
        _deposit(msg.sender, amount, destinationDex);
    }

    /**
     * @notice Deposits tokens to credit a specific recipient on Hypercore.
     * @param recipient The address receiving the tokens on HyperCore.
     * @param amount The amount of tokens being deposited.
     * @param destinationDex The destination dex on HyperCore (0 for default Core Perps dex, uint32.max for Core Spot dex.)
     */
    function depositFor(address recipient, uint256 amount, uint32 destinationDex) external override whenNotPaused {
        require(recipient != address(0), "Invalid recipient: zero address");
        require(recipient != tokenSystemAddress, "Invalid recipient: system address");
        require(recipient != address(this), "Invalid recipient: CoreDepositWallet");
        require(!token.isBlacklisted(recipient), "Invalid recipient: blacklisted");
        _deposit(recipient, amount, destinationDex);
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
     * @param destinationDex The destination dex on HyperCore (0 for default Core Perps dex, uint32.max for Core Spot dex.)
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

        _depositAndForwardIfDexEnabled(msg.sender, amount, destinationDex);
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
     * @notice Handles cross-chain token withdrawals from HyperCore to a destination chain via CCTP.
     * @dev This function initiates a cross-chain transfer of tokens using CCTP to mint tokens on the destination chain.
     *      It constructs and sends a CCTP message containing encoded hook data that embeds the optional user-provided
     *      data to be used on the destination chain and determines the CCTP forwarding behavior.
     *
     * @dev Requirements:
     *      - Caller must be the token system address.
     *      - `amount` must be strictly greater than the computed maximum withdrawal fee
     *        (see calculateCrossChainWithdrawalFee).
     *
     * @dev CCTP behavior:
     *      - The CCTP message's destinationCaller is always set to `bytes32(0)` and anyone can call
     *        MessageTransmitterV2.receiveMessage directly on the destination chain.
     * 
     * @dev Forwarding is the process of completing the mint on the destination chain by paying gas to
     *      submit a transaction that includes the CCTP attestation. When forwarding is requested:
     *      - The forwarder subtracts a configured amount of minted tokens from the final recipient,
     *        not exceeding the CCTP maxFee.
     *      - This forwarding amount is added to the CCTP maxFee to compute the total fee for the
     *        cross-chain withdrawal.
     * 
     * @dev Forwarding logic:
     * The forwarding logic is determined by the user-provided data:
     *      - If `data` is empty: the hook data will be a default forwarding hook and forwarding will be performed.
     *      - If `data` begins with the CCTP forwarding magic bytes: the hook data will embed `data` and forwarding will be performed.
     *      - Otherwise: the hook data will embed `data` and forwarding will NOT be performed.
     *
     * @dev Hook data encoding:
     * The hook data is constructed using the `CrossChainWithdrawalHookData` library. See that library for the full
     * encoding details.
     *
     * @param from The HyperCore address debited by the cross-chain withdrawal.
     * @param destinationRecipient The address receiving the minted tokens on the destination chain, as bytes32.
     * @param destinationChainId The CCTP domain ID of the destination chain.
     * @param amount The amount of tokens being transferred.
     * @param coreNonce The HyperCore transaction nonce.
     * @param data Optional user-provided data to embed in the CCTP message payload hook data; also determines the
     *             forwarding logic as described above. Must be less than or equal to MAX_HOOK_DATA_SIZE.
     */
    function coreReceiveWithData(
        address from,
        bytes32 destinationRecipient,
        uint32 destinationChainId,
        uint256 amount,
        uint64 coreNonce,
        bytes calldata data
    ) external override whenNotPaused {
        require(msg.sender == tokenSystemAddress, "Caller is not the system address");
        require(data.length <= MAX_HOOK_DATA_SIZE, "Data length exceeds MAX_HOOK_DATA_SIZE");

        bool shouldForward = _shouldForward(data);
        uint256 maxFee = calculateCrossChainWithdrawalFee(shouldForward, destinationChainId);
        require(amount > maxFee, "Amount must exceed maxFee");
        require(token.approve(address(tokenMessenger), amount), "Token approval failed");

        // Build the CCTP message payload hook data.
        bytes memory hookData = CrossChainWithdrawalHookData._build(shouldForward, from, coreNonce, data);

        tokenMessenger.depositForBurnWithHook(
            amount,
            destinationChainId,
            destinationRecipient,
            address(token),
            bytes32(0),
            maxFee,
            CCTP_FINALIZED_THRESHOLD,
            hookData
        );

        emit CrossChainWithdraw(from, destinationRecipient, amount, destinationChainId, coreNonce);
    }

    /**
     * @notice Returns the HyperCore protocol constants
     * @return constants The HyperCore protocol constants.
     */
    function getCoreProtocolConstants() external pure returns (CoreProtocolConstants memory constants) {
        return CoreProtocolConstants({
            coreWriterActionVersion: CORE_WRITER_ACTION_VERSION,
            coreWriterSendAssetActionId: CORE_WRITER_SEND_ASSET_ACTION_ID,
            coreTokenIndex: CORE_TOKEN_INDEX,
            coreSpotDexId: CORE_SPOT_DEX_ID,
            corePerpsDexId: CORE_PERPS_DEX_ID,
            coreWriterPrecompileAddress: CORE_WRITER_PRECOMPILE_ADDRESS,
            coreUserExistsPrecompileAddress: CORE_USER_EXISTS_PRECOMPILE_ADDRESS,
            coreScalingFactor: CORE_SCALING_FACTOR
        });
    }

    /**
     * @notice Calculates the maximum fee for the cross-chain withdrawal that will be used in depositForBurnWithHook.
     * @dev Behavior:
     *      - If shouldForward is false, maxFee = cctpMaxFee.
     *      - If shouldForward is true, maxFee = cctpMaxFee + forwardFee (if destination chain fee override exists, else cctpDefaultForwardFee).
     * @param shouldForward True if cross-chain forwarding should be performed, false otherwise.
     * @param destinationChainId CCTP domain ID of the destination chain.
     * @return maxFee The computed maximum fee for the cross-chain withdrawal that will be used in depositForBurnWithHook.
     */
    function calculateCrossChainWithdrawalFee(bool shouldForward, uint32 destinationChainId)
        public
        view
        returns (uint256 maxFee)
    {
        if (shouldForward) {
            uint256 forwardFee = isCctpForwardFeeSet[destinationChainId]
                ? cctpForwardFees[destinationChainId]
                : cctpDefaultForwardFee;
            maxFee = cctpMaxFee + forwardFee;
        } else {
            maxFee = cctpMaxFee;
        }
    }

    // ============ Internal Functions  ============
    /**
     * @notice Deposits tokens to the recipient's account on HyperCore.
     * @dev Handles the token transfer to the CoreDepositWallet on behalf of recipient.
     * @param _recipient The address receiving the tokens on HyperCore.
     * @param _amount The amount of tokens being deposited.
     * @param _destinationDex The destination dex on HyperCore.
     */
    function _deposit(address _recipient, uint256 _amount, uint32 _destinationDex) internal {
        require(_amount > 0, "Amount must be greater than zero");
        require(token.transferFrom(msg.sender, address(this), _amount), "Transfer operation failed");

        _depositAndForwardIfDexEnabled(_recipient, _amount, _destinationDex);
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

    /**
     * @notice Deposits tokens to the recipient's account on HyperCore.
     * @dev Behavior:
     *      - If dex forwarding is enabled and the specified destination dex is enabled, deposit to the
     *        CoreDepositWallet address on HyperCore Spot and forward to the recipient address on the specified
     *        destination dex via CoreWriter.
     *      - If dex forwarding is disabled, the destination dex is not enabled, or destinationDex is the
     *        HyperCore Spot dex, deposit to the recipient address on HyperCore Spot.
     *      - Reverts if _amount exceeds MAX_TRANSFER_VALUE_FROM_EVM.
     *
     * @param _recipient The address receiving the tokens on HyperCore.
     * @param _amount The amount of tokens being deposited.
     * @param _destinationDex The intended destination dex on HyperCore.
     */
    function _depositAndForwardIfDexEnabled(address _recipient, uint256 _amount, uint32 _destinationDex) internal {
        // Ensure the amount is not greater than the maximum HyperCore asset units
        require(_amount <= MAX_TRANSFER_VALUE_FROM_EVM, "Amount exceeds max transfer value from EVM");
        // If dex forwarding is enabled and the _destinationDex is enabled, deposit to the CoreDepositWallet address on HyperCore Spot
        // and forward to the _recipient address on the _destinationDex via CoreWriter.
        if (!isDexForwardingDisabled && enabledDestinationDexes[_destinationDex]) {
            // Transfer to the CoreDepositWallet address on HyperCore Spot.
            emit Transfer(address(this), tokenSystemAddress, _amount);
            // Forward to the _recipient address on the _destinationDex via CoreWriter.
            _sendAsset(_recipient, _amount, _destinationDex);
        }
        // Otherwise, deposit to the _recipient address on HyperCore Spot.
        else {
            // Transfer to the _recipient address on HyperCore Spot.
            emit Transfer(_recipient, tokenSystemAddress, _amount);
        }
    }

    /**
     * @notice Move the tokens from the CoreDepositWallet's spot to a destination dex on HyperCore via CoreWriter sendAsset action.
     * @dev Uses _coreUserExists() to check HyperCore account status and subtracts newCoreAccountFee from the deposit amount for new users.
     *      Scales the amount from 6 decimals (HyperEVM) to 8 decimals (HyperCore).
     *      Encodes a HyperCore CoreWriter sendAsset action:
     *      - Header (packed):
     *        - version: 1 byte (0x01)
     *        - actionId: 3 bytes big-endian (0x00000D = send asset)
     *      - Payload (ABI-encoded):
     *        (address recipient,         // recipient address on HyperCore
     *         address subAccount,        // always address(0) (subaccounts unused)
     *         uint32 sourceDex,          // Core Spot dex: type(uint32).max
     *         uint32 destinationDex,     // destination dex
     *         uint64 tokenIndex,         // 0 for USD on the main dex
     *         uint64 amount)             // amount in core asset units (8 decimals)
     *
     *      Encoding:
     *        bytes memory payload = abi.encode(
     *            recipient,
     *            address(0),
     *            CORE_SPOT_DEX_ID,
     *            destinationDex,
     *            CORE_TOKEN_INDEX,
     *            amount
     *        );
     *        bytes memory data = abi.encodePacked(CORE_WRITER_ACTION_VERSION, CORE_WRITER_SEND_ASSET_ACTION_ID, payload);
     *
     * @param recipient The address receiving the tokens on HyperCore.
     * @param evmAmount Amount of tokens to send from the CoreDepositWallet's spot to the destination dex in EVM token units (6 decimals).
     * @param destinationDex The destination dex on HyperCore.
     */
    function _sendAsset(address recipient, uint256 evmAmount, uint32 destinationDex) internal {
        uint256 scaledAmount = evmAmount * CORE_SCALING_FACTOR;
        uint64 coreAmount = uint64(scaledAmount);
        uint64 _newCoreAccountFee = newCoreAccountFee;

        if (_newCoreAccountFee > 0) {
            if (!_coreUserExists(recipient)) {
                require(coreAmount > _newCoreAccountFee, "Amount must exceed new account fee");
                coreAmount = coreAmount - _newCoreAccountFee;

                emit NewCoreAccountFeeApplied(recipient, _newCoreAccountFee, evmAmount, coreAmount);
            }
        }

        bytes memory payload = abi.encode(
            recipient,
            address(0),
            CORE_SPOT_DEX_ID,
            destinationDex,
            CORE_TOKEN_INDEX,
            coreAmount
        );
        bytes memory data = abi.encodePacked(CORE_WRITER_ACTION_VERSION, CORE_WRITER_SEND_ASSET_ACTION_ID, payload);

        ICoreWriter(CORE_WRITER_PRECOMPILE_ADDRESS).sendRawAction(data);

        emit SendAsset(recipient, coreAmount, destinationDex);
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

    /**
     * @notice Updates the cross-chain message fee.
     * @param _cctpMaxFee The new maximum fee.
     */
    function _setNewCctpMaxFee(uint256 _cctpMaxFee) internal {
        require(_cctpMaxFee <= CCTP_FEE_LIMIT, "Max fee exceeds fee limit");
        uint256 previous = cctpMaxFee;
        cctpMaxFee = _cctpMaxFee;
        emit CctpMaxFeeUpdated(previous, _cctpMaxFee);
    }

    /**
     * @notice Updates the default cross-chain forwarding fee.
     * @param _cctpDefaultForwardFee The new default forwarding fee.
     */
    function _setNewCctpDefaultForwardFee(uint256 _cctpDefaultForwardFee) internal {
        require(_cctpDefaultForwardFee <= CCTP_FEE_LIMIT, "Forward fee exceeds fee limit");
        uint256 previous = cctpDefaultForwardFee;
        cctpDefaultForwardFee = _cctpDefaultForwardFee;
        emit CctpDefaultForwardFeeUpdated(previous, _cctpDefaultForwardFee);
    }

    /**
     * @notice Queries the HyperCore precompile to determine if a user account exists.
     * @dev Makes a staticcall to the CORE_USER_EXISTS_PRECOMPILE_ADDRESS precompile.
     * @param user The address to check for existence on HyperCore
     * @return exists True if the user exists on HyperCore, false otherwise
     */
    function _coreUserExists(address user) internal view returns (bool) {
        (bool success, bytes memory result) = CORE_USER_EXISTS_PRECOMPILE_ADDRESS.staticcall(abi.encode(user));
        require(success, "Core user exists precompile call failed");
        return abi.decode(result, (CoreUserExists)).exists;
    }

    /**
     * @notice Determines if cross-chain withdrawal forwarding should be performed.
     * @dev If `data` is empty, cross-chain withdrawal forwarding should be performed.
     * @dev If `data` begins with the CCTP forwarding magic bytes, cross-chain withdrawal forwarding should be performed.
     * @dev Otherwise, cross-chain withdrawal forwarding should not be performed.
     * @dev Reverts if hook data is malformed.
     * @param data The user-provided hook data.
     * @return True if cross-chain withdrawal forwarding should be performed, false otherwise.
     */
    function _shouldForward(bytes calldata data) internal pure returns (bool) {
        if (data.length == 0) return true;
        bytes29 _data = TypedMemView.ref(data, 0);
        CrossChainWithdrawalHookData._validateHookData(_data);
        return CrossChainWithdrawalHookData._hasForwardingMagicBytes(_data);
    }
}
