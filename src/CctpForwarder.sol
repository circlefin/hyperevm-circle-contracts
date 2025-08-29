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

import {IReceiver} from "@evm-cctp-contracts/interfaces/IReceiver.sol";
import {MessageV2} from "@evm-cctp-contracts/messages/v2/MessageV2.sol";
import {BurnMessageV2} from "@evm-cctp-contracts/messages/v2/BurnMessageV2.sol";
import {AddressUtils} from "@evm-cctp-contracts/messages/v2/AddressUtils.sol";
import {Initializable} from "@evm-cctp-contracts/proxy/Initializable.sol";
import {TokenMessengerV2} from "@evm-cctp-contracts/v2/TokenMessengerV2.sol";
import {TypedMemView} from "@memview-sol/contracts/TypedMemView.sol";
import {SafeMath} from "@openzeppelin/contracts/math/SafeMath.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICctpForwarder} from "./interfaces/ICctpForwarder.sol";
import {Rescuable} from "./roles/Rescuable.sol";
import {IForwardDepositReceiver} from "./interfaces/IForwardDepositReceiver.sol";
import {CctpForwarderHookData} from "./messages/CctpForwarderHookData.sol";

/**
 * @title CctpForwarder
 * @notice Mint token via CCTP and forward to forwarding address on behalf of the forward recipient
 */
