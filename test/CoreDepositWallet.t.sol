/*
 * Copyright (c) 2025, Circle Internet Financial Limited.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
pragma solidity 0.7.6;
pragma abicoder v2;

import {CoreDepositWallet} from "../src/CoreDepositWallet.sol";
import {MockMintBurnToken} from "lib/evm-cctp-contracts/test/mocks/MockMintBurnToken.sol";
import {MockDepositableToken} from "./mocks/MockDepositableToken.sol";
import {MockEIP3009Token} from "./mocks/MockEIP3009Token.sol";
import {AdminUpgradableProxy} from "@evm-cctp-contracts/proxy/AdminUpgradableProxy.sol";
import {Test} from "forge-std/Test.sol";
import {TestUtils} from "./TestUtils.sol";
import {DeployScriptTestUtils} from "./DeployScriptTestUtils.s.sol";
import {MockCoreDepositWalletV2} from "./mocks/MockCoreDepositWalletV2.sol";
import {MockCoreWriter} from "./mocks/MockCoreWriter.sol";
import {MockCoreUserExistsPrecompile} from "./mocks/MockCoreUserExistsPrecompile.sol";
import {ICoreWriter} from "../src/interfaces/ICoreWriter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

contract CoreDepositWalletTest is TestUtils, DeployScriptTestUtils {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Withdraw(address indexed to, uint256 value);

    event SendRawAction(address indexed user, bytes data);

    event SendAsset(address indexed coreRecipient, uint64 coreAmount);

    event NewCoreAccountFeeUpdated(uint64 previousFee, uint64 newFee);

    event NewCoreAccountFeeApplied(
        address indexed coreRecipient,
        uint64 newCoreAccountFee,
        uint256 evmDepositAmount,
        uint64 coreSentAmount
    );

    address public newTokenSystemAddress = address(11);
    address private constant CORE_USER_EXISTS_ADDRESS =
        0x0000000000000000000000000000000000000810;
    address private constant CORE_WRITER_ADDRESS =
        0x3333333333333333333333333333333333333333;

    uint64 private constant DEFAULT_NEW_CORE_ACCOUNT_FEE = 100000000; // 1 USDC (8 decimals)
    uint256 private constant CORE_SCALING_FACTOR = 100; // 6 decimals -> 8 decimals

    function setUp() public {
        _deployCreate2Factory();
        _deployMockCoreWriter();
        _deployCoreDepositWallet();
        _deployMockCoreUserExistsPrecompile();
    }

    function _deployMockCoreWriter() internal {
        // Deploy MockCoreWriter at the hardcoded CoreWriter address
        address coreWriterAddress = 0x3333333333333333333333333333333333333333;
        vm.etch(coreWriterAddress, type(MockCoreWriter).runtimeCode);
    }

    function _deployMockCoreUserExistsPrecompile() internal {
        // Deploy a simple contract that always returns true (user exists)
        vm.etch(
            CORE_USER_EXISTS_ADDRESS,
            type(MockCoreUserExistsPrecompile).runtimeCode
        );
    }

    // Helper functions
    function _buildCoreWriterAction(
        address sender,
        uint256 amount
    ) internal pure returns (bytes memory data) {
        // Scale from 6 decimals (HyperEVM) to 8 decimals (HyperCore) to match contract
        uint256 scaledAmount = amount * 100;
        bytes memory encodedAction = abi.encode(
            sender, // recipient
            address(0), // subAccount
            type(uint32).max, // SOURCE_SPOT_DEX
            uint32(0), // DESTINATION_PERP_DEX
            uint64(0), // TOKEN_INDEX
            uint64(scaledAmount) // scaled amount as uint64
        );
        data = new bytes(4 + encodedAction.length);
        data[0] = 0x01;
        data[1] = 0x00;
        data[2] = 0x00;
        data[3] = 0x0D;
        for (uint256 i = 0; i < encodedAction.length; i++) {
            data[4 + i] = encodedAction[i];
        }
        return data;
    }

    function _setupTokenMintAndApprove(
        address account,
        uint256 amount
    ) internal {
        // Mint tokens to the account
        MockDepositableToken(TOKEN).mint(account, amount);
        vm.prank(account);
        MockDepositableToken(TOKEN).approve(address(coreDepositWallet), amount);
    }

    function _mockCoreUserExists(address user, bool exists) internal {
        // Mock the CoreUserExistsPrecompile contract to return the desired exists value
        vm.mockCall(
            CORE_USER_EXISTS_ADDRESS,
            abi.encode(user),
            abi.encode(exists)
        );
    }

    // Helper to bound deposit and fee together with valid relationship
    function _boundDepositAndFee(
        uint256 evmAmountIn,
        uint64 feeIn
    ) internal pure returns (uint256 evmAmount, uint64 fee) {
        evmAmount = bound(
            evmAmountIn,
            1,
            type(uint64).max / CORE_SCALING_FACTOR
        );
        uint64 feeMax = uint64(evmAmount * CORE_SCALING_FACTOR - 1);
        fee = uint64(bound(uint256(feeIn), 1, feeMax));
    }

    function _scaleToCore(uint256 evmAmount) internal pure returns (uint64) {
        return uint64(evmAmount * CORE_SCALING_FACTOR);
    }

    // Proxy tests

    function testInitialize_revertsIfOwnerIsZeroAddress() public {
        AdminUpgradableProxy _proxy = new AdminUpgradableProxy(
            address(coreDepositWalletImpl),
            coreDepositWalletProxyAdmin,
            bytes("")
        );
        vm.expectRevert("Invalid roles.owner: zero address");
        CoreDepositWallet(address(_proxy)).initialize(
            CoreDepositWallet.CoreDepositWalletRoles({
                owner: address(0),
                rescuer: coreDepositWalletRescuer,
                pauser: coreDepositWalletPauser
            })
        );
    }

    function testInitialize_revertsIfRescuerIsZeroAddress() public {
        AdminUpgradableProxy _proxy = new AdminUpgradableProxy(
            address(coreDepositWalletImpl),
            coreDepositWalletProxyAdmin,
            bytes("")
        );
        vm.expectRevert("Rescuable: new rescuer is the zero address");
        CoreDepositWallet(address(_proxy)).initialize(
            CoreDepositWallet.CoreDepositWalletRoles({
                owner: coreDepositWalletOwner,
                rescuer: address(0),
                pauser: coreDepositWalletPauser
            })
        );
    }

    function testInitialize_revertsIfPauserIsZeroAddress() public {
        AdminUpgradableProxy _proxy = new AdminUpgradableProxy(
            address(coreDepositWalletImpl),
            coreDepositWalletProxyAdmin,
            bytes("")
        );
        vm.expectRevert("Pausable: new pauser is the zero address");
        CoreDepositWallet(address(_proxy)).initialize(
            CoreDepositWallet.CoreDepositWalletRoles({
                owner: coreDepositWalletOwner,
                rescuer: coreDepositWalletRescuer,
                pauser: address(0)
            })
        );
    }

    function testInitialize_setsExpectedValues() public view {
        assertEq(coreDepositWallet.owner(), coreDepositWalletOwner);
        assertEq(coreDepositWallet.rescuer(), coreDepositWalletRescuer);
        assertEq(coreDepositWallet.pauser(), coreDepositWalletPauser);
    }

    function testInitialize_emitsEvents() public {
        AdminUpgradableProxy _proxy = new AdminUpgradableProxy(
            address(coreDepositWalletImpl),
            coreDepositWalletProxyAdmin,
            bytes("")
        );

        CoreDepositWallet _coreDepositWallet = CoreDepositWallet(
            address(_proxy)
        );

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(address(0), coreDepositWalletOwner);

        vm.expectEmit(true, true, true, true);
        emit PauserChanged(coreDepositWalletPauser);

        vm.expectEmit(true, true, true, true);
        emit RescuerChanged(coreDepositWalletRescuer);

        vm.expectEmit(true, true, true, true);
        emit Initialized(1);

        _coreDepositWallet.initialize(coreDepositWalletRoles);
    }

    function testInitialize_canBeCalledAtomicallyByTheProxy() public {
        AdminUpgradableProxy _proxy = new AdminUpgradableProxy(
            address(coreDepositWalletImpl),
            coreDepositWalletProxyAdmin,
            abi.encodeWithSelector(
                CoreDepositWallet.initialize.selector,
                coreDepositWalletRoles
            )
        );
        assertEq(
            CoreDepositWallet(address(_proxy)).owner(),
            coreDepositWalletOwner
        );
        assertEq(
            CoreDepositWallet(address(_proxy)).rescuer(),
            coreDepositWalletRescuer
        );
        assertEq(
            CoreDepositWallet(address(_proxy)).pauser(),
            coreDepositWalletPauser
        );
    }

    function testInitialize_revertsIfCalledTwice() public {
        vm.expectRevert("Initializable: invalid initialization");
        coreDepositWallet.initialize(coreDepositWalletRoles);
    }

    function testInitialize_revertsIfCalledOnImplementation() public {
        vm.expectRevert("Initializable: invalid initialization");
        coreDepositWalletImpl.initialize(coreDepositWalletRoles);
    }

    function testUpgrade_succeeds() public {
        AdminUpgradableProxy _proxy = AdminUpgradableProxy(
            payable(address(coreDepositWallet))
        );

        // Sanity check
        assertEq(_proxy.implementation(), address(coreDepositWalletImpl));

        // Test that we can upgrade to a v2 CoreDepositWallet
        // Deploy v2 implementation
        MockCoreDepositWalletV2 _implV2 = new MockCoreDepositWalletV2(
            TOKEN,
            newTokenSystemAddress
        );

        // Upgrade
        vm.prank(coreDepositWalletProxyAdmin);
        vm.expectEmit(true, true, true, true);
        emit Upgraded(address(_implV2));
        _proxy.upgradeTo(address(_implV2));

        // Sanity checks
        assertEq(_proxy.implementation(), address(_implV2));
        assertTrue(MockCoreDepositWalletV2(address(_proxy)).v2Function());
        // Check that the token system address is updated
        assertEq(coreDepositWallet.tokenSystemAddress(), newTokenSystemAddress);
    }

    function testConstructor_revertsIfTokenIsZeroAddress() public {
        vm.expectRevert("Invalid tokenAddress: zero address");
        new CoreDepositWallet(address(0), TOKEN_SYSTEM_ADDRESS);
    }

    function testConstructor_revertsIfTokenSystemAddressIsZeroAddress() public {
        vm.expectRevert("Invalid _tokenSystemAddress: zero address");
        new CoreDepositWallet(TOKEN, address(0));
    }

    // Ownable tests

    function testTransferOwnershipAndAcceptOwnership_succeeds(
        address _newOwner
    ) public {
        vm.assume(_newOwner != coreDepositWallet.owner());
        transferOwnershipAndAcceptOwnership(
            address(coreDepositWallet),
            _newOwner
        );
    }

    function testTransferOwnership_revertsOnNonOwner(
        address _notOwner,
        address _newOwner
    ) public {
        vm.assume(_notOwner != coreDepositWallet.owner());
        transferOwnershipFailsIfNotOwner(
            address(coreDepositWallet),
            _notOwner,
            _newOwner
        );
    }

    function testAcceptOwnership_revertsOnNonPendingOwner(
        address _newOwner,
        address _otherAccount
    ) public {
        vm.assume(_newOwner != _otherAccount);
        acceptOwnershipFailsIfNotPendingOwner(
            address(coreDepositWallet),
            _newOwner,
            _otherAccount
        );
    }

    function testTransferOwnershipWithoutAcceptingThenTransferToNewOwner_succeeds(
        address _newOwner,
        address _secondNewOwner
    ) public {
        transferOwnershipWithoutAcceptingThenTransferToNewOwner(
            address(coreDepositWallet),
            _newOwner,
            _secondNewOwner
        );
    }

    // Pausable tests

    function testPausable() public {
        assertContractIsPausable(
            address(coreDepositWallet),
            coreDepositWalletPauser,
            address(100),
            coreDepositWalletOwner,
            address(200)
        );
    }

    // Rescuable tests

    function testRescuable() public {
        assertContractIsRescuable(
            address(coreDepositWallet),
            coreDepositWalletRescuer,
            address(100),
            100,
            address(200)
        );
    }

    function testRescueERC20_revertsIfTokenContractIsToken(
        address _to,
        uint256 _amount
    ) public {
        vm.assume(_to != address(0));
        vm.assume(_amount > 0);

        IERC20 tokenContract = coreDepositWallet.token();
        vm.prank(coreDepositWalletRescuer);
        vm.expectRevert("Cannot rescue token");
        coreDepositWallet.rescueERC20(tokenContract, _to, _amount);
    }

    function testDeposit_succeeds(uint256 _amount, address _sender) public {
        vm.assume(_amount > 0);
        vm.assume(_amount <= type(uint64).max / 100); // Ensure scaled amount fits in uint64
        vm.assume(_sender != address(0));
        uint64 coreScaledAmount = uint64(_amount * 100); // scaled core amount

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, _amount);
        vm.startPrank(_sender);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Check that the SendRawAction event was emitted from CoreWriter
        bytes memory expectedData = _buildCoreWriterAction(_sender, _amount);

        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Expect SendAsset event with scaled amount
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledAmount);

        // Deposit tokens into the CoreDepositWallet
        coreDepositWallet.deposit(_amount);
        vm.stopPrank();

        // Check the balance of the CoreDepositWallet
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            _amount
        );
    }

    function testDeposit_succeedsWithMaxUint64Amount(address _sender) public {
        uint256 amount = type(uint64).max / 100; // Max amount before scaling overflow
        vm.assume(_sender != address(0));
        uint64 coreScaledAmount = uint64(amount * 100); // scaled core amount
        // Arrange
        _setupTokenMintAndApprove(_sender, amount);
        vm.startPrank(_sender);

        // Expect Transfer and CoreWriter action
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(coreDepositWallet), TOKEN_SYSTEM_ADDRESS, amount);

        bytes memory expectedData = _buildCoreWriterAction(_sender, amount);
        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Expect SendAsset event with scaled amount
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledAmount);

        // Act
        coreDepositWallet.deposit(amount);
        vm.stopPrank();

        // Assert balance
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            amount
        );
    }

    function testDeposit_revertsOnUint256Overflow(
        uint256 _amount,
        address _sender
    ) public {
        _amount = bound(
            _amount,
            type(uint256).max / 100 + 1,
            type(uint256).max
        ); // Will cause SafeMath multiplication overflow
        vm.assume(_sender != address(0));

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);
        // Approve the CoreDepositWallet to spend the tokens
        vm.startPrank(_sender);
        MockDepositableToken(TOKEN).approve(
            address(coreDepositWallet),
            _amount
        );

        // Expect revert due to SafeMath multiplication overflow
        vm.expectRevert("SafeMath: multiplication overflow");
        coreDepositWallet.deposit(_amount);
        vm.stopPrank();
    }

    function testDeposit_revertsOnUint64Overflow(
        uint256 _amount,
        address _sender
    ) public {
        vm.assume(
            _amount > type(uint64).max / 100 &&
                _amount <= type(uint256).max / 100
        ); // Will cause SafeCast overflow after scaling
        vm.assume(_sender != address(0));

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Approve the CoreDepositWallet to spend the tokens
        vm.startPrank(_sender);
        MockDepositableToken(TOKEN).approve(
            address(coreDepositWallet),
            _amount
        );

        // Expect revert due to SafeCast overflow
        vm.expectRevert("SafeCast: value doesn't fit in 64 bits");
        coreDepositWallet.deposit(_amount);
        vm.stopPrank();
    }

    function testDeposit_revertsWhenTransferFails(
        uint256 _amount,
        address _sender
    ) public {
        vm.assume(_sender != address(0));

        vm.prank(_sender);
        vm.mockCall(
            address(TOKEN),
            abi.encodeWithSelector(MockMintBurnToken.transferFrom.selector),
            abi.encode(false)
        );

        vm.assume(_amount > 0);
        vm.expectRevert("Transfer operation failed");
        coreDepositWallet.deposit(_amount);
    }

    function testDeposit_revertsWhenPaused(uint256 _amount) public {
        vm.assume(_amount > 0);

        vm.prank(coreDepositWalletPauser);
        coreDepositWallet.pause();
        assertTrue(coreDepositWallet.paused());

        vm.expectRevert("Pausable: paused");
        coreDepositWallet.deposit(_amount);
    }

    function testDeposit_revertsWithZeroAmount() public {
        vm.expectRevert("Amount must be greater than zero");
        coreDepositWallet.deposit(0);
    }

    function testDepositFor_succeeds(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public {
        vm.assume(_amount > 0);
        vm.assume(_amount <= type(uint64).max / 100); // Ensure scaled amount fits in uint64
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, _amount);
        vm.startPrank(_sender);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );
        // Check that the SendRawAction event was emitted from CoreWriter
        bytes memory expectedData = _buildCoreWriterAction(_recipient, _amount);

        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Expect SendAsset event with scaled amount
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_recipient, uint64(_amount * 100));

        // Deposit tokens into the CoreDepositWallet
        coreDepositWallet.depositFor(_recipient, _amount);
        vm.stopPrank();

        // Check the balance of the CoreDepositWallet
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            _amount
        );
    }

    function testDepositFor_succeedsWithMaxUint64Amount(
        address _sender,
        address _recipient
    ) public {
        uint256 amount = type(uint64).max / 100; // Max amount before scaling overflow
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));

        // Arrange
        _setupTokenMintAndApprove(_sender, amount);
        vm.startPrank(_sender);

        // Expect Transfer and CoreWriter action
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(coreDepositWallet), TOKEN_SYSTEM_ADDRESS, amount);

        bytes memory expectedData = _buildCoreWriterAction(_recipient, amount);
        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Act
        coreDepositWallet.depositFor(_recipient, amount);
        vm.stopPrank();

        // Assert balance
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            amount
        );
    }

    function testDepositFor_revertsOnUint256Overflow(
        uint256 _amount,
        address _sender,
        address _recipient
    ) public {
        _amount = bound(
            _amount,
            type(uint256).max / 100 + 1,
            type(uint256).max
        ); // Will cause SafeMath multiplication overflow
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Approve the CoreDepositWallet to spend the tokens
        vm.startPrank(_sender);
        MockDepositableToken(TOKEN).approve(
            address(coreDepositWallet),
            _amount
        );

        // Expect revert due to SafeMath multiplication overflow
        vm.expectRevert("SafeMath: multiplication overflow");
        coreDepositWallet.depositFor(_recipient, _amount);
        vm.stopPrank();
    }

    function testDepositFor_revertsOnUint64Overflow(
        uint256 _amount,
        address _sender,
        address _recipient
    ) public {
        vm.assume(
            _amount > type(uint64).max / 100 &&
                _amount <= type(uint256).max / 100
        ); // Will cause SafeCast overflow after scaling
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Approve the CoreDepositWallet to spend the tokens
        vm.startPrank(_sender);
        MockDepositableToken(TOKEN).approve(
            address(coreDepositWallet),
            _amount
        );

        // Expect revert due to SafeCast overflow
        vm.expectRevert("SafeCast: value doesn't fit in 64 bits");
        coreDepositWallet.depositFor(_recipient, _amount);
        vm.stopPrank();
    }

    function testDepositFor_revertsWhenTransferFails(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));

        vm.prank(_sender);
        vm.mockCall(
            address(TOKEN),
            abi.encodeWithSelector(MockMintBurnToken.transferFrom.selector),
            abi.encode(false)
        );

        vm.assume(_amount > 0);
        vm.expectRevert("Transfer operation failed");
        coreDepositWallet.depositFor(_recipient, _amount);
    }

    function testDepositFor_revertsWhenRecipientIsZeroAddress(
        address _sender,
        uint256 _amount
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(_amount > 0);

        vm.prank(_sender);
        vm.expectRevert("Invalid recipient: zero address");
        coreDepositWallet.depositFor(address(0), _amount);
    }

    function testDepositFor_revertsWhenRecipientIsSystemAddress(
        address _sender,
        uint256 _amount
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(_amount > 0);

        vm.prank(_sender);
        vm.expectRevert("Invalid recipient: system address");
        coreDepositWallet.depositFor(TOKEN_SYSTEM_ADDRESS, _amount);
    }

    function testDepositFor_revertsWhenRecipientIsCoreDepositWallet(
        address _sender,
        uint256 _amount
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(_amount > 0);

        vm.prank(_sender);
        vm.expectRevert("Invalid recipient: CoreDepositWallet");
        coreDepositWallet.depositFor(address(coreDepositWallet), _amount);
    }

    function testDepositFor_revertsWhenRecipientBlocklisted(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(_amount > 0);
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));

        MockDepositableToken(TOKEN).blacklist(_recipient);

        vm.prank(_sender);
        vm.expectRevert("Invalid recipient: blacklisted");
        coreDepositWallet.depositFor(_recipient, _amount);
    }

    function testDepositFor_revertsWhenPaused(
        address _sender,
        address _recipient,
        uint256 _amount
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_amount > 0);

        vm.prank(coreDepositWalletPauser);
        coreDepositWallet.pause();
        assertTrue(coreDepositWallet.paused());

        vm.prank(_sender);
        vm.expectRevert("Pausable: paused");
        coreDepositWallet.depositFor(_recipient, _amount);
    }

    function testDepositFor_revertsWithZeroAmount(
        address sender,
        address recipient
    ) public {
        vm.assume(recipient != address(0));
        vm.assume(recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(recipient != address(coreDepositWallet));

        vm.prank(sender);
        vm.expectRevert("Amount must be greater than zero");
        coreDepositWallet.depositFor(recipient, 0);
    }

    function testDepositWithAuth_succeeds(
        uint256 _amount,
        address _sender
    ) public {
        vm.assume(_amount > 0);
        vm.assume(_amount <= type(uint64).max / 100); // Ensure scaled amount fits in uint64
        vm.assume(_sender != address(0));
        uint64 coreScaledAmount = uint64(_amount * 100); // scaled core amount

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Check that the SendRawAction event was emitted from CoreWriter
        bytes memory expectedData = _buildCoreWriterAction(_sender, _amount);

        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Expect SendAsset event with scaled amount
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledAmount);

        // Deposit tokens into the CoreDepositWallet
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            _amount,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("s"),
            bytes32("v")
        );

        // Check the balance of the CoreDepositWallet
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            _amount
        );
    }

    function testDepositWithAuth_succeedsWithMaxUint64Amount(
        address _sender
    ) public {
        uint256 amount = type(uint64).max / 100; // Max amount before scaling overflow
        vm.assume(_sender != address(0));
        uint64 coreScaledAmount = uint64(amount * 100); // scaled core amount
        // Arrange (token is pulled via receiveWithAuthorization)
        MockDepositableToken(TOKEN).mint(_sender, amount);

        // Expect Transfer and CoreWriter action
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(coreDepositWallet), TOKEN_SYSTEM_ADDRESS, amount);

        bytes memory expectedData = _buildCoreWriterAction(_sender, amount);
        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Expect SendAsset event with scaled amount
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledAmount);

        // Act
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            amount,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("r"),
            bytes32("s")
        );

        // Assert balance
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            amount
        );
    }

    function testDepositWithAuth_revertsOnUint256Overflow(
        uint256 _amount,
        address _sender
    ) public {
        _amount = bound(
            _amount,
            type(uint256).max / 100 + 1,
            type(uint256).max
        ); // Will cause SafeMath multiplication overflow
        vm.assume(_sender != address(0));

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Expect revert due to SafeMath multiplication overflow
        vm.prank(_sender);
        vm.expectRevert("SafeMath: multiplication overflow");
        coreDepositWallet.depositWithAuth(
            _amount,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("r"),
            bytes32("s")
        );
    }

    function testDepositWithAuth_revertsOnUint64Overflow(
        uint256 _amount,
        address _sender
    ) public {
        vm.assume(
            _amount > type(uint64).max / 100 &&
                _amount <= type(uint256).max / 100
        ); // Will cause SafeCast overflow after scaling
        vm.assume(_sender != address(0));

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Expect revert due to SafeCast overflow
        vm.prank(_sender);
        vm.expectRevert("SafeCast: value doesn't fit in 64 bits");
        coreDepositWallet.depositWithAuth(
            _amount,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("r"),
            bytes32("s")
        );
    }

    function testDepositWithAuth_revertsWhenPaused(
        uint256 _amount,
        address _sender
    ) public {
        vm.assume(_amount > 0);
        vm.assume(_sender != address(0));

        vm.prank(coreDepositWalletPauser);
        coreDepositWallet.pause();
        assertTrue(coreDepositWallet.paused());

        vm.expectRevert("Pausable: paused");
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            _amount,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("s"),
            bytes32("v")
        );
    }

    function testDepositWithAuth_revertsWithZeroAmount(address _sender) public {
        vm.assume(_sender != address(0));

        vm.expectRevert("Amount must be greater than zero");
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            0,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("s"),
            bytes32("v")
        );
    }

    function testDepositWithAuth_revertsWhenReceiveFails(
        uint256 _amount,
        address _sender
    ) public {
        vm.assume(_amount > 0);
        vm.assume(_sender != address(0));

        vm.mockCallRevert(
            address(TOKEN),
            abi.encodeWithSelector(
                MockEIP3009Token.receiveWithAuthorization.selector
            ),
            abi.encode("revert")
        );

        vm.expectRevert();
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            _amount,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("s"),
            bytes32("v")
        );
    }

    function testTransfer_succeeds(address _to, uint256 _amount) public {
        vm.assume(_to != address(0));
        vm.assume(_to != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_amount > 0);

        // Mint tokens to the CoreDepositWallet
        MockDepositableToken(TOKEN).mint(address(coreDepositWallet), _amount);

        // Check that the Withdraw event was emitted
        vm.expectEmit(true, true, true, true);
        emit Withdraw(_to, _amount);

        // Transfer tokens from the CoreDepositWallet
        vm.prank(TOKEN_SYSTEM_ADDRESS);
        assertTrue(coreDepositWallet.transfer(_to, _amount));

        // Check the balance of the _to address
        assertEq(MockDepositableToken(TOKEN).balanceOf(_to), _amount);
    }

    function testTransfer_revertsWhenSenderIsNotSystemAddress(
        address _to,
        uint256 _amount
    ) public {
        vm.assume(_to != TOKEN_SYSTEM_ADDRESS);
        vm.prank(_to);

        vm.expectRevert("Caller is not the system address");
        coreDepositWallet.transfer(_to, _amount);
    }

    function testTransfer_revertsWhenToIsSystemAddress(uint256 _amount) public {
        vm.prank(TOKEN_SYSTEM_ADDRESS);

        vm.expectRevert("Invalid to: system address");
        coreDepositWallet.transfer(TOKEN_SYSTEM_ADDRESS, _amount);
    }

    function testTransfer_revertsWhenTransferFails(
        address _to,
        uint256 _amount
    ) public {
        vm.assume(_to != address(0));
        vm.assume(_to != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_amount > 0);

        vm.mockCall(
            address(TOKEN),
            abi.encodeWithSelector(MockMintBurnToken.transfer.selector),
            abi.encode(false)
        );

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        vm.expectRevert("Transfer operation failed");
        coreDepositWallet.transfer(_to, _amount);
    }

    function testTransfer_revertsWhenPaused(
        address _to,
        uint256 _amount
    ) public {
        vm.assume(_to != address(0));
        vm.assume(_amount > 0);

        vm.prank(coreDepositWalletPauser);
        coreDepositWallet.pause();
        assertTrue(coreDepositWallet.paused());

        vm.expectRevert("Pausable: paused");
        coreDepositWallet.transfer(_to, _amount);
    }

    function testSendAssetEncoding_matchesSpec(
        address _sender,
        uint256 _amount
    ) public {
        // Constrain to valid values that avoid scaled amount overflow
        vm.assume(_sender != address(0));
        vm.assume(_amount > 0 && _amount <= type(uint64).max / 100);

        // Arrange
        MockDepositableToken(TOKEN).mint(_sender, _amount);
        vm.startPrank(_sender);
        MockDepositableToken(TOKEN).approve(
            address(coreDepositWallet),
            _amount
        );

        // Record logs to capture CoreWriter event
        vm.recordLogs();

        // Act
        coreDepositWallet.deposit(_amount);
        vm.stopPrank();

        // Extract the raw action bytes from CoreWriter's SendRawAction event
        bytes memory rawAction;
        {
            Vm.Log[] memory logs = vm.getRecordedLogs();
            bytes32 sig = keccak256("SendRawAction(address,bytes)");
            address coreWriter = 0x3333333333333333333333333333333333333333;
            for (uint256 i = 0; i < logs.length; i++) {
                if (
                    logs[i].emitter == coreWriter &&
                    logs[i].topics.length > 0 &&
                    logs[i].topics[0] == sig
                ) {
                    rawAction = abi.decode(logs[i].data, (bytes));
                    break;
                }
            }
        }
        require(rawAction.length > 0, "SendRawAction not found");

        // Validate header: 1-byte version, 3-byte big-endian actionId
        require(rawAction.length >= 4, "rawAction too short");
        {
            uint256 version256 = uint256(uint8(rawAction[0]));
            uint256 actionId256 = uint256(
                (uint24(uint8(rawAction[1])) << 16) |
                    (uint24(uint8(rawAction[2])) << 8) |
                    uint24(uint8(rawAction[3]))
            );
            assertEq(version256, uint256(0x01), "version");
            assertEq(actionId256, uint256(0x00000D), "actionId");
        }

        // Slice payload and decode ABI-encoded fields, then assert
        {
            bytes memory payload = new bytes(rawAction.length - 4);
            for (uint256 j = 0; j < payload.length; j++) {
                payload[j] = rawAction[4 + j];
            }
            (
                address recipient,
                address subAccount,
                uint32 sourceDex,
                uint32 destinationDex,
                uint64 tokenIndex,
                uint64 amount64
            ) = abi.decode(
                    payload,
                    (address, address, uint32, uint32, uint64, uint64)
                );

            assertEq(recipient, _sender, "recipient");
            assertEq(subAccount, address(0), "subAccount");
            assertEq(
                uint256(sourceDex),
                uint256(type(uint32).max),
                "sourceDex"
            );
            assertEq(uint256(destinationDex), uint256(0), "destinationDex");
            assertEq(uint256(tokenIndex), uint256(0), "tokenIndex");
            assertEq(uint256(amount64), uint256(_amount * 100), "amount");
        }
    }

    function testGetCoreProtocolConstants_returnsExpectedValues() public view {
        CoreDepositWallet.CoreProtocolConstants memory c = coreDepositWallet
            .getCoreProtocolConstants();
        assertEq(
            uint256(c.coreWriterActionVersion),
            uint256(0x01),
            "coreWriterActionVersion"
        );
        assertEq(
            uint256(c.coreWriterSendAssetActionId),
            uint256(0x00000D),
            "coreWriterSendAssetActionId"
        );
        assertEq(
            uint256(c.coreWriterTokenIndex),
            uint256(0),
            "coreWriterTokenIndex"
        );
        assertEq(
            uint256(c.coreWriterSourceSpotDex),
            uint256(type(uint32).max),
            "coreWriterSourceSpotDex"
        );
        assertEq(
            uint256(c.coreWriterDestinationPerpDex),
            uint256(0),
            "coreWriterDestinationPerpDex"
        );
        assertEq(
            c.coreWriterAddress,
            0x3333333333333333333333333333333333333333,
            "coreWriterAddress"
        );
        assertEq(
            c.coreUserExistsAddress,
            0x0000000000000000000000000000000000000810,
            "coreUserExistsAddress"
        );
        assertEq(
            uint256(c.coreScalingFactor),
            uint256(100),
            "coreScalingFactor"
        );
    }

    // ============ New Account Fee Tests ============

    function testNewCoreAccountFee_defaultIsSetCorrectly() public view {
        assertEq(
            uint256(coreDepositWallet.newCoreAccountFee()),
            uint256(DEFAULT_NEW_CORE_ACCOUNT_FEE),
            "Default new account fee should be 1 USDC"
        );
    }

    function testUpdateNewCoreAccountFee_onlyOwner(uint64 newCoreFee) public {
        // Non-owner cannot update
        vm.prank(address(0x999));
        vm.expectRevert("Ownable: caller is not the owner");
        coreDepositWallet.updateNewCoreAccountFee(newCoreFee);

        // Owner can update
        vm.expectEmit(true, true, true, true);
        emit NewCoreAccountFeeUpdated(DEFAULT_NEW_CORE_ACCOUNT_FEE, newCoreFee);

        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(newCoreFee);

        assertEq(
            uint256(coreDepositWallet.newCoreAccountFee()),
            uint256(newCoreFee),
            "Fee should be updated"
        );
    }

    function testDepositFor_existingUser_noFeeApplied(
        uint256 evmDepositAmount
    ) public {
        // Bound: 1 <= evmDepositAmount <= type(uint64).max / 100 to avoid scaling overflow
        evmDepositAmount = bound(evmDepositAmount, 1, type(uint64).max / 100);
        uint64 scaledCoreAmount = uint64(evmDepositAmount * 100);
        address recipient = address(0x123);

        // Mock user exists (returns true)
        _mockCoreUserExists(recipient, true);

        // Mock token operations
        _setupTokenMintAndApprove(address(this), evmDepositAmount);

        // Expect full amount to be sent (no fee deduction)
        bytes memory expectedPayload = abi.encode(
            recipient,
            address(0),
            type(uint32).max,
            uint32(0),
            uint64(0),
            scaledCoreAmount
        );
        bytes memory expectedData = abi.encodePacked(
            uint8(0x01),
            uint24(0x00000D),
            expectedPayload
        );

        vm.expectCall(
            CORE_WRITER_ADDRESS,
            abi.encodeWithSelector(
                ICoreWriter.sendRawAction.selector,
                expectedData
            )
        );

        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            evmDepositAmount
        );
        vm.expectEmit(true, true, true, true);
        emit SendAsset(recipient, scaledCoreAmount); // scaled core amount without any fee deduction

        coreDepositWallet.depositFor(recipient, evmDepositAmount);
    }

    function testDepositFor_newUser_feeApplied(
        uint256 evmDepositAmount,
        uint64 coreNewAccountFee
    ) public {
        (uint256 evmAmount, uint64 fee) = _boundDepositAndFee(
            evmDepositAmount,
            coreNewAccountFee
        );
        uint64 coreScaledAmount = _scaleToCore(evmAmount);
        uint64 coreNetScaledAmount = uint64(uint256(coreScaledAmount) - fee);
        address recipient = address(0x123);

        // Set up fee (core units)
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(fee);

        // Mock user does NOT exist (returns false)
        _mockCoreUserExists(recipient, false);

        // Mock token operations
        _setupTokenMintAndApprove(address(this), evmAmount);

        // Expect reduced core amount to be sent (after fee deduction in core units)
        bytes memory expectedPayload = abi.encode(
            recipient,
            address(0),
            type(uint32).max,
            uint32(0),
            uint64(0),
            coreNetScaledAmount
        );
        bytes memory expectedData = abi.encodePacked(
            uint8(0x01),
            uint24(0x00000D),
            expectedPayload
        );

        vm.expectCall(
            CORE_WRITER_ADDRESS,
            abi.encodeWithSelector(
                ICoreWriter.sendRawAction.selector,
                expectedData
            )
        );

        // Expect Transfer event with full deposited amount (emitted before fee deduction)
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            evmAmount
        );

        // Should emit NewCoreAccountFeeApplied with core units
        vm.expectEmit(true, true, true, true);
        emit NewCoreAccountFeeApplied(
            recipient,
            fee,
            evmAmount,
            coreNetScaledAmount
        );

        // Expect SendAsset event with scaled net amount (after fee deduction)
        vm.expectEmit(true, true, true, true);
        emit SendAsset(recipient, coreNetScaledAmount);

        coreDepositWallet.depositFor(recipient, evmAmount);
    }

    function testDepositFor_newUser_insufficientAmount_reverts(
        uint256 evmDepositAmount,
        uint64 coreFee
    ) public {
        // Choose fee (core units) large enough that some deposit amounts are <= fee/100
        coreFee = uint64(bound(uint256(coreFee), 100, type(uint64).max));
        // Constrain: 1 <= depositAmount <= floor(coreFee/100)
        evmDepositAmount = bound(evmDepositAmount, 1, coreFee / 100);
        address recipient = address(0x123);

        // Set up fee
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(coreFee);

        // Mock user does NOT exist (returns false)
        _mockCoreUserExists(recipient, false);

        // Mock token operations
        _setupTokenMintAndApprove(address(this), evmDepositAmount);

        // Should revert with insufficient amount (100*evmDeposit <= coreFee)
        vm.expectRevert("Amount must exceed new account fee");
        coreDepositWallet.depositFor(recipient, evmDepositAmount);
    }

    function testDepositFor_newUser_exactFeeAmount_reverts(
        uint64 coreFee
    ) public {
        // Bound fee (core units) so that depositAmount = coreFee/100 is valid (>0)
        coreFee = uint64(bound(uint256(coreFee), 100, type(uint64).max));
        address recipient = address(0x123);

        // Set up fee
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(coreFee);

        // Mock user does NOT exist (returns false)
        _mockCoreUserExists(recipient, false);

        // Mock token operations
        uint256 evmDepositAmount = coreFee / 100;
        _setupTokenMintAndApprove(address(this), evmDepositAmount);

        // Should revert when 100*evmDepositAmount <= coreFee
        vm.expectRevert("Amount must exceed new account fee");
        coreDepositWallet.depositFor(recipient, evmDepositAmount);
    }

    function testDepositFor_newUser_zeroFee_noFeeLogic(
        uint256 evmDepositAmount
    ) public {
        // Bound: 1 <= evmDepositAmount <= type(uint64).max / 100 to avoid scaling overflow
        evmDepositAmount = bound(evmDepositAmount, 1, type(uint64).max / 100);
        uint64 coreScaledAmount = uint64(evmDepositAmount * 100); // scaled core amount
        uint64 coreFee = 0; // 0 USDC (core token units)
        address recipient = address(0x123);

        // Set fee to 0 for this test
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(coreFee);

        // Mock user does NOT exist (returns false)
        _mockCoreUserExists(recipient, false);

        // Mock token operations
        _setupTokenMintAndApprove(address(this), evmDepositAmount);

        // Expect full amount to be sent (no fee when fee is 0)
        bytes memory expectedPayload = abi.encode(
            recipient,
            address(0),
            type(uint32).max,
            uint32(0),
            uint64(0),
            coreScaledAmount
        );
        bytes memory expectedData = abi.encodePacked(
            uint8(0x01),
            uint24(0x00000D),
            expectedPayload
        );

        vm.expectCall(
            CORE_WRITER_ADDRESS,
            abi.encodeWithSelector(
                ICoreWriter.sendRawAction.selector,
                expectedData
            )
        );

        // Should emit Transfer and SendAsset without any fee deduction; should NOT emit NewCoreAccountFeeApplied when fee is 0
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            evmDepositAmount
        );
        vm.expectEmit(true, true, true, true);
        emit SendAsset(recipient, coreScaledAmount);

        coreDepositWallet.depositFor(recipient, evmDepositAmount);
    }

    function testDeposit_existingUser_noFeeApplied(
        address _sender,
        uint256 evmDepositAmount
    ) public {
        // Bound: 1 <= evmDepositAmount <= type(uint64).max / 100 to avoid scaling overflow
        evmDepositAmount = bound(evmDepositAmount, 1, type(uint64).max / 100);
        uint64 coreScaledAmount = uint64(evmDepositAmount * 100);
        vm.assume(_sender != address(0));

        // Mock user exists (returns true)
        _mockCoreUserExists(_sender, true);

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, evmDepositAmount);
        vm.startPrank(_sender);

        // Expect full amount to be sent (no fee deduction)
        bytes memory expectedData = _buildCoreWriterAction(
            _sender,
            evmDepositAmount
        );

        vm.expectCall(
            CORE_WRITER_ADDRESS,
            abi.encodeWithSelector(
                ICoreWriter.sendRawAction.selector,
                expectedData
            )
        );

        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            evmDepositAmount
        );
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledAmount);

        coreDepositWallet.deposit(evmDepositAmount);
        vm.stopPrank();
    }

    function testDeposit_newUser_feeApplied(
        address _sender,
        uint256 evmDepositAmount,
        uint64 coreFee
    ) public {
        vm.assume(_sender != address(0));

        // Use helper to bound deposit and fee with valid relationship
        (uint256 evmAmount, uint64 fee) = _boundDepositAndFee(
            evmDepositAmount,
            coreFee
        );
        uint64 coreScaledAmount = _scaleToCore(evmAmount);
        uint64 coreNetScaledAmount = uint64(uint256(coreScaledAmount) - fee);

        // Set up fee
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(fee);

        // Mock user does NOT exist (returns false)
        _mockCoreUserExists(_sender, false);

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, evmAmount);
        vm.startPrank(_sender);

        // Expect reduced core amount to be sent (after fee deduction)
        bytes memory expectedPayload = abi.encode(
            _sender,
            address(0),
            type(uint32).max,
            uint32(0),
            uint64(0),
            coreNetScaledAmount
        );
        bytes memory expectedData = abi.encodePacked(
            uint8(0x01),
            uint24(0x00000D),
            expectedPayload
        );
        vm.expectCall(
            CORE_WRITER_ADDRESS,
            abi.encodeWithSelector(
                ICoreWriter.sendRawAction.selector,
                expectedData
            )
        );

        // Expect Transfer (full amount), fee applied event, and SendAsset (net)
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            evmAmount
        );

        vm.expectEmit(true, true, true, true);
        emit NewCoreAccountFeeApplied(
            _sender,
            fee,
            evmAmount,
            coreNetScaledAmount
        );

        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreNetScaledAmount);

        coreDepositWallet.deposit(evmAmount);
        vm.stopPrank();
    }

    function testDeposit_newUser_insufficientAmount_reverts(
        address _sender,
        uint256 evmDepositAmount,
        uint64 coreFee
    ) public {
        vm.assume(_sender != address(0));
        // Bound fee (core units) so that there exist deposits with 100*deposit <= fee
        coreFee = uint64(bound(uint256(coreFee), 100, type(uint64).max));
        // Constrain: 1 <= depositAmount <= floor(coreFee/100)
        evmDepositAmount = bound(evmDepositAmount, 1, coreFee / 100);

        // Set up fee
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(coreFee);

        // Mock user does NOT exist (returns false)
        _mockCoreUserExists(_sender, false);

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, evmDepositAmount);
        vm.startPrank(_sender);

        // Should revert with insufficient amount
        vm.expectRevert("Amount must exceed new account fee");
        coreDepositWallet.deposit(evmDepositAmount);
        vm.stopPrank();
    }

    function testDeposit_newUser_exactFeeAmount_reverts(
        address _sender,
        uint64 coreFee
    ) public {
        // Bound fee (core units) so that depositAmount = coreFee/100 is valid
        coreFee = uint64(bound(uint256(coreFee), 100, type(uint64).max));
        vm.assume(_sender != address(0));

        // Set up fee
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(coreFee);

        // Mock user does NOT exist (returns false)
        _mockCoreUserExists(_sender, false);

        // Setup tokens for sender
        uint256 evmDepositAmount = coreFee / 100;
        _setupTokenMintAndApprove(_sender, evmDepositAmount);
        vm.startPrank(_sender);

        // Should revert when amount equals fee (no net amount)
        vm.expectRevert("Amount must exceed new account fee");
        coreDepositWallet.deposit(evmDepositAmount);
        vm.stopPrank();
    }

    function testDeposit_newUser_zeroFee_noFeeLogic(
        address _sender,
        uint256 evmDepositAmount
    ) public {
        // Bound: 1 <= evmDepositAmount <= type(uint64).max / 100 to avoid scaling overflow
        evmDepositAmount = bound(evmDepositAmount, 1, type(uint64).max / 100);
        uint64 coreScaledAmount = uint64(evmDepositAmount * 100);
        uint64 coreFee = 0; // 0 USDC (core token units)
        vm.assume(_sender != address(0));

        // Set fee to 0 for this test
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(coreFee);

        // Mock user does NOT exist (returns false)
        _mockCoreUserExists(_sender, false);

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, evmDepositAmount);
        vm.startPrank(_sender);

        // Expect full amount to be sent (no fee)
        bytes memory expectedData = _buildCoreWriterAction(
            _sender,
            evmDepositAmount
        );
        vm.expectCall(
            CORE_WRITER_ADDRESS,
            abi.encodeWithSelector(
                ICoreWriter.sendRawAction.selector,
                expectedData
            )
        );

        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            evmDepositAmount
        );
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledAmount);

        coreDepositWallet.deposit(evmDepositAmount);
        vm.stopPrank();
    }

    function testDepositWithAuth_newUser_feeApplied(
        address _sender,
        uint256 evmDepositAmount,
        uint64 coreFee
    ) public {
        vm.assume(_sender != address(0));

        // Use helper to bound deposit and fee with valid relationship
        (uint256 evmAmount, uint64 fee) = _boundDepositAndFee(
            evmDepositAmount,
            coreFee
        );
        uint64 coreScaledNetAmount = uint64(
            uint256(_scaleToCore(evmAmount)) - fee
        ); // scaled core net amount

        // Set up fee
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(fee);

        // Mock user does NOT exist (returns false)
        _mockCoreUserExists(_sender, false);

        // Mock token operations
        MockDepositableToken(TOKEN).mint(_sender, evmAmount);

        // Mock receiveWithAuthorization
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(
                MockEIP3009Token.receiveWithAuthorization.selector
            ),
            abi.encode()
        );

        // Expect net core amount to be sent
        bytes memory expectedPayload = abi.encode(
            _sender,
            address(0),
            type(uint32).max,
            uint32(0),
            uint64(0),
            coreScaledNetAmount
        );
        bytes memory expectedData = abi.encodePacked(
            uint8(0x01),
            uint24(0x00000D),
            expectedPayload
        );

        vm.expectCall(
            CORE_WRITER_ADDRESS,
            abi.encodeWithSelector(
                ICoreWriter.sendRawAction.selector,
                expectedData
            )
        );

        // Expect Transfer event with full deposited amount (emitted before fee logic)
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            evmAmount
        );
        // Should emit NewCoreAccountFeeApplied with core units
        vm.expectEmit(true, true, true, true);
        emit NewCoreAccountFeeApplied(
            _sender,
            fee,
            evmAmount,
            coreScaledNetAmount
        );
        // Expect SendAsset event with scaled net amount (after fee)
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledNetAmount);

        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            evmAmount,
            block.timestamp - 1,
            block.timestamp + 1000,
            bytes32(uint256(1)),
            27,
            bytes32(uint256(2)),
            bytes32(uint256(3))
        );
    }

    function testDepositWithAuth_existingUser_noFeeApplied(
        address _sender,
        uint256 evmDepositAmount
    ) public {
        // Bound: 1 <= evmDepositAmount <= type(uint64).max / 100 to avoid scaling overflow
        evmDepositAmount = bound(evmDepositAmount, 1, type(uint64).max / 100);
        uint64 coreScaledAmount = uint64(evmDepositAmount * 100); // scaled core amount
        vm.assume(_sender != address(0));

        // Existing user
        _mockCoreUserExists(_sender, true);

        // Mint tokens to sender and mock receiveWithAuthorization
        MockDepositableToken(TOKEN).mint(_sender, evmDepositAmount);
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(
                MockEIP3009Token.receiveWithAuthorization.selector
            ),
            abi.encode()
        );

        // Expect CoreWriter call with full amount
        bytes memory expectedData = _buildCoreWriterAction(
            _sender,
            evmDepositAmount
        );
        vm.expectCall(
            CORE_WRITER_ADDRESS,
            abi.encodeWithSelector(
                ICoreWriter.sendRawAction.selector,
                expectedData
            )
        );

        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            evmDepositAmount
        );
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledAmount);

        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            evmDepositAmount,
            block.timestamp - 1,
            block.timestamp + 1000,
            bytes32(uint256(1)),
            27,
            bytes32(uint256(2)),
            bytes32(uint256(3))
        );
    }

    function testDepositWithAuth_newUser_insufficientAmount_reverts(
        address _sender,
        uint256 evmDepositAmount,
        uint64 coreFee
    ) public {
        vm.assume(_sender != address(0));
        // Bound fee (core units) so that there exist deposits with 100*deposit <= fee
        coreFee = uint64(bound(uint256(coreFee), 100, type(uint64).max));
        evmDepositAmount = bound(evmDepositAmount, 1, coreFee / 100);

        // Set fee and mark as new user
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(coreFee);
        _mockCoreUserExists(_sender, false);

        // Mint and mock auth
        MockDepositableToken(TOKEN).mint(_sender, evmDepositAmount);
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(
                MockEIP3009Token.receiveWithAuthorization.selector
            ),
            abi.encode()
        );

        vm.prank(_sender);
        vm.expectRevert("Amount must exceed new account fee");

        coreDepositWallet.depositWithAuth(
            evmDepositAmount,
            block.timestamp - 1,
            block.timestamp + 1000,
            bytes32(uint256(1)),
            27,
            bytes32(uint256(2)),
            bytes32(uint256(3))
        );
    }

    function testDepositWithAuth_newUser_exactFeeAmount_reverts(
        address _sender,
        uint64 coreFee
    ) public {
        // Bound fee (core units)
        coreFee = uint64(bound(uint256(coreFee), 100, type(uint64).max));
        uint256 evmDepositAmount = coreFee / 100;
        vm.assume(_sender != address(0));

        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(coreFee);
        _mockCoreUserExists(_sender, false);

        MockDepositableToken(TOKEN).mint(_sender, evmDepositAmount);
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(
                MockEIP3009Token.receiveWithAuthorization.selector
            ),
            abi.encode()
        );

        vm.prank(_sender);
        vm.expectRevert("Amount must exceed new account fee");
        coreDepositWallet.depositWithAuth(
            evmDepositAmount,
            block.timestamp - 1,
            block.timestamp + 1000,
            bytes32(uint256(1)),
            27,
            bytes32(uint256(2)),
            bytes32(uint256(3))
        );
    }

    function testDepositWithAuth_newUser_zeroFee_noFeeLogic(
        address _sender,
        uint256 evmDepositAmount
    ) public {
        vm.assume(_sender != address(0));
        evmDepositAmount = bound(evmDepositAmount, 1, type(uint64).max / 100);
        uint64 coreScaledAmount = uint64(evmDepositAmount * 100);

        // Set fee to 0 and mark as new user
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(uint64(0));
        _mockCoreUserExists(_sender, false);

        // Mint and mock auth
        MockDepositableToken(TOKEN).mint(_sender, evmDepositAmount);
        vm.mockCall(
            TOKEN,
            abi.encodeWithSelector(
                MockEIP3009Token.receiveWithAuthorization.selector
            ),
            abi.encode()
        );

        // Expect full amount
        bytes memory expectedData = _buildCoreWriterAction(
            _sender,
            evmDepositAmount
        );
        vm.expectCall(
            CORE_WRITER_ADDRESS,
            abi.encodeWithSelector(
                ICoreWriter.sendRawAction.selector,
                expectedData
            )
        );

        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            evmDepositAmount
        );
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledAmount);

        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            evmDepositAmount,
            block.timestamp - 1,
            block.timestamp + 1000,
            bytes32(uint256(1)),
            27,
            bytes32(uint256(2)),
            bytes32(uint256(3))
        );
    }

    function testPrecompileCall_failure_reverts(uint256 depositAmount) public {
        address recipient = address(0x123);
        // Bound: 1 <= depositAmount <= type(uint64).max / 100 to avoid scaling overflow
        depositAmount = bound(depositAmount, 1, type(uint64).max / 100);

        // Mock precompile call failure
        vm.mockCallRevert(
            CORE_USER_EXISTS_ADDRESS,
            abi.encode(recipient),
            "Precompile error"
        );

        // Mock token operations
        _setupTokenMintAndApprove(address(this), depositAmount);

        // Should revert with precompile error
        vm.expectRevert("Core user exists precompile call failed");
        coreDepositWallet.depositFor(recipient, depositAmount);
    }

    function testUpdateNewCoreAccountFee_multipleTimes() public {
        uint64 fee1 = 150000000; // 1.5 USDC (8 decimals)
        uint64 fee2 = 200000000; // 2 USDC (8 decimals)
        uint64 fee3 = 0;

        // First update
        vm.expectEmit(true, true, true, true);
        emit NewCoreAccountFeeUpdated(DEFAULT_NEW_CORE_ACCOUNT_FEE, fee1);
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(fee1);
        assertEq(uint256(coreDepositWallet.newCoreAccountFee()), uint256(fee1));

        // Second update (previous fee is now fee1)
        vm.expectEmit(true, true, true, true);
        emit NewCoreAccountFeeUpdated(fee1, fee2);
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(fee2);
        assertEq(uint256(coreDepositWallet.newCoreAccountFee()), uint256(fee2));

        // Third update (previous fee is now fee2, not 0)
        vm.expectEmit(true, true, true, true);
        emit NewCoreAccountFeeUpdated(fee2, fee3);
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(fee3);
        assertEq(uint256(coreDepositWallet.newCoreAccountFee()), uint256(fee3));
    }

    function testDeposit_newUser_minimalViableAmount(uint64 coreFee) public {
        // Bound fee (core units)
        uint256 maxDeposit = type(uint64).max / 100;
        coreFee = uint64(bound(coreFee, 1, maxDeposit * 100 - 1));
        // Choose minimal deposit so that net core amount >= 1 and scaled fits in uint64
        uint256 depositAmount = (coreFee / 100) + 1;
        uint64 coreScaledNetAmount = uint64(
            uint256(uint64(depositAmount * 100)) - coreFee
        );
        address recipient = address(0x123);

        // Set up fee
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(coreFee);

        // Mock user does NOT exist
        vm.mockCall(
            CORE_USER_EXISTS_ADDRESS,
            abi.encode(recipient),
            abi.encode(false)
        );

        // Mock token operations
        _setupTokenMintAndApprove(address(this), depositAmount);

        // Expect Transfer (full amount) then NewCoreAccountFeeApplied with minimal net amount
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            depositAmount
        );
        vm.expectEmit(true, true, true, true);
        emit NewCoreAccountFeeApplied(
            recipient,
            coreFee,
            depositAmount,
            coreScaledNetAmount
        );

        // Expect SendAsset event with scaled net amount (after fee)
        vm.expectEmit(true, true, true, true);
        emit SendAsset(recipient, coreScaledNetAmount); // scaled core net amount
        coreDepositWallet.depositFor(recipient, depositAmount);
    }
}
