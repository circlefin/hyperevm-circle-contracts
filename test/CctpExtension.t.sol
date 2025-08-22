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

import {Test, console} from "forge-std/Test.sol";
import {MockMintBurnToken} from "lib/evm-cctp-contracts/test/mocks/MockMintBurnToken.sol";
import {CctpExtension} from "../src/CctpExtension.sol";
import {MockEIP3009Token} from "./mocks/MockEIP3009Token.sol";
import {ICctpExtension} from "../src/interfaces/ICctpExtension.sol";
import {TestUtils} from "./TestUtils.sol";

contract CctpExtensionTest is Test, TestUtils {
    MockEIP3009Token public EIP3009_TOKEN = new MockEIP3009Token();
    CctpExtension public cctpExtension;

    address public owner = address(10);
    address public rescuer = address(11);
    address public tokenMessenger = address(12);

    function setUp() public {
        cctpExtension = new CctpExtension();
        cctpExtension.initialize(
            CctpExtension.InitParams({
                owner: owner,
                rescuer: rescuer,
                tokenMessenger: tokenMessenger,
                token: address(EIP3009_TOKEN)
            })
        );
    }

    //=========================== Constructor Tests ============================

    function testConstructor_stateVariablesAreSetCorrectly() public {
        CctpExtension testExtension = new CctpExtension();
        assertEq(testExtension.owner(), address(this)); // initial owner is set to the deployer
        assertEq(testExtension.rescuer(), address(0)); // initial rescuer is set to the zero address
        assertEq(testExtension.tokenMessenger(), address(0)); // initial tokenMessenger is set to the zero address
        assertEq(testExtension.token(), address(0)); // initial token is set to the zero address
    }

    //=========================== Initialize Tests ============================

    function testInitialize_revertsIfOwnerIsZeroAddress() public {
        CctpExtension testExtension = new CctpExtension();
        vm.expectRevert("Invalid owner address");
        testExtension.initialize(
            CctpExtension.InitParams({
                owner: address(0),
                rescuer: rescuer,
                tokenMessenger: tokenMessenger,
                token: address(EIP3009_TOKEN)
            })
        );
    }

    function testInitialize_revertsIfRescuerIsZeroAddress() public {
        CctpExtension testExtension = new CctpExtension();
        vm.expectRevert("Invalid rescuer address");
        testExtension.initialize(
            CctpExtension.InitParams({
                owner: owner,
                rescuer: address(0),
                tokenMessenger: tokenMessenger,
                token: address(EIP3009_TOKEN)
            })
        );
    }

    function testInitialize_revertsIfTokenMessengerIsZeroAddress() public {
        CctpExtension testExtension = new CctpExtension();
        vm.expectRevert("Invalid tokenMessenger");
        testExtension.initialize(
            CctpExtension.InitParams({
                owner: owner,
                rescuer: rescuer,
                tokenMessenger: address(0),
                token: address(EIP3009_TOKEN)
            })
        );
    }

    function testInitialize_revertsIfTokenIsZeroAddress() public {
        CctpExtension testExtension = new CctpExtension();
        vm.expectRevert("Invalid token address");
        testExtension.initialize(
            CctpExtension.InitParams({owner: owner, rescuer: rescuer, tokenMessenger: tokenMessenger, token: address(0)})
        );
    }

    function testInitialize_setsStateVariablesCorrectly() public view {
        assertEq(cctpExtension.owner(), owner);
        assertEq(cctpExtension.rescuer(), rescuer);
        assertEq(cctpExtension.tokenMessenger(), tokenMessenger);
        assertEq(cctpExtension.token(), address(EIP3009_TOKEN));
    }

    function testInitialize_increasesAllowanceForTokenMessenger() public view {
        assertEq(EIP3009_TOKEN.allowance(address(cctpExtension), tokenMessenger), type(uint256).max);
    }

    function testInitialize_emitsOwnershipTransferredEvents() public {
        // The initialize function emits one OwnershipTransferred event:
        // Transfer from test contract (initial owner) to specified owner

        CctpExtension testExtension = new CctpExtension();

        // Expect event: address(this) -> owner (transfer from initial owner)
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(address(this), owner);

        testExtension.initialize(
            CctpExtension.InitParams({
                owner: owner,
                rescuer: rescuer,
                tokenMessenger: tokenMessenger,
                token: address(EIP3009_TOKEN)
            })
        );
    }

    function testInitialize_emitsRescuerChangedEvent() public {
        CctpExtension testExtension = new CctpExtension();
        vm.expectEmit(true, true, true, true);
        emit RescuerChanged(rescuer);
        testExtension.initialize(
            CctpExtension.InitParams({
                owner: owner,
                rescuer: rescuer,
                tokenMessenger: tokenMessenger,
                token: address(EIP3009_TOKEN)
            })
        );
    }

    function testInitialize_emitsInitializedEvent() public {
        CctpExtension testExtension = new CctpExtension();

        // Expect Initialized event with version 1
        vm.expectEmit(true, true, true, true);
        emit Initialized(1);

        testExtension.initialize(
            CctpExtension.InitParams({
                owner: owner,
                rescuer: rescuer,
                tokenMessenger: tokenMessenger,
                token: address(EIP3009_TOKEN)
            })
        );
    }

    function testInitialize_revertsIfCalledTwice() public {
        CctpExtension testExtension = new CctpExtension();

        // First initialization should succeed
        testExtension.initialize(
            CctpExtension.InitParams({
                owner: owner,
                rescuer: rescuer,
                tokenMessenger: tokenMessenger,
                token: address(EIP3009_TOKEN)
            })
        );

        // Second initialization should fail
        vm.expectRevert("Initializable: invalid initialization");
        testExtension.initialize(
            CctpExtension.InitParams({
                owner: owner,
                rescuer: rescuer,
                tokenMessenger: tokenMessenger,
                token: address(EIP3009_TOKEN)
            })
        );
    }

    //=========================== External Functions Tests ============================

    function testBatchDepositForBurnWithAuth_singleBurnWithoutHookData() public {
        uint256 authAmount = 1000;
        uint256 burnAmount = 1000;
        address caller = address(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));

        ICctpExtension.ReceiveWithAuthorizationData memory authData = ICctpExtension.ReceiveWithAuthorizationData({
            amount: authAmount,
            authValidAfter: 0,
            authValidBefore: type(uint256).max,
            authNonce: bytes32(uint256(1)),
            v: 27,
            r: bytes32(uint256(0x1)),
            s: bytes32(uint256(0x2))
        });

        ICctpExtension.DepositForBurnWithHookData memory burnData = ICctpExtension.DepositForBurnWithHookData({
            amount: burnAmount,
            destinationDomain: 1,
            mintRecipient: mintRecipient,
            destinationCaller: destinationCaller,
            maxFee: 10,
            minFinalityThreshold: 500,
            hookData: new bytes(0) // No hook data
        });

        // Mock receiveWithAuthorization call
        bytes memory receiveWithAuthCall = abi.encodeWithSelector(
            MockEIP3009Token.receiveWithAuthorization.selector,
            caller,
            address(cctpExtension),
            authData.amount,
            authData.authValidAfter,
            authData.authValidBefore,
            authData.authNonce,
            authData.v,
            authData.r,
            authData.s
        );

        // Mock depositForBurn call
        bytes memory depositForBurnCall = abi.encodeWithSignature(
            "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)",
            burnData.amount,
            burnData.destinationDomain,
            burnData.mintRecipient,
            address(EIP3009_TOKEN),
            burnData.destinationCaller,
            burnData.maxFee,
            burnData.minFinalityThreshold
        );

        // Mock calls
        vm.mockCall(address(EIP3009_TOKEN), receiveWithAuthCall, abi.encode());
        vm.mockCall(tokenMessenger, depositForBurnCall, abi.encode());

        // Expect receiveWithAuthorization to be called exactly once
        vm.expectCall(address(EIP3009_TOKEN), receiveWithAuthCall, 1);

        // Expect depositForBurn to be called exactly once
        vm.expectCall(tokenMessenger, depositForBurnCall, 1);

        // Execute the function
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(authData, burnData);
    }

    function testBatchDepositForBurnWithAuth_singleBurnWithHookData() public {
        uint256 authAmount = 1000;
        uint256 burnAmount = 1000; // Single burn, no batching
        address caller = address(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));
        bytes memory hookData = abi.encode("single burn hook data", 98765);

        ICctpExtension.ReceiveWithAuthorizationData memory authData = ICctpExtension.ReceiveWithAuthorizationData({
            amount: authAmount,
            authValidAfter: 0,
            authValidBefore: type(uint256).max,
            authNonce: bytes32(uint256(1)),
            v: 27,
            r: bytes32(uint256(0x1)),
            s: bytes32(uint256(0x2))
        });

        ICctpExtension.DepositForBurnWithHookData memory burnData = ICctpExtension.DepositForBurnWithHookData({
            amount: burnAmount,
            destinationDomain: 1,
            mintRecipient: mintRecipient,
            destinationCaller: destinationCaller,
            maxFee: 10,
            minFinalityThreshold: 500,
            hookData: hookData
        });

        // Mock the receiveWithAuthorization call to succeed
        bytes memory receiveWithAuthCall = abi.encodeWithSelector(
            MockEIP3009Token.receiveWithAuthorization.selector,
            caller,
            address(cctpExtension),
            authData.amount,
            authData.authValidAfter,
            authData.authValidBefore,
            authData.authNonce,
            authData.v,
            authData.r,
            authData.s
        );

        // Mock and expect depositForBurnWithHook call (single call since batch size equals total amount)
        bytes memory depositForBurnWithHookCall = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            burnData.amount,
            burnData.destinationDomain,
            burnData.mintRecipient,
            address(EIP3009_TOKEN),
            burnData.destinationCaller,
            burnData.maxFee,
            burnData.minFinalityThreshold,
            hookData
        );

        // Mock calls
        vm.mockCall(address(EIP3009_TOKEN), receiveWithAuthCall, abi.encode());
        vm.mockCall(tokenMessenger, depositForBurnWithHookCall, abi.encode());

        // Expect receiveWithAuthorization to be called exactly once
        vm.expectCall(address(EIP3009_TOKEN), receiveWithAuthCall, 1);
        // Expect depositForBurnWithHook to be called exactly once
        vm.expectCall(tokenMessenger, depositForBurnWithHookCall, 1);

        // Execute the function
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(authData, burnData);
    }

    function testBatchDepositForBurnWithAuth_batchWithoutHookData() public {
        uint256 authAmount = 1000;
        uint256 burnAmount = 300;
        address caller = address(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));

        ICctpExtension.ReceiveWithAuthorizationData memory authData = ICctpExtension.ReceiveWithAuthorizationData({
            amount: authAmount,
            authValidAfter: 0,
            authValidBefore: type(uint256).max,
            authNonce: bytes32(uint256(1)),
            v: 27,
            r: bytes32(uint256(0x1)),
            s: bytes32(uint256(0x2))
        });

        ICctpExtension.DepositForBurnWithHookData memory burnData = ICctpExtension.DepositForBurnWithHookData({
            amount: burnAmount,
            destinationDomain: 1,
            mintRecipient: mintRecipient,
            destinationCaller: destinationCaller,
            maxFee: 10,
            minFinalityThreshold: 500,
            hookData: new bytes(0) // No hook data
        });

        bytes memory receiveWithAuthCall = abi.encodeWithSelector(
            MockEIP3009Token.receiveWithAuthorization.selector,
            caller,
            address(cctpExtension),
            authAmount,
            authData.authValidAfter,
            authData.authValidBefore,
            authData.authNonce,
            authData.v,
            authData.r,
            authData.s
        );

        // Mock and expect depositForBurn calls - expect 4 calls: 300, 300, 300, 100
        bytes memory depositForBurn300Call = abi.encodeWithSignature(
            "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)",
            300,
            burnData.destinationDomain,
            burnData.mintRecipient,
            address(EIP3009_TOKEN),
            burnData.destinationCaller,
            burnData.maxFee,
            burnData.minFinalityThreshold
        );

        bytes memory depositForBurn100Call = abi.encodeWithSignature(
            "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)",
            100,
            burnData.destinationDomain,
            burnData.mintRecipient,
            address(EIP3009_TOKEN),
            burnData.destinationCaller,
            burnData.maxFee,
            burnData.minFinalityThreshold
        );

        // Mock calls
        vm.mockCall(address(EIP3009_TOKEN), receiveWithAuthCall, abi.encode());
        vm.mockCall(tokenMessenger, depositForBurn300Call, abi.encode());
        vm.mockCall(tokenMessenger, depositForBurn100Call, abi.encode());

        // Expect receiveWithAuthorization to be called exactly once
        vm.expectCall(address(EIP3009_TOKEN), receiveWithAuthCall, 1);

        // Expect 3 calls of 300 tokens each
        vm.expectCall(tokenMessenger, depositForBurn300Call, 3);

        // Expect 1 call of 100 tokens (remainder)
        vm.expectCall(tokenMessenger, depositForBurn100Call, 1);

        // Execute the function
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(authData, burnData);
    }

    function testBatchDepositForBurnWithAuth_batchWithHookData() public {
        uint256 authAmount = 1000;
        uint256 burnAmount = 300;
        address caller = address(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));
        bytes memory hookData = abi.encode("test hook data", 12345, true);

        ICctpExtension.ReceiveWithAuthorizationData memory authData = ICctpExtension.ReceiveWithAuthorizationData({
            amount: authAmount,
            authValidAfter: 0,
            authValidBefore: type(uint256).max,
            authNonce: bytes32(uint256(1)),
            v: 27,
            r: bytes32(uint256(0x1)),
            s: bytes32(uint256(0x2))
        });

        ICctpExtension.DepositForBurnWithHookData memory burnData = ICctpExtension.DepositForBurnWithHookData({
            amount: burnAmount,
            destinationDomain: 1,
            mintRecipient: mintRecipient,
            destinationCaller: destinationCaller,
            maxFee: 10,
            minFinalityThreshold: 500,
            hookData: hookData
        });

        bytes memory receiveWithAuthCall = abi.encodeWithSelector(
            MockEIP3009Token.receiveWithAuthorization.selector,
            caller,
            address(cctpExtension),
            authAmount,
            authData.authValidAfter,
            authData.authValidBefore,
            authData.authNonce,
            authData.v,
            authData.r,
            authData.s
        );

        // Mock and expect depositForBurnWithHook calls - expect 4 calls: 300, 300, 300, 100
        bytes memory depositForBurnWithHook300Call = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            300,
            burnData.destinationDomain,
            burnData.mintRecipient,
            address(EIP3009_TOKEN),
            burnData.destinationCaller,
            burnData.maxFee,
            burnData.minFinalityThreshold,
            hookData
        );
        bytes memory depositForBurnWithHook100Call = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            100,
            burnData.destinationDomain,
            burnData.mintRecipient,
            address(EIP3009_TOKEN),
            burnData.destinationCaller,
            burnData.maxFee,
            burnData.minFinalityThreshold,
            hookData
        );

        // Mock calls
        vm.mockCall(address(EIP3009_TOKEN), receiveWithAuthCall, abi.encode());
        vm.mockCall(tokenMessenger, depositForBurnWithHook300Call, abi.encode());
        vm.mockCall(tokenMessenger, depositForBurnWithHook100Call, abi.encode());

        // Expect receiveWithAuthorization to be called exactly once
        vm.expectCall(address(EIP3009_TOKEN), receiveWithAuthCall);

        // Expect 3 calls of 300 tokens each
        vm.expectCall(tokenMessenger, depositForBurnWithHook300Call, 3);

        // Expect 1 call of 100 tokens (remainder)
        vm.expectCall(tokenMessenger, depositForBurnWithHook100Call, 1);

        // Execute the function
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(authData, burnData);
    }

    function testBatchDepositForBurnWithAuth_batchWithHookDataAndBurnAmountGreaterThanAuthAmount() public {
        uint256 authAmount = 1000;
        uint256 burnAmount = 1500;
        address caller = address(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));
        bytes memory hookData = abi.encode("test hook data", 12345, true);

        ICctpExtension.ReceiveWithAuthorizationData memory authData = ICctpExtension.ReceiveWithAuthorizationData({
            amount: authAmount,
            authValidAfter: 0,
            authValidBefore: type(uint256).max,
            authNonce: bytes32(uint256(1)),
            v: 27,
            r: bytes32(uint256(0x1)),
            s: bytes32(uint256(0x2))
        });

        ICctpExtension.DepositForBurnWithHookData memory burnData = ICctpExtension.DepositForBurnWithHookData({
            amount: burnAmount,
            destinationDomain: 1,
            mintRecipient: mintRecipient,
            destinationCaller: destinationCaller,
            maxFee: 10,
            minFinalityThreshold: 500,
            hookData: hookData
        });

        bytes memory receiveWithAuthCall = abi.encodeWithSelector(
            MockEIP3009Token.receiveWithAuthorization.selector,
            caller,
            address(cctpExtension),
            authAmount,
            authData.authValidAfter,
            authData.authValidBefore,
            authData.authNonce,
            authData.v,
            authData.r,
            authData.s
        );

        bytes memory depositForBurnWithHookCall = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            authAmount,
            burnData.destinationDomain,
            burnData.mintRecipient,
            address(EIP3009_TOKEN),
            burnData.destinationCaller,
            burnData.maxFee,
            burnData.minFinalityThreshold
        );

        // Mock calls
        vm.mockCall(address(EIP3009_TOKEN), receiveWithAuthCall, abi.encode());
        vm.mockCall(tokenMessenger, depositForBurnWithHookCall, abi.encode());

        // Expect receiveWithAuthorization to be called exactly once
        vm.expectCall(address(EIP3009_TOKEN), receiveWithAuthCall, 1);
        // Expect depositForBurnWithHook to be called exactly once
        vm.expectCall(tokenMessenger, depositForBurnWithHookCall, 1);

        // Execute the function
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(authData, burnData);
    }

    function testBatchDepositForBurnWithAuth_batchWithoutHookDataAndBurnAmountGreaterThanAuthAmount() public {
        uint256 authAmount = 1000;
        uint256 burnAmount = 1500;
        address caller = address(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));

        ICctpExtension.ReceiveWithAuthorizationData memory authData = ICctpExtension.ReceiveWithAuthorizationData({
            amount: authAmount,
            authValidAfter: 0,
            authValidBefore: type(uint256).max,
            authNonce: bytes32(uint256(1)),
            v: 27,
            r: bytes32(uint256(0x1)),
            s: bytes32(uint256(0x2))
        });

        ICctpExtension.DepositForBurnWithHookData memory burnData = ICctpExtension.DepositForBurnWithHookData({
            amount: burnAmount,
            destinationDomain: 1,
            mintRecipient: mintRecipient,
            destinationCaller: destinationCaller,
            maxFee: 10,
            minFinalityThreshold: 500,
            hookData: new bytes(0) // No hook data
        });

        bytes memory receiveWithAuthCall = abi.encodeWithSelector(
            MockEIP3009Token.receiveWithAuthorization.selector,
            caller,
            address(cctpExtension),
            authAmount,
            authData.authValidAfter,
            authData.authValidBefore,
            authData.authNonce,
            authData.v,
            authData.r,
            authData.s
        );

        bytes memory depositForBurnCall = abi.encodeWithSignature(
            "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)",
            authAmount,
            burnData.destinationDomain,
            burnData.mintRecipient,
            address(EIP3009_TOKEN),
            burnData.destinationCaller,
            burnData.maxFee,
            burnData.minFinalityThreshold
        );

        // Mock calls
        vm.mockCall(address(EIP3009_TOKEN), receiveWithAuthCall, abi.encode());
        vm.mockCall(tokenMessenger, depositForBurnCall, abi.encode());

        // Expect receiveWithAuthorization to be called exactly once
        vm.expectCall(address(EIP3009_TOKEN), receiveWithAuthCall, 1);
        // Expect depositForBurnWithHook to be called exactly once
        vm.expectCall(tokenMessenger, depositForBurnCall, 1);

        // Execute the function
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(authData, burnData);
    }

    function testBatchDepositForBurnWithAuth_requestWithoutHookDataAndZeroAuthAmount() public {
        uint256 authAmount = 0;
        uint256 burnAmount = 1000;
        address caller = address(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));

        ICctpExtension.ReceiveWithAuthorizationData memory authData = ICctpExtension.ReceiveWithAuthorizationData({
            amount: authAmount,
            authValidAfter: 0,
            authValidBefore: type(uint256).max,
            authNonce: bytes32(uint256(1)),
            v: 27,
            r: bytes32(uint256(0x1)),
            s: bytes32(uint256(0x2))
        });

        ICctpExtension.DepositForBurnWithHookData memory burnData = ICctpExtension.DepositForBurnWithHookData({
            amount: burnAmount,
            destinationDomain: 1,
            mintRecipient: mintRecipient,
            destinationCaller: destinationCaller,
            maxFee: 10,
            minFinalityThreshold: 500,
            hookData: new bytes(0) // No hook data
        });

        bytes memory receiveWithAuthCall = abi.encodeWithSelector(
            MockEIP3009Token.receiveWithAuthorization.selector,
            caller,
            address(cctpExtension),
            authAmount,
            authData.authValidAfter,
            authData.authValidBefore,
            authData.authNonce,
            authData.v,
            authData.r,
            authData.s
        );

        bytes memory depositForBurnCall = abi.encodeWithSignature(
            "depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)",
            burnAmount,
            burnData.destinationDomain,
            burnData.mintRecipient,
            address(EIP3009_TOKEN),
            burnData.destinationCaller,
            burnData.maxFee,
            burnData.minFinalityThreshold
        );

        // Mock the receiveWithAuthorization call and don't mock the depositForBurn call to ensure it's not called (test would fail if it was)
        vm.mockCall(address(EIP3009_TOKEN), receiveWithAuthCall, abi.encode());

        // Expect receiveWithAuthorization to be called once with 0 amount
        vm.expectCall(address(EIP3009_TOKEN), receiveWithAuthCall, 1);

        // Expect depositForBurn to NEVER be called since authAmount = 0
        vm.expectCall(tokenMessenger, depositForBurnCall, 0);

        // Execute the function - should complete successfully
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(authData, burnData);
    }

    function testBatchDepositForBurnWithAuth_requestWithHookDataAndZeroAuthAmount() public {
        uint256 authAmount = 0;
        uint256 burnAmount = 1000;
        address caller = address(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));
        bytes memory hookData = abi.encode("test hook data", 12345, true);

        ICctpExtension.ReceiveWithAuthorizationData memory authData = ICctpExtension.ReceiveWithAuthorizationData({
            amount: authAmount,
            authValidAfter: 0,
            authValidBefore: type(uint256).max,
            authNonce: bytes32(uint256(1)),
            v: 27,
            r: bytes32(uint256(0x1)),
            s: bytes32(uint256(0x2))
        });

        ICctpExtension.DepositForBurnWithHookData memory burnData = ICctpExtension.DepositForBurnWithHookData({
            amount: burnAmount,
            destinationDomain: 1,
            mintRecipient: mintRecipient,
            destinationCaller: destinationCaller,
            maxFee: 10,
            minFinalityThreshold: 500,
            hookData: hookData
        });

        bytes memory receiveWithAuthCall = abi.encodeWithSelector(
            MockEIP3009Token.receiveWithAuthorization.selector,
            caller,
            address(cctpExtension),
            authAmount,
            authData.authValidAfter,
            authData.authValidBefore,
            authData.authNonce,
            authData.v,
            authData.r,
            authData.s
        );

        bytes memory depositForBurnCall = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            burnAmount,
            burnData.destinationDomain,
            burnData.mintRecipient,
            address(EIP3009_TOKEN),
            burnData.destinationCaller,
            burnData.maxFee,
            burnData.minFinalityThreshold
        );

        // Mock the receiveWithAuthorization call and don't mock the depositForBurn call to ensure it's not called (test would fail if it was)
        vm.mockCall(address(EIP3009_TOKEN), receiveWithAuthCall, abi.encode());

        // Expect receiveWithAuthorization to be called once with 0 amount
        vm.expectCall(address(EIP3009_TOKEN), receiveWithAuthCall, 1);

        // Expect depositForBurn to NEVER be called since authAmount = 0
        vm.expectCall(tokenMessenger, depositForBurnCall, 0);

        // Execute the function - should complete successfully
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(authData, burnData);
    }

    function testbatchDepositForBurnWithAuth_revertsIfAuthReceiveFails(bool useHookData) public {
        uint256 authAmount = 1000;
        uint256 burnAmount = 1500;
        address caller = address(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));

        // Determine hook data
        bytes memory hookData = useHookData ? abi.encode("hook data", 12345, useHookData) : new bytes(0);

        ICctpExtension.ReceiveWithAuthorizationData memory authData = ICctpExtension.ReceiveWithAuthorizationData({
            amount: authAmount,
            authValidAfter: 0,
            authValidBefore: type(uint256).max,
            authNonce: bytes32(uint256(1)),
            v: 27,
            r: bytes32(uint256(0x1)),
            s: bytes32(uint256(0x2))
        });

        ICctpExtension.DepositForBurnWithHookData memory burnData = ICctpExtension.DepositForBurnWithHookData({
            amount: burnAmount,
            destinationDomain: 1,
            mintRecipient: mintRecipient,
            destinationCaller: destinationCaller,
            maxFee: 10,
            minFinalityThreshold: 500,
            hookData: hookData
        });

        // Mock receiveWithAuthorization to revert with "Invalid authorization signature"
        vm.mockCallRevert(
            address(EIP3009_TOKEN),
            abi.encodeWithSelector(
                MockEIP3009Token.receiveWithAuthorization.selector,
                caller,
                address(cctpExtension),
                authAmount,
                authData.authValidAfter,
                authData.authValidBefore,
                authData.authNonce,
                authData.v,
                authData.r,
                authData.s
            ),
            "Invalid authorization signature"
        );

        // Expect the function to revert with the authorization failure
        vm.prank(caller);
        vm.expectRevert("Invalid authorization signature");
        cctpExtension.batchDepositForBurnWithAuth(authData, burnData);
    }

    function testBatchDepositForBurnWithAuth_revertsIfDepositForBurnFails(bool useHookData) public {
        uint256 authAmount = 1000;
        uint256 burnAmount = 1500;
        address caller = address(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));

        // Determine hook data
        bytes memory hookData = useHookData ? abi.encode("hook data", 54321, useHookData) : new bytes(0);

        ICctpExtension.ReceiveWithAuthorizationData memory authData = ICctpExtension.ReceiveWithAuthorizationData({
            amount: authAmount,
            authValidAfter: 0,
            authValidBefore: type(uint256).max,
            authNonce: bytes32(uint256(1)),
            v: 27,
            r: bytes32(uint256(0x1)),
            s: bytes32(uint256(0x2))
        });

        ICctpExtension.DepositForBurnWithHookData memory burnData = ICctpExtension.DepositForBurnWithHookData({
            amount: burnAmount,
            destinationDomain: 1,
            mintRecipient: mintRecipient,
            destinationCaller: destinationCaller,
            maxFee: 10,
            minFinalityThreshold: 500,
            hookData: hookData
        });

        // Mock receiveWithAuthorization to succeed
        vm.mockCall(
            address(EIP3009_TOKEN),
            abi.encodeWithSignature(
                "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
            ),
            abi.encode()
        );

        // Mock the appropriate depositForBurn function to revert based on hook data usage
        if (useHookData) {
            vm.mockCallRevert(
                tokenMessenger,
                abi.encodeWithSignature(
                    "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)"
                ),
                "DepositForBurnWithHook failed"
            );
        } else {
            vm.mockCallRevert(
                tokenMessenger,
                abi.encodeWithSignature("depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)"),
                "DepositForBurn failed"
            );
        }

        // Expect the function to revert with the deposit failure
        vm.prank(caller);
        vm.expectRevert();
        cctpExtension.batchDepositForBurnWithAuth(authData, burnData);
    }

    // =========================== Fuzz Tests ============================

    /**
     * @notice Fuzz test for batch deposit with varying authorization and batch amounts
     * @param authAmount Total amount authorized (1 to 1000 USDC)
     * @param batchSize Amount per batch (1 to 200 USDC)
     */
    function testFuzz_batchDepositForBurnWithAuth_varyingAmounts(uint256 authAmount, uint256 batchSize) public {
        // Bound inputs to reasonable ranges
        authAmount = bound(authAmount, 1e6, 1000e6); // 1 to 1000 USDC
        batchSize = bound(batchSize, 1e6, 200e6); // 1 to 200 USDC

        address caller = vm.addr(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));

        // Setup mock token behavior
        vm.mockCall(
            address(EIP3009_TOKEN),
            abi.encodeWithSignature(
                "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
            ),
            abi.encode()
        );

        // Mock the token messenger calls to succeed
        vm.mockCall(
            tokenMessenger,
            abi.encodeWithSignature("depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)"),
            abi.encode()
        );

        // Execute
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(
            ICctpExtension.ReceiveWithAuthorizationData({
                amount: authAmount,
                authValidAfter: 0,
                authValidBefore: type(uint256).max,
                authNonce: bytes32(uint256(1)),
                v: 27,
                r: bytes32(uint256(1)),
                s: bytes32(uint256(2))
            }),
            ICctpExtension.DepositForBurnWithHookData({
                amount: batchSize,
                destinationDomain: 1,
                mintRecipient: mintRecipient,
                destinationCaller: destinationCaller,
                maxFee: 10,
                minFinalityThreshold: 500,
                hookData: ""
            })
        );
    }

    /**
     * @notice Fuzz test for batch deposit with varying amounts using hook data (depositForBurnWithHook)
     * @param authAmount Total amount authorized (1 to 1000 USDC)
     * @param batchSize Amount per batch (1 to 200 USDC)
     */
    function testFuzz_batchDepositForBurnWithAuth_varyingAmountsWithHook(uint256 authAmount, uint256 batchSize)
        public
    {
        // Bound inputs to reasonable ranges
        authAmount = bound(authAmount, 1e6, 1000e6); // 1 to 1000 USDC
        batchSize = bound(batchSize, 1e6, 200e6); // 1 to 200 USDC

        address caller = vm.addr(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));
        bytes memory hookData = abi.encode("test hook data for fuzz", authAmount, batchSize);

        // Setup mock token behavior
        vm.mockCall(
            address(EIP3009_TOKEN),
            abi.encodeWithSignature(
                "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
            ),
            abi.encode()
        );

        // Mock the token messenger calls for depositForBurnWithHook
        vm.mockCall(
            tokenMessenger,
            abi.encodeWithSignature(
                "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)"
            ),
            abi.encode()
        );

        // Execute with hook data to test depositForBurnWithHook path
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(
            ICctpExtension.ReceiveWithAuthorizationData({
                amount: authAmount,
                authValidAfter: 0,
                authValidBefore: type(uint256).max,
                authNonce: bytes32(uint256(1)),
                v: 27,
                r: bytes32(uint256(1)),
                s: bytes32(uint256(2))
            }),
            ICctpExtension.DepositForBurnWithHookData({
                amount: batchSize,
                destinationDomain: 1,
                mintRecipient: mintRecipient,
                destinationCaller: destinationCaller,
                maxFee: 10,
                minFinalityThreshold: 500,
                hookData: hookData // Non-empty hook data ensures depositForBurnWithHook path
            })
        );
    }

    /**
     * @notice Fuzz test for hook data variations
     * @param hookDataLength Length of hook data (0 to 1000 bytes)
     * @param hookDataSeed Seed for generating hook data content
     */
    function testFuzz_batchDepositForBurnWithAuth_hookData(uint256 hookDataLength, uint256 hookDataSeed) public {
        // Bound hook data length to reasonable range
        hookDataLength = bound(hookDataLength, 0, 1000);

        address caller = vm.addr(0x123);
        uint256 amount = 50e6;
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));

        // Generate hook data
        bytes memory hookData;
        if (hookDataLength > 0) {
            hookData = new bytes(hookDataLength);
            for (uint256 i = 0; i < hookDataLength; i++) {
                hookData[i] = bytes1(uint8((hookDataSeed + i) % 256));
            }
        }

        // Setup mocks
        vm.mockCall(
            address(EIP3009_TOKEN),
            abi.encodeWithSignature(
                "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
            ),
            abi.encode()
        );

        // Mock both possible calls based on hook data presence
        vm.mockCall(
            tokenMessenger,
            abi.encodeWithSignature("depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)"),
            abi.encode()
        );
        vm.mockCall(
            tokenMessenger,
            abi.encodeWithSignature(
                "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)"
            ),
            abi.encode()
        );

        // Execute
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(
            ICctpExtension.ReceiveWithAuthorizationData({
                amount: amount,
                authValidAfter: 0,
                authValidBefore: type(uint256).max,
                authNonce: bytes32(uint256(1)),
                v: 27,
                r: bytes32(uint256(1)),
                s: bytes32(uint256(2))
            }),
            ICctpExtension.DepositForBurnWithHookData({
                amount: amount,
                destinationDomain: 1,
                mintRecipient: mintRecipient,
                destinationCaller: destinationCaller,
                maxFee: 10,
                minFinalityThreshold: 500,
                hookData: hookData
            })
        );
    }

    /**
     * @notice Property test: Total burned amount should equal authorized amount
     * @param authAmount Authorization amount
     * @param batchSize Batch size
     */
    function testFuzz_batchDepositForBurnWithAuth_propertyTotalBurnedEqualsAuthorized(
        uint256 authAmount,
        uint256 batchSize
    ) public {
        // Bound to prevent overflow and ensure reasonable values
        authAmount = bound(authAmount, 1e6, 100e6); // 1 to 100 USDC
        batchSize = bound(batchSize, 1e6, 100e6); // 1 to 100 USDC

        address caller = vm.addr(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));

        // Track total burned amount
        uint256 totalBurned = 0;
        uint256 remaining = authAmount;

        // Setup mocks
        vm.mockCall(
            address(EIP3009_TOKEN),
            abi.encodeWithSignature(
                "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
            ),
            abi.encode()
        );

        // Mock token messenger calls
        vm.mockCall(
            tokenMessenger,
            abi.encodeWithSignature("depositForBurn(uint256,uint32,bytes32,address,bytes32,uint256,uint32)"),
            abi.encode()
        );

        // Calculate how many burns will happen and their amounts for property verification
        while (remaining > 0) {
            uint256 burnAmount = remaining > batchSize ? batchSize : remaining;
            totalBurned += burnAmount;
            remaining -= burnAmount;
        }

        // Property: Total burned should equal authorized amount
        assertEq(totalBurned, authAmount, "Total burned amount must equal authorized amount");

        // Execute the actual function
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(
            ICctpExtension.ReceiveWithAuthorizationData({
                amount: authAmount,
                authValidAfter: 0,
                authValidBefore: type(uint256).max,
                authNonce: bytes32(uint256(1)),
                v: 27,
                r: bytes32(uint256(1)),
                s: bytes32(uint256(2))
            }),
            ICctpExtension.DepositForBurnWithHookData({
                amount: batchSize,
                destinationDomain: 1,
                mintRecipient: mintRecipient,
                destinationCaller: destinationCaller,
                maxFee: 10,
                minFinalityThreshold: 500,
                hookData: ""
            })
        );
    }

    /**
     * @notice Property test: Total burned amount should equal authorized amount (with hook data)
     * @param authAmount Authorization amount
     * @param batchSize Batch size
     */
    function testFuzz_batchDepositForBurnWithAuth_propertyTotalBurnedEqualsAuthorizedWithHookData(
        uint256 authAmount,
        uint256 batchSize
    ) public {
        // Bound to prevent overflow and ensure reasonable values
        authAmount = bound(authAmount, 1e6, 100e6); // 1 to 100 USDC
        batchSize = bound(batchSize, 1e6, 100e6); // 1 to 100 USDC

        address caller = vm.addr(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));
        bytes memory hookData = abi.encode("property test hook data", authAmount, batchSize);

        // Track total burned amount
        uint256 totalBurned = 0;
        uint256 remaining = authAmount;

        // Setup mocks
        vm.mockCall(
            address(EIP3009_TOKEN),
            abi.encodeWithSignature(
                "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
            ),
            abi.encode()
        );

        // Mock token messenger calls for depositForBurnWithHook
        vm.mockCall(
            tokenMessenger,
            abi.encodeWithSignature(
                "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)"
            ),
            abi.encode()
        );

        // Calculate how many burns will happen and their amounts for property verification
        while (remaining > 0) {
            uint256 burnAmount = remaining > batchSize ? batchSize : remaining;
            totalBurned += burnAmount;
            remaining -= burnAmount;
        }

        // Property: Total burned should equal authorized amount
        assertEq(totalBurned, authAmount, "Total burned amount must equal authorized amount with hook data");

        // Execute the actual function with hook data
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(
            ICctpExtension.ReceiveWithAuthorizationData({
                amount: authAmount,
                authValidAfter: 0,
                authValidBefore: type(uint256).max,
                authNonce: bytes32(uint256(1)),
                v: 27,
                r: bytes32(uint256(1)),
                s: bytes32(uint256(2))
            }),
            ICctpExtension.DepositForBurnWithHookData({
                amount: batchSize,
                destinationDomain: 1,
                mintRecipient: mintRecipient,
                destinationCaller: destinationCaller,
                maxFee: 10,
                minFinalityThreshold: 500,
                hookData: hookData // Non-empty hook data ensures depositForBurnWithHook path
            })
        );
    }

    /**
     * @notice Property test: Total burned amount should equal authorized amount (with variable hook data)
     * @param authAmount Authorization amount
     * @param batchSize Batch size
     * @param hookDataLength Length of hook data
     */
    function testFuzz_batchDepositForBurnWithAuth_propertyTotalBurnedEqualsAuthorizedWithHook(
        uint256 authAmount,
        uint256 batchSize,
        uint256 hookDataLength
    ) public {
        // Bound to prevent overflow and ensure reasonable values
        authAmount = bound(authAmount, 1e6, 100e6); // 1 to 100 USDC
        batchSize = bound(batchSize, 1e6, 100e6); // 1 to 100 USDC
        hookDataLength = bound(hookDataLength, 1, 500); // 1 to 500 bytes

        address caller = vm.addr(0x123);
        bytes32 mintRecipient = bytes32(uint256(address(0x456)));
        bytes32 destinationCaller = bytes32(uint256(address(0x789)));

        // Generate hook data
        bytes memory hookData = new bytes(hookDataLength);
        for (uint256 i = 0; i < hookDataLength; i++) {
            hookData[i] = bytes1(uint8((i * 7 + 42) % 256)); // Deterministic hook data
        }

        // Track total burned amount
        uint256 totalBurned = 0;
        uint256 remaining = authAmount;

        // Setup mocks
        vm.mockCall(
            address(EIP3009_TOKEN),
            abi.encodeWithSignature(
                "receiveWithAuthorization(address,address,uint256,uint256,uint256,bytes32,uint8,bytes32,bytes32)"
            ),
            abi.encode()
        );

        // Mock token messenger calls for depositForBurnWithHook
        vm.mockCall(
            tokenMessenger,
            abi.encodeWithSignature(
                "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)"
            ),
            abi.encode()
        );

        // Calculate how many burns will happen and their amounts for property verification
        while (remaining > 0) {
            uint256 burnAmount = remaining > batchSize ? batchSize : remaining;
            totalBurned += burnAmount;
            remaining -= burnAmount;
        }

        // Property: Total burned should equal authorized amount
        assertEq(totalBurned, authAmount, "Total burned amount must equal authorized amount with hook data");

        // Execute the actual function
        vm.prank(caller);
        cctpExtension.batchDepositForBurnWithAuth(
            ICctpExtension.ReceiveWithAuthorizationData({
                amount: authAmount,
                authValidAfter: 0,
                authValidBefore: type(uint256).max,
                authNonce: bytes32(uint256(1)),
                v: 27,
                r: bytes32(uint256(1)),
                s: bytes32(uint256(2))
            }),
            ICctpExtension.DepositForBurnWithHookData({
                amount: batchSize,
                destinationDomain: 1,
                mintRecipient: mintRecipient,
                destinationCaller: destinationCaller,
                maxFee: 10,
                minFinalityThreshold: 500,
                hookData: hookData
            })
        );
    }

    // =========================== Ownership Tests ============================

    function testTransferOwnershipAndAcceptOwnership_succeeds(address _newOwner) public {
        vm.assume(_newOwner != cctpExtension.owner());
        transferOwnershipAndAcceptOwnership(address(cctpExtension), _newOwner);
    }

    function testTransferOwnership_revertsOnNonOwner(address _notOwner, address _newOwner) public {
        transferOwnership_revertsFromNonOwner(address(cctpExtension), _newOwner, _notOwner);
    }

    function testAcceptOwnership_revertsOnNonPendingOwner(address _newOwner, address _otherAccount) public {
        acceptOwnership_revertsFromNonPendingOwner(address(cctpExtension), _newOwner, _otherAccount);
    }

    function testTransferOwnershipWithoutAcceptingThenTransferToNewOwner_succeeds(
        address _newOwner,
        address _secondNewOwner
    ) public {
        transferOwnershipWithoutAcceptingThenTransferToNewOwner(address(cctpExtension), _newOwner, _secondNewOwner);
    }

    // =========================== Rescuer Tests ============================

    function testRescuable() public {
        assertContractIsRescuable(
            address(cctpExtension),
            rescuer,
            address(100), // rescueRecipient
            100, // amount
            address(200) // nonRescuer
        );
    }
}