contract CctpForwarder is ICctpForwarder, Initializable, Rescuable {
    // ============ Structs ============
    struct CctpForwarderRoles {
        address owner;
        address rescuer;
    }

    // ============ Events ============
    /**
     * @notice Emitted when a token is minted and forwarded
     * @param forwardRecipient Forward recipient
     * @param forwardingAddress Forwarding address
     * @param token Local token address
     * @param amount Amount minted
     */
    event MintAndForward(
        address indexed forwardRecipient,
        address indexed forwardingAddress,
        address indexed token,
        uint256 amount
    );

    /**
     * @notice Emitted when a token forwarding address is added
     * @param token Local token address
     * @param forwardingAddress Forwarding address
     */
    event ForwardingAddressAdded(address token, address forwardingAddress);

    /**
     * @notice Emitted when a token forwarding address is removed
     * @param token Local token address
     * @param forwardingAddress Forwarding address
     */
    event ForwardingAddressRemoved(address token, address forwardingAddress);

    // ============ State Variables ============
    // Supported message versions
    uint32 public immutable supportedMessageVersion;
    uint32 public immutable supportedBurnMessageVersion;

    // Local CCTP Message Transmitter
    IReceiver public immutable messageTransmitter;

    // Local CCTP Token Messenger
    TokenMessengerV2 public immutable tokenMessenger;

    // Maps local ERC20 token address to associated forwarding address
    mapping(address => address) public tokenToForwardingAddress;

    // ============ Libraries ============
    using TypedMemView for bytes;
    using MessageV2 for bytes29;
    using BurnMessageV2 for bytes29;
    using AddressUtils for bytes32;
    using CctpForwarderHookData for bytes29;
    using SafeMath for uint256;

    /**
     * @notice Constructor
     * @param _messageTransmitter CCTP message transmitter
     * @param _tokenMessenger CCTP token messenger
     * @param _supportedMessageVersion Supported message version
     * @param _supportedBurnMessageVersion Supported burn message version
     */
    constructor(
        address _messageTransmitter,
        address _tokenMessenger,
        uint32 _supportedMessageVersion,
        uint32 _supportedBurnMessageVersion
    ) {
        require(
            _messageTransmitter != address(0),
            "MessageTransmitter not set"
        );
        require(_tokenMessenger != address(0), "TokenMessenger not set");
        messageTransmitter = IReceiver(_messageTransmitter);
        tokenMessenger = TokenMessengerV2(_tokenMessenger);
        supportedMessageVersion = _supportedMessageVersion;
        supportedBurnMessageVersion = _supportedBurnMessageVersion;
        _disableInitializers();
    }

    /**
     * @notice Initializes the forwarder contract
     * @dev Reverts if the tokens and forwarding addresses are not the same length
     * @param roles Roles configuration
     * @param _tokens Local token addresses
     * @param _forwardingAddresses Forwarding addresses
     */
    function initialize(
        CctpForwarderRoles calldata roles,
        address[] calldata _tokens,
        address[] calldata _forwardingAddresses
    ) external initializer {
        require(roles.owner != address(0), "Invalid roles.owner: zero address");
        require(
            _tokens.length == _forwardingAddresses.length,
            "Tokens and forwarding addresses must be the same length"
        );

        _transferOwnership(roles.owner);
        _updateRescuer(roles.rescuer);

        uint256 _tokensLength = _tokens.length;
        for (uint256 i; i < _tokensLength; ++i) {
            _addTokenForwardingAddress(_tokens[i], _forwardingAddresses[i]);
        }
    }

    /**
     * @notice Mint token and forward to forwarding address on behalf of the forward recipient
     * @param message CCTP receive message
     * @param attestation CCTP attestation
     */
    function mintAndForward(
        bytes calldata message,
        bytes calldata attestation
    ) external override {
        (
            uint32 sourceDomain,
            bytes32 burnToken,
            address forwardRecipient
        ) = _validateCctpMessage(message);

        // Get local token address
        address localToken = _getLocalToken(sourceDomain, burnToken);

        // Get forwarding address
        address forwardingAddress = tokenToForwardingAddress[localToken];
        require(forwardingAddress != address(0), "Forwarding address not set");

        require(
            forwardRecipient != address(0) &&
                forwardRecipient != localToken &&
                forwardRecipient != forwardingAddress,
            "Invalid forward recipient"
        );

        // Mint tokens through CCTP
        uint256 amountMinted = _mintThroughCctp(
            localToken,
            message,
            attestation
        );

        // Approve to forwarding address
        require(
            IERC20(localToken).approve(
                address(forwardingAddress),
                amountMinted
            ),
            "Failed to approve"
        );

        // Deposit to forwarding address
        IForwardDepositReceiver(forwardingAddress).depositFor(
            forwardRecipient,
            amountMinted
        );

        // Emit event
        emit MintAndForward(
            forwardRecipient,
            forwardingAddress,
            localToken,
            amountMinted
        );
    }

    /**
     * @notice Add a token forwarding address
     * @param token Local token address
     * @param forwardingAddress Forwarding address
     */
    function addTokenForwardingAddress(
        address token,
        address forwardingAddress
    ) external onlyOwner {
        _addTokenForwardingAddress(token, forwardingAddress);
    }

    /**
     * @notice Remove a token forwarding address
     * @param token Local token address
     */
    function removeTokenForwardingAddress(address token) external onlyOwner {
        address removedForwardingAddress = tokenToForwardingAddress[token];
        require(
            removedForwardingAddress != address(0),
            "Token forwarding address not set"
        );

        delete tokenToForwardingAddress[token];
        emit ForwardingAddressRemoved(token, removedForwardingAddress);
    }

    /**
     * @notice Add a token forwarding address
     * @param token Local token address
     * @param forwardingAddress Forwarding address
     */
    function _addTokenForwardingAddress(
        address token,
        address forwardingAddress
    ) internal {
        require(forwardingAddress != address(0), "Zero address not allowed");
        require(
            tokenToForwardingAddress[token] == address(0),
            "Forwarding address already set"
        );

        tokenToForwardingAddress[token] = forwardingAddress;
        emit ForwardingAddressAdded(token, forwardingAddress);
    }

    /**
     * @notice Mint tokens through CCTP
     * @param localTokenAddress Local token address
     * @param message CCTP receive message
     * @param attestation CCTP attestation
     * @return amountMinted Amount minted
     */
    function _mintThroughCctp(
        address localTokenAddress,
        bytes calldata message,
        bytes calldata attestation
    ) internal returns (uint256 amountMinted) {
        IERC20 localToken = IERC20(localTokenAddress);
        uint256 startingBalance = localToken.balanceOf(address(this));
        require(
            messageTransmitter.receiveMessage(message, attestation),
            "Failed to receive message"
        );
        amountMinted = localToken.balanceOf(address(this)).sub(startingBalance);
        require(amountMinted > 0, "No tokens minted");
    }

    /**
     * @notice Validate CCTP message and extract message details
     * @param _message CCTP receive message
     * @return sourceDomain Source domain
     * @return burnToken Burn token
     * @return forwardRecipient Forward recipient
     */
    function _validateCctpMessage(
        bytes calldata _message
    )
        internal
        view
        returns (
            uint32 sourceDomain,
            bytes32 burnToken,
            address forwardRecipient
        )
    {
        // Validate message and burn message
        bytes29 message = _message.ref(0);
        message._validateMessageFormat();
        require(
            MessageV2._getVersion(message) == supportedMessageVersion,
            "Unsupported message version"
        );
        bytes29 burnMessage = message._getMessageBody();
        burnMessage._validateBurnMessageFormat();
        require(
            BurnMessageV2._getVersion(burnMessage) ==
                supportedBurnMessageVersion,
            "Unsupported burn message version"
        );

        sourceDomain = message._getSourceDomain();
        require(
            message._getRecipient().toAddress() == address(tokenMessenger),
            "Invalid message recipient"
        );

        burnToken = burnMessage._getBurnToken();

        // Mint recipient must be this contract
        bytes32 mintRecipient = burnMessage._getMintRecipient();
        require(
            mintRecipient.toAddress() == address(this),
            "Mint recipient must be forwarder"
        );

        bytes29 hookData = burnMessage._getHookData();
        forwardRecipient = hookData._getForwardRecipient();
    }

    /**
     * @notice Get local token address from message recipient
     * @dev This function is static for safety. Assumes the message recipient is
     * a valid token messenger and points to a valid local minter.
     * @param sourceDomain Source domain
     * @param burnToken Burn token
     * @return localToken Local token address
     */
    function _getLocalToken(
        uint32 sourceDomain,
        bytes32 burnToken
    ) internal view returns (address) {
        return
            tokenMessenger.localMinter().getLocalToken(sourceDomain, burnToken);
    }
}
