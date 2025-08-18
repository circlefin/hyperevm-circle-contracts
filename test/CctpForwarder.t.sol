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

import {BurnMessageV2} from "@evm-cctp-contracts/messages/v2/BurnMessageV2.sol";
import {MessageV2} from "@evm-cctp-contracts/messages/v2/MessageV2.sol";
import {AddressUtils} from "@evm-cctp-contracts/messages/v2/AddressUtils.sol";
import {Test, console} from "forge-std/Test.sol";
import {CctpForwarder} from "../src/CctpForwarder.sol";
import {MockMintBurnToken} from "lib/evm-cctp-contracts/test/mocks/MockMintBurnToken.sol";
import {MockMessageTransmitterV2, MockTokenMessengerV2, MockTokenMinterV2, MockStatefulTokenMessengerV2} from "./mocks/MockCctpContracts.sol";
import {MockCoreDepositWallet} from "./mocks/MockCoreDepositWallet.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CctpForwarderTest is Test {
    // Events for testing
    event MintAndForward(
        address indexed forwardRecipient,
        address indexed forwardingAddress,
        address indexed token,
        uint256 amount
    );

    MockMintBurnToken public TOKEN = new MockMintBurnToken();
    MockMessageTransmitterV2 public MESSAGE_TRANSMITTER =
        new MockMessageTransmitterV2(address(TOKEN));
    MockTokenMinterV2 public TOKEN_MINTER =
        new MockTokenMinterV2(address(TOKEN));
    MockTokenMessengerV2 public TOKEN_MESSENGER =
        new MockTokenMessengerV2(address(TOKEN_MINTER));
    MockCoreDepositWallet public CORE_DEPOSIT_WALLET =
        new MockCoreDepositWallet();

    CctpForwarder public forwarder;

    // ============ Default Burn Message ============
    uint32 constant BURN_VERSION = 1;
    bytes32 BURN_TOKEN;
    bytes32 MINT_RECIPIENT;
    uint256 constant AMOUNT = 100;
    bytes32 constant MESSAGE_SENDER = bytes32(0);
    uint256 constant MAX_FEE = 10;
    uint256 constant FEE_EXECUTED = 5;
    uint256 constant EXPIRATION_BLOCK = 0;
    bytes constant HOOK_DATA =
        abi.encodePacked(
            bytes24("cctp-relay"), // 24 bytes magic section
            uint32(0),
            uint32(20),
            FORWARD_RECIPIENT
        );

    // ============ Default Message ============
    uint32 constant MESSAGE_VERSION = 1;
    uint32 constant SOURCE_DOMAIN = 1;
    uint32 constant DESTINATION_DOMAIN = 19;
    bytes32 constant SENDER = bytes32(0);
    bytes32 RECIPIENT;
    bytes32 constant DESTINATION_CALLER = bytes32(0);

    bytes public constant VALID_SIGNATURE = "valid signature";
    address constant FORWARD_RECIPIENT = address(123);

    // ============ Libraries ============
    using AddressUtils for address;

    function setUp() public {
        // TODO: setup through proxy and initializer
        forwarder = new CctpForwarder(
            address(MESSAGE_TRANSMITTER),
            MESSAGE_VERSION,
            BURN_VERSION
        );
        forwarder.addTokenForwardingAddress(
            address(TOKEN),
            address(CORE_DEPOSIT_WALLET)
        );

        BURN_TOKEN = address(TOKEN).toBytes32();
        MINT_RECIPIENT = address(forwarder).toBytes32();
        RECIPIENT = address(TOKEN_MESSENGER).toBytes32();
    }

    function emptyBytes() internal pure returns (bytes calldata result) {
        assembly {
            result.offset := 0
            result.length := 0
        }
    }

    function _formatBurnMessageForRelay(
        uint32 _version,
        bytes32 _burnToken,
        bytes32 _mintRecipient,
        uint256 _amount,
        bytes32 _messageSender,
        uint256 _maxFee,
        uint256 _feeExecuted,
        uint256 _expirationBlock,
        bytes memory _hookData
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                _version,
                _burnToken,
                _mintRecipient,
                _amount,
                _messageSender,
                _maxFee,
                _feeExecuted,
                _expirationBlock,
                _hookData
            );
    }

    function _formatMessageForRelay(
        uint32 _version,
        uint32 _sourceDomain,
        uint32 _destinationDomain,
        bytes32 _sender,
        bytes32 _recipient,
        bytes32 _destinationCaller,
        bytes memory _messageBody
    ) internal pure returns (bytes memory) {
        return
            abi.encodePacked(
                _version,
                _sourceDomain,
                _destinationDomain,
                bytes32(0), // nonce
                _sender,
                _recipient,
                _destinationCaller,
                uint32(0), // minFinalityThreshold
                uint32(0), // finalityThresholdExecuted
                _messageBody
            );
    }

    function test_Constructor_revertsIfMessageTransmitterNotSet() public {
        vm.expectRevert("MessageTransmitter not set");
        new CctpForwarder(address(0), MESSAGE_VERSION, BURN_VERSION);
    }

    function test_MintAndForward_revertsIfInvalidMessage() public {
        bytes memory message = "";
        vm.expectRevert("Invalid message: too short");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_MintAndForward_revertsIfReceiveMessageFails() public {
        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            HOOK_DATA
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        // Revert
        bytes memory signature = bytes("revert");
        vm.expectRevert("mock revert");
        forwarder.mintAndForward(message, signature);

        // Return false
        signature = bytes("return false");
        vm.expectRevert("Failed to receive message");
        forwarder.mintAndForward(message, signature);
    }

    function test_MintAndForward_revertsIfInvalidBurnMessage() public {
        bytes memory burnMessage = "";
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        vm.expectRevert("Invalid burn message: too short");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_MintAndForward_revertsIfForwardingAddressNotSet() public {
        // Remove forwarding address
        forwarder.removeTokenForwardingAddress(address(TOKEN));

        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            HOOK_DATA
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        vm.expectRevert("Forwarding address not set");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_MintAndForward_revertsIfInvalidMintRecipient() public {
        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            bytes32(0), // invalid mint recipient
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            HOOK_DATA
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        vm.expectRevert("Mint recipient must be forwarder");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_MintAndForward_revertsIfAmountIsZero() public {
        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            MINT_RECIPIENT,
            0, // amount is zero
            MESSAGE_SENDER,
            MAX_FEE,
            0, // fee is also zero to avoid overflow
            EXPIRATION_BLOCK,
            HOOK_DATA
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        vm.expectRevert("No tokens minted");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_MintAndForward_revertsIfInvalidHookDataLength() public {
        bytes memory hookWithInvalidLength = abi.encodePacked(
            bytes24("cctp-relay"), // 24 bytes magic section
            uint32(0),
            uint32(20)
        );
        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            hookWithInvalidLength
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        vm.expectRevert("Invalid hook data: too short");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_MintAndForward_revertsIfInvalidHookVersion() public {
        bytes memory hookWithInvalidVersion = abi.encodePacked(
            bytes24("cctp-relay"), // 24 bytes magic section
            uint32(1), // invalid version
            uint32(20),
            address(forwarder)
        );
        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            hookWithInvalidVersion
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        vm.expectRevert("Invalid hook data: version");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_GetLocalToken_isStatic() public {
        MockStatefulTokenMessengerV2 statefulTokenMessenger = new MockStatefulTokenMessengerV2(
                address(TOKEN_MINTER)
            );

        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            HOOK_DATA
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            address(statefulTokenMessenger).toBytes32(),
            DESTINATION_CALLER,
            burnMessage
        );
        assertEq(statefulTokenMessenger.counter(), 0);
        vm.expectCall(
            address(statefulTokenMessenger),
            abi.encodeWithSelector(
                MockStatefulTokenMessengerV2.localMinter.selector
            )
        );
        vm.expectRevert(); // EvmError: StateChangeDuringStaticCall
        forwarder.mintAndForward(message, VALID_SIGNATURE);
        assertEq(statefulTokenMessenger.counter(), 0);
    }

    function test_MintAndForward_revertsIfInvalidForwardRecipient() public {
        // Test cases: zero address, TOKEN address, and deposit wallet address
        address[3] memory invalidRecipients = [
            address(0), // zero address
            address(TOKEN), // TOKEN address
            address(CORE_DEPOSIT_WALLET) // deposit wallet address
        ];

        for (uint256 i = 0; i < invalidRecipients.length; i++) {
            bytes memory hookWithInvalidRecipient = abi.encodePacked(
                bytes24("cctp-relay"), // 24 bytes magic section
                uint32(0),
                uint32(20),
                invalidRecipients[i] // invalid forward recipient
            );
            bytes memory burnMessage = _formatBurnMessageForRelay(
                BURN_VERSION,
                BURN_TOKEN,
                MINT_RECIPIENT,
                AMOUNT,
                MESSAGE_SENDER,
                MAX_FEE,
                FEE_EXECUTED,
                EXPIRATION_BLOCK,
                hookWithInvalidRecipient
            );
            bytes memory message = _formatMessageForRelay(
                MESSAGE_VERSION,
                SOURCE_DOMAIN,
                DESTINATION_DOMAIN,
                SENDER,
                RECIPIENT,
                DESTINATION_CALLER,
                burnMessage
            );
            vm.expectRevert("Invalid forward recipient");
            forwarder.mintAndForward(message, VALID_SIGNATURE);
        }
    }

    function test_MintAndForward_revertsIfFailedToApprove() public {
        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            HOOK_DATA
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        vm.mockCall(
            address(TOKEN),
            abi.encodeWithSelector(
                IERC20.approve.selector,
                address(CORE_DEPOSIT_WALLET),
                AMOUNT - FEE_EXECUTED
            ),
            abi.encode(false)
        );
        vm.expectRevert("Failed to approve");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_MintAndForward_revertsIfFailedToDeposit() public {
        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            HOOK_DATA
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        vm.mockCallRevert(
            address(CORE_DEPOSIT_WALLET),
            abi.encodeWithSelector(
                MockCoreDepositWallet.depositFor.selector,
                address(forwarder),
                FORWARD_RECIPIENT,
                AMOUNT - FEE_EXECUTED
            ),
            "revert"
        );
        vm.expectRevert("revert");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_MintAndForward_succeeds() public {
        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            HOOK_DATA
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        // Receives
        vm.expectCall(
            address(MESSAGE_TRANSMITTER),
            abi.encodeWithSelector(
                MockMessageTransmitterV2.receiveMessage.selector,
                message,
                VALID_SIGNATURE
            )
        );
        // Approves
        vm.expectCall(
            address(TOKEN),
            abi.encodeWithSelector(
                IERC20.approve.selector,
                address(CORE_DEPOSIT_WALLET),
                AMOUNT - FEE_EXECUTED
            )
        );
        // Deposits
        vm.expectCall(
            address(CORE_DEPOSIT_WALLET),
            abi.encodeWithSelector(
                MockCoreDepositWallet.depositFor.selector,
                address(forwarder),
                FORWARD_RECIPIENT,
                AMOUNT - FEE_EXECUTED
            )
        );
        // Expect MintAndForward event
        vm.expectEmit(true, true, true, true);
        emit MintAndForward(
            FORWARD_RECIPIENT,
            address(CORE_DEPOSIT_WALLET),
            address(TOKEN),
            AMOUNT - FEE_EXECUTED
        );
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_MintAndForward_revertsIfUnsupportedMessageVersion() public {
        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            HOOK_DATA
        );
        bytes memory message = _formatMessageForRelay(
            2, // unsupported message version
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        vm.expectRevert("Unsupported message version");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_MintAndForward_revertsIfUnsupportedBurnMessageVersion()
        public
    {
        bytes memory burnMessage = _formatBurnMessageForRelay(
            2, // unsupported burn message version
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            HOOK_DATA
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        vm.expectRevert("Unsupported burn message version");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_MintAndForward_revertsIfZeroMessageVersion() public {
        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            HOOK_DATA
        );
        bytes memory message = _formatMessageForRelay(
            0, // zero message version
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        vm.expectRevert("Unsupported message version");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    function test_MintAndForward_revertsIfZeroBurnMessageVersion() public {
        bytes memory burnMessage = _formatBurnMessageForRelay(
            0, // zero burn message version
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            HOOK_DATA
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        vm.expectRevert("Unsupported burn message version");
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    // Test that magic bytes can be set to 0 - currently no validation is implemented
    // so this test verifies the current behavior (should succeed)
    function test_MintAndForward_succeedsWithZeroMagicBytes() public {
        bytes memory hookWithZeroMagicBytes = abi.encodePacked(
            bytes24(0), // zero magic bytes - no validation implemented yet
            uint32(0),
            uint32(20),
            FORWARD_RECIPIENT
        );
        bytes memory burnMessage = _formatBurnMessageForRelay(
            BURN_VERSION,
            BURN_TOKEN,
            MINT_RECIPIENT,
            AMOUNT,
            MESSAGE_SENDER,
            MAX_FEE,
            FEE_EXECUTED,
            EXPIRATION_BLOCK,
            hookWithZeroMagicBytes
        );
        bytes memory message = _formatMessageForRelay(
            MESSAGE_VERSION,
            SOURCE_DOMAIN,
            DESTINATION_DOMAIN,
            SENDER,
            RECIPIENT,
            DESTINATION_CALLER,
            burnMessage
        );
        // Expect MintAndForward event
        vm.expectEmit(true, true, true, true);
        emit MintAndForward(
            FORWARD_RECIPIENT,
            address(CORE_DEPOSIT_WALLET),
            address(TOKEN),
            AMOUNT - FEE_EXECUTED
        );
        // Currently no magic bytes validation is implemented, so this should succeed
        forwarder.mintAndForward(message, VALID_SIGNATURE);
    }

    // Rescuable
}
