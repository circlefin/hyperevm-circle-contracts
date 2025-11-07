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

    event CrossChainWithdraw(address indexed from, bytes32 indexed to, uint256 value, uint32 destinationDomain, uint64 indexed coreNonce);

    event CctpMaxFeeUpdated(uint256 previousFee, uint256 newFee);

    event CctpDefaultForwardFeeUpdated(uint256 previousFee, uint256 newFee);

    event CctpForwardFeeUpdated(uint32 indexed destinationDomain, uint256 previousFee, uint256 newFee);

    event SendRawAction(address indexed user, bytes data);

    event SendAsset(address indexed coreRecipient, uint64 coreAmount, uint32 destinationDex);

    event NewCoreAccountFeeUpdated(uint64 previousFee, uint64 newFee);

    event NewCoreAccountFeeApplied(
        address indexed coreRecipient,
        uint64 newCoreAccountFee,
        uint256 evmDepositAmount,
        uint64 coreSentAmount
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

    address public newTokenSystemAddress = address(11);
    address private constant CORE_USER_EXISTS_PRECOMPILE_ADDRESS =
        0x0000000000000000000000000000000000000810;
    address private constant CORE_WRITER_PRECOMPILE_ADDRESS =
        0x3333333333333333333333333333333333333333;

    uint64 private constant DEFAULT_NEW_CORE_ACCOUNT_FEE = 100000000; // 1 USDC (8 decimals)
    uint256 private constant CORE_SCALING_FACTOR = 100; // 6 decimals -> 8 decimals
    uint256 private constant MAX_TRANSFER_VALUE_FROM_EVM = 184467440737095516; // type(uint64.max) / 100;

    uint256 private constant CCTP_MAX_FEE = 0;
    uint256 private constant CCTP_DEFAULT_FORWARD_FEE = 200000; // 0.2 USDC (6 decimals)
    bytes24 private constant CCTP_FORWARD_HOOK_MAGIC_BYTES = bytes24("cctp-forward");
    uint256 private constant MAX_HOOK_DATA_SIZE = 1024; // mirror CoreDepositWallet limit

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
            CORE_USER_EXISTS_PRECOMPILE_ADDRESS,
            type(MockCoreUserExistsPrecompile).runtimeCode
        );
    }

    // Helper functions
    function _buildCoreWriterAction(
        address sender,
        uint256 amount,
        uint32 destinationDex
    ) internal pure returns (bytes memory data) {
        // Scale from 6 decimals (HyperEVM) to 8 decimals (HyperCore) to match contract
        uint256 scaledAmount = amount * 100;
        bytes memory encodedAction = abi.encode(
            sender, // recipient
            address(0), // subAccount
            SPOT_DEX_ID, // SOURCE_SPOT_DEX
            destinationDex, // destination dex
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

    // Builds the expected CCTP hook bytes as constructed by the CrossChainWithdrawalHookData library.
    function _buildExpectedHook(
        bool shouldForward,
        address from,
        uint64 nonce,
        bytes memory userData
    ) internal pure returns (bytes memory) {
        bytes24 magic = shouldForward ? bytes24("cctp-forward") : bytes24(0);
        return abi.encodePacked(magic, uint32(0), uint32(20 + 8 + userData.length), from, nonce, userData); // 20 bytes for EVM address + 8 bytes for nonce + length of the user data
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
            CORE_USER_EXISTS_PRECOMPILE_ADDRESS,
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

    function _assertSuccessfulDepositToSpot(uint256 _amount) internal {
        // Assert balance of CoreDepositWallet == deposit amount
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            _amount
        );

        // Assert that no CoreWriter actions were emitted
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 2);
        // Transfer to CoreDepositWallet
        assertEq(entries[0].topics[0], keccak256("Transfer(address,address,uint256)"));
        // Transfer to recipient
        assertEq(entries[1].topics[0], keccak256("Transfer(address,address,uint256)"));
    }

    function _assertSuccessfulDepositWithAuthToSpot(uint256 _amount) internal {
        // Assert balance of CoreDepositWallet == deposit amount
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            _amount
        );

        // Assert that no CoreWriter actions were emitted
        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 3);
        // Transfer to CoreDepositWallet
        assertEq(entries[0].topics[0], keccak256("AuthorizationUsed(address,bytes32)"));
        assertEq(entries[1].topics[0], keccak256("Transfer(address,address,uint256)"));
        // Transfer to recipient
        assertEq(entries[2].topics[0], keccak256("Transfer(address,address,uint256)"));
    }

    // Enable destinationDex if disabled
    function _enableDestinationDex(uint32 _destinationDex) internal {
        if (!coreDepositWallet.enabledDestinationDexes(_destinationDex) && _destinationDex != SPOT_DEX_ID) {
            vm.prank(coreDepositWalletOwner);
            coreDepositWallet.enableDex(_destinationDex);
        }
    }

    // Disable destinationDex if enabled
    function _disableDestinationDex(uint32 _destinationDex) internal {
        if (coreDepositWallet.enabledDestinationDexes(_destinationDex)) {
            vm.prank(coreDepositWalletOwner);
            coreDepositWallet.disableDex(_destinationDex);
        }
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
            newTokenSystemAddress,
            TOKEN_MESSENGER
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
        new CoreDepositWallet(address(0), TOKEN_SYSTEM_ADDRESS, TOKEN_MESSENGER);
    }

    function testConstructor_revertsIfTokenSystemAddressIsZeroAddress() public {
        vm.expectRevert("Invalid _tokenSystemAddress: zero address");
        new CoreDepositWallet(TOKEN, address(0), TOKEN_MESSENGER);
    }

    function testConstructor_revertsIfTokenMessengerAddressIsZeroAddress() public {
        vm.expectRevert("Invalid tokenMessengerAddress: zero address");
        new CoreDepositWallet(TOKEN, TOKEN_SYSTEM_ADDRESS, address(0));
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

    function testDeposit_succeeds(uint256 _amount, address _sender, uint32 destinationDex) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(_sender != address(0));
        vm.assume(destinationDex != SPOT_DEX_ID);

        uint64 coreScaledAmount = uint64(_amount * 100); // scaled core amount

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, _amount);
        _enableDestinationDex(destinationDex);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Check that the SendRawAction event was emitted from CoreWriter
        bytes memory expectedData = _buildCoreWriterAction(_sender, _amount, destinationDex);

        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Expect SendAsset event with scaled amount
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledAmount, destinationDex);

        vm.startPrank(_sender);
        // Deposit tokens into the CoreDepositWallet
        coreDepositWallet.deposit(_amount, destinationDex);
        vm.stopPrank();

        // Check the balance of the CoreDepositWallet
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            _amount
        );
    }

    function testDeposit_succeedsWithMaxTransferAmount(address _sender, uint32 destinationDex) public {
        vm.assume(_sender != address(0));
        uint64 coreScaledAmount = uint64(MAX_TRANSFER_VALUE_FROM_EVM * 100); // scaled core amount
        vm.assume(destinationDex != SPOT_DEX_ID);

        // Arrange
        _setupTokenMintAndApprove(_sender, MAX_TRANSFER_VALUE_FROM_EVM);
        _enableDestinationDex(destinationDex);

        // Expect Transfer and CoreWriter action
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(coreDepositWallet), TOKEN_SYSTEM_ADDRESS, MAX_TRANSFER_VALUE_FROM_EVM);

        bytes memory expectedData = _buildCoreWriterAction(_sender, MAX_TRANSFER_VALUE_FROM_EVM, destinationDex);
        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Expect SendAsset event with scaled amount
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledAmount, destinationDex);

        // Act
        vm.startPrank(_sender);
        coreDepositWallet.deposit(MAX_TRANSFER_VALUE_FROM_EVM, destinationDex);
        vm.stopPrank();

        // Assert balance
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            MAX_TRANSFER_VALUE_FROM_EVM
        );
    }

    function testDeposit_depositsToSpotIfDexForwardingDisabled(uint256 _amount, address _sender, uint32 destinationDex) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(_sender != address(0));
        vm.assume(destinationDex != SPOT_DEX_ID);

        // Disable dex forwarding
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.disableDexForwarding();

        // Enable specified dex
        _enableDestinationDex(destinationDex);

        // Validate dex forwarding is disabled, and specified is enabled
        assertTrue(coreDepositWallet.isDexForwardingDisabled());
        assertTrue(coreDepositWallet.enabledDestinationDexes(destinationDex));

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, _amount);
        vm.startPrank(_sender);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(_sender),
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Start recording logs.
        vm.recordLogs();

        // Deposit tokens into the CoreDepositWallet
        coreDepositWallet.deposit(_amount, destinationDex);
        vm.stopPrank();

        _assertSuccessfulDepositToSpot(_amount);
    }

    function testDeposit_depositsToSpotIfDexIsSpot(address _sender, uint256 _amount) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(_sender != address(0));

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, _amount);
        vm.startPrank(_sender);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(_sender),
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Start recording logs.
        vm.recordLogs();

        // Deposit tokens into the CoreDepositWallet
        coreDepositWallet.deposit(_amount, SPOT_DEX_ID);
        vm.stopPrank();

        _assertSuccessfulDepositToSpot(_amount);
    }

    function testDeposit_depositsToSpotIfDexIsDisabled(uint256 _amount, address _sender, uint32 disabledDex) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(_sender != address(0));

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, _amount);
        // Disable the specified dex
        _disableDestinationDex(disabledDex);

        vm.startPrank(_sender);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(_sender),
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Start recording logs.
        vm.recordLogs();

        // Deposit tokens into the CoreDepositWallet
        coreDepositWallet.deposit(_amount, disabledDex);
        vm.stopPrank();

        _assertSuccessfulDepositToSpot(_amount);
    }

    function testDeposit_revertsOnTransferAmountTooLarge(
        uint256 _amount,
        address _sender,
        uint32 destinationDex
    ) public {
        _amount = bound(
            _amount,
            MAX_TRANSFER_VALUE_FROM_EVM + 1,
            type(uint256).max
        );
        vm.assume(_sender != address(0));

        // Enable destination dex
        _enableDestinationDex(destinationDex);

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Approve the CoreDepositWallet to spend the tokens
        vm.startPrank(_sender);
        MockDepositableToken(TOKEN).approve(
            address(coreDepositWallet),
            _amount
        );

        vm.expectRevert("Amount exceeds max transfer value from EVM");
        coreDepositWallet.deposit(_amount, destinationDex);
        vm.stopPrank();
    }

    function testDeposit_revertsWhenTransferFails(
        uint256 _amount,
        address _sender,
        uint32 destinationDex
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(destinationDex != SPOT_DEX_ID);

        // Enable destination dex
        _enableDestinationDex(destinationDex);

        vm.prank(_sender);
        vm.mockCall(
            address(TOKEN),
            abi.encodeWithSelector(MockMintBurnToken.transferFrom.selector),
            abi.encode(false)
        );

        vm.assume(_amount > 0);
        vm.expectRevert("Transfer operation failed");
        coreDepositWallet.deposit(_amount, destinationDex);
    }

    function testDeposit_revertsWhenPaused(uint256 _amount, uint32 destinationDex) public {
        vm.assume(_amount > 0);

        vm.prank(coreDepositWalletPauser);
        coreDepositWallet.pause();
        assertTrue(coreDepositWallet.paused());

        vm.expectRevert("Pausable: paused");
        coreDepositWallet.deposit(_amount, destinationDex);
    }

    function testDeposit_revertsWithZeroAmount(uint32 destinationDex) public {
        vm.expectRevert("Amount must be greater than zero");
        coreDepositWallet.deposit(0, destinationDex);
    }

    function testDepositFor_succeeds(
        address _sender,
        address _recipient,
        uint256 _amount,
        uint32 destinationDex
    ) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));
        vm.assume(destinationDex != SPOT_DEX_ID);

        uint64 coreScaledAmount = uint64(_amount * 100); // scaled core amount

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, _amount);
        _enableDestinationDex(destinationDex);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Check that the SendRawAction event was emitted from CoreWriter
        bytes memory expectedData = _buildCoreWriterAction(_recipient, _amount, destinationDex);

        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Expect SendAsset event with scaled amount
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_recipient, coreScaledAmount, destinationDex);

        vm.startPrank(_sender);
        // Deposit tokens into the CoreDepositWallet
        coreDepositWallet.depositFor(_recipient, _amount, destinationDex);
        vm.stopPrank();

        // Check the balance of the CoreDepositWallet
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            _amount
        );
    }

    function testDepositFor_succeedsWithMaxTransferAmount(
        address _sender,
        address _recipient,
        uint32 destinationDex
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));
        vm.assume(destinationDex != SPOT_DEX_ID);

        // Arrange
        _setupTokenMintAndApprove(_sender, MAX_TRANSFER_VALUE_FROM_EVM);
        _enableDestinationDex(destinationDex);

        // Expect Transfer and CoreWriter action
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(coreDepositWallet), TOKEN_SYSTEM_ADDRESS, MAX_TRANSFER_VALUE_FROM_EVM);

        bytes memory expectedData = _buildCoreWriterAction(_recipient, MAX_TRANSFER_VALUE_FROM_EVM, destinationDex);
        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Act
        vm.startPrank(_sender);
        coreDepositWallet.depositFor(_recipient, MAX_TRANSFER_VALUE_FROM_EVM, destinationDex);
        vm.stopPrank();

        // Assert balance
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            MAX_TRANSFER_VALUE_FROM_EVM
        );
    }

    function testDepositFor_depositsToSpotIfDexForwardingDisabled(address _sender, address _recipient, uint256 _amount, uint32 destinationDex) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));
        vm.assume(destinationDex != SPOT_DEX_ID);

        // Disable dex forwarding
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.disableDexForwarding();

        // Enable specified destination dex
        _enableDestinationDex(destinationDex);

        // Validate dex forwarding is disabled, and specified destination dex is enabled
        assertTrue(coreDepositWallet.isDexForwardingDisabled());
        assertTrue(coreDepositWallet.enabledDestinationDexes(destinationDex));

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, _amount);
        vm.startPrank(_sender);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            _recipient,
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Start recording logs.
        vm.recordLogs();

        // Deposit tokens into the CoreDepositWallet
        coreDepositWallet.depositFor(_recipient, _amount, destinationDex);
        vm.stopPrank();

        _assertSuccessfulDepositToSpot(_amount);
    }

    function testDepositFor_depositsToSpotIfDexIsSpot(address _sender, address _recipient, uint256 _amount) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
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
            _recipient,
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Start recording logs.
        vm.recordLogs();

        // Deposit tokens into the CoreDepositWallet
        coreDepositWallet.depositFor(_recipient, _amount, SPOT_DEX_ID);
        vm.stopPrank();

        _assertSuccessfulDepositToSpot(_amount);
    }

    function testDepositFor_depositsToSpotIfDexIsDisabled(address _sender, address _recipient, uint256 _amount, uint32 disabledDex) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));

        // Disable the specified dex
        _disableDestinationDex(disabledDex);

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, _amount);
        vm.startPrank(_sender);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            _recipient,
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Start recording logs.
        vm.recordLogs();

        // Deposit tokens into the CoreDepositWallet
        coreDepositWallet.depositFor(_recipient, _amount, disabledDex);
        vm.stopPrank();

        _assertSuccessfulDepositToSpot(_amount);
    }

    function testDepositFor_revertsOnTransferAmountTooLarge(
        uint256 _amount,
        address _sender,
        address _recipient,
        uint32 _destinationDex
    ) public {
        _amount = bound(
            _amount,
            MAX_TRANSFER_VALUE_FROM_EVM + 1,
            type(uint256).max
        );
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));
        vm.assume(_destinationDex != SPOT_DEX_ID);

        // Enable destination dex
        _enableDestinationDex(_destinationDex);

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Approve the CoreDepositWallet to spend the tokens
        vm.startPrank(_sender);
        MockDepositableToken(TOKEN).approve(
            address(coreDepositWallet),
            _amount
        );

        // Expect revert due to SafeCast overflow
        vm.expectRevert("Amount exceeds max transfer value from EVM");
        coreDepositWallet.depositFor(_recipient, _amount, _destinationDex);
        vm.stopPrank();
    }

    function testDepositFor_revertsWhenTransferFails(
        address _sender,
        address _recipient,
        uint256 _amount,
        uint32 _destinationDex
    ) public {
        vm.assume(_amount > 0);
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

        vm.expectRevert("Transfer operation failed");
        coreDepositWallet.depositFor(_recipient, _amount, _destinationDex);
    }

    function testDepositFor_revertsWhenRecipientIsZeroAddress(
        address _sender,
        uint256 _amount,
        uint32 _destinationDex
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(_amount > 0);

        vm.prank(_sender);
        vm.expectRevert("Invalid recipient: zero address");
        coreDepositWallet.depositFor(address(0), _amount, _destinationDex);
    }

    function testDepositFor_revertsWhenRecipientIsSystemAddress(
        address _sender,
        uint256 _amount,
        uint32 _destinationDex
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(_amount > 0);

        vm.prank(_sender);
        vm.expectRevert("Invalid recipient: system address");
        coreDepositWallet.depositFor(TOKEN_SYSTEM_ADDRESS, _amount, _destinationDex);
    }

    function testDepositFor_revertsWhenRecipientIsCoreDepositWallet(
        address _sender,
        uint256 _amount,
        uint32 _destinationDex
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(_amount > 0);

        vm.prank(_sender);
        vm.expectRevert("Invalid recipient: CoreDepositWallet");
        coreDepositWallet.depositFor(address(coreDepositWallet), _amount, _destinationDex);
    }

    function testDepositFor_revertsWhenRecipientBlocklisted(
        address _sender,
        address _recipient,
        uint256 _amount,
        uint32 _destinationDex
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(_amount > 0);
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));

        MockDepositableToken(TOKEN).blacklist(_recipient);

        vm.prank(_sender);
        vm.expectRevert("Invalid recipient: blacklisted");
        coreDepositWallet.depositFor(_recipient, _amount, _destinationDex);
    }

    function testDepositFor_revertsWhenPaused(
        address _sender,
        address _recipient,
        uint256 _amount,
        uint32 _destinationDex
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_amount > 0);

        vm.prank(coreDepositWalletPauser);
        coreDepositWallet.pause();
        assertTrue(coreDepositWallet.paused());

        vm.prank(_sender);
        vm.expectRevert("Pausable: paused");
        coreDepositWallet.depositFor(_recipient, _amount, _destinationDex);
    }

    function testDepositFor_revertsWithZeroAmount(
        address sender,
        address recipient,
        uint32 _destinationDex
    ) public {
        vm.assume(recipient != address(0));
        vm.assume(recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(recipient != address(coreDepositWallet));

        vm.prank(sender);
        vm.expectRevert("Amount must be greater than zero");
        coreDepositWallet.depositFor(recipient, 0, _destinationDex);
    }

    function testDepositWithAuth_succeeds(
        uint256 _amount,
        address _sender,
        uint32 _destinationDex
    ) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(_sender != address(0));
        vm.assume(_destinationDex != SPOT_DEX_ID);

        uint64 coreScaledAmount = uint64(_amount * 100); // scaled core amount

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);
        _enableDestinationDex(_destinationDex);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            address(coreDepositWallet),
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Check that the SendRawAction event was emitted from CoreWriter
        bytes memory expectedData = _buildCoreWriterAction(_sender, _amount, _destinationDex);

        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Expect SendAsset event with scaled amount
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledAmount, _destinationDex);

        // Deposit tokens into the CoreDepositWallet
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            _amount,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("s"),
            bytes32("v"),
            _destinationDex
        );

        // Check the balance of the CoreDepositWallet
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            _amount
        );
    }

    function testDepositWithAuth_succeedsWithMaxUint64Amount(
        address _sender,
        uint32 _destinationDex
    ) public {
        uint256 amount = MAX_TRANSFER_VALUE_FROM_EVM; // Max amount before scaling overflow
        vm.assume(_sender != address(0));
        vm.assume(_destinationDex != SPOT_DEX_ID);
        uint64 coreScaledAmount = uint64(amount * 100); // scaled core amount
        // Arrange (token is pulled via receiveWithAuthorization)
        MockDepositableToken(TOKEN).mint(_sender, amount);
        _enableDestinationDex(_destinationDex);

        // Expect Transfer and CoreWriter action
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(coreDepositWallet), TOKEN_SYSTEM_ADDRESS, amount);

        bytes memory expectedData = _buildCoreWriterAction(_sender, amount, _destinationDex);
        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Expect SendAsset event with scaled amount
        vm.expectEmit(true, true, true, true);
        emit SendAsset(_sender, coreScaledAmount, _destinationDex);

        // Act
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            amount,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("r"),
            bytes32("s"),
            _destinationDex
        );

        // Assert balance
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            amount
        );
    }

    function testDepositWithAuth_revertsOnTransferAmountTooLarge(
        uint256 _amount,
        address _sender,
        uint32 _destinationDex
    ) public {
        _amount = bound(
            _amount,
            MAX_TRANSFER_VALUE_FROM_EVM + 1,
            type(uint256).max
        );

        vm.assume(_sender != address(0));

        _enableDestinationDex(_destinationDex);

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Expect revert due to SafeCast overflow
        vm.prank(_sender);
        vm.expectRevert("Amount exceeds max transfer value from EVM");
        coreDepositWallet.depositWithAuth(
            _amount,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("r"),
            bytes32("s"),
            _destinationDex
        );
    }

    function testDepositWithAuth_revertsWhenPaused(
        uint256 _amount,
        address _sender,
        uint32 _destinationDex
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
            bytes32("v"),
            _destinationDex
        );
    }

    function testDepositWithAuth_revertsWithZeroAmount(address _sender, uint32 _destinationDex) public {
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
            bytes32("v"),
            _destinationDex
        );
    }

    function testDepositWithAuth_revertsWhenReceiveFails(
        uint256 _amount,
        address _sender,
        uint32 _destinationDex
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
            bytes32("v"),
            _destinationDex
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

    // ============ coreReceiveWithData Tests ============

    function testCoreReceiveWithData_succeeds(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        _amount = bound(_amount, CCTP_DEFAULT_FORWARD_FEE + 1, type(uint256).max);

        // Check that the CrossChainWithdraw event was emitted
        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        // Expect exact depositForBurn calldata
        bytes memory expectedHook = _buildExpectedHook(true, _from, _nonce, hex"");
        bytes memory depositForBurnCall = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            CCTP_DEFAULT_FORWARD_FEE,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        
        vm.mockCall(TOKEN_MESSENGER, depositForBurnCall, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, depositForBurnCall, uint64(1));

        // Transfer tokens via depositForBurn
        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, "");
    }

    function testCoreReceiveWithData_succeedsWithData(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        _amount = bound(_amount, CCTP_MAX_FEE + 1, type(uint256).max);
        bytes memory _data = hex"01020304";

        // Check that the CrossChainWithdraw event was emitted
        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        // Expect exact depositForBurn calldata
        bytes memory expectedHook = _buildExpectedHook(false, _from, _nonce, _data);
        bytes memory depositForBurnCall = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            CCTP_MAX_FEE,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        
        vm.mockCall(TOKEN_MESSENGER, depositForBurnCall, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, depositForBurnCall, uint64(1));

        // Transfer tokens via depositForBurn
        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, _data);
    }

    function testCoreReceiveWithData_succeedsWithNonDefaultForwardFee(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        uint256 customForwardFee = 2 * CCTP_DEFAULT_FORWARD_FEE;
        _amount = bound(_amount, customForwardFee + 1, type(uint256).max);

        // Modify CoreDepositWallet to use custom forward fee for this test
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpForwardFee(_destinationChainId, customForwardFee);

        // Check that the CrossChainWithdraw event was emitted
        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        // Expect exact depositForBurn calldata
        bytes memory expectedHook = _buildExpectedHook(true, _from, _nonce, hex"");
        bytes memory depositForBurnCall = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            customForwardFee,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        
        vm.mockCall(TOKEN_MESSENGER, depositForBurnCall, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, depositForBurnCall, uint64(1));

        // Transfer tokens via depositForBurn
        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, "");
    }

    function testCoreReceiveWithData_succeedsWithZeroForwardFee(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        _amount = bound(_amount, 1, type(uint256).max);

        // Modify CoreDepositWallet to use zero forward fee for this test
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpForwardFee(_destinationChainId, 0);

        // Check that the CrossChainWithdraw event was emitted
        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        // Expect exact depositForBurn calldata
        bytes memory expectedHook = _buildExpectedHook(true, _from, _nonce, hex"");
        bytes memory depositForBurnCall = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            0,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        
        vm.mockCall(TOKEN_MESSENGER, depositForBurnCall, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, depositForBurnCall, uint64(1));

        // Transfer tokens via depositForBurn
        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, "");
    }

    function testCoreReceiveWithData_succeedsWithNonDefaultForwardAndMaxFee(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        uint256 customMaxFee = 100;
        uint256 customForwardFee = 2 * CCTP_DEFAULT_FORWARD_FEE;
        _amount = bound(_amount, customMaxFee + customForwardFee + 1, type(uint256).max);

        // Modify CoreDepositWallet to use custom forward and max fee for this test
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpForwardFee(_destinationChainId, customForwardFee);

        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpMaxFee(customMaxFee);

        // Check that the CrossChainWithdraw event was emitted
        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        // Expect exact depositForBurn calldata
        bytes memory expectedHook = _buildExpectedHook(true, _from, _nonce, hex"");
        bytes memory depositForBurnCall = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            customForwardFee + customMaxFee,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        
        vm.mockCall(TOKEN_MESSENGER, depositForBurnCall, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, depositForBurnCall, uint64(1));

        // Transfer tokens via depositForBurn
        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, "");
    }

    function testCoreReceiveWithData_revertsWhenSenderIsNotSystemAddress(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount
    ) public {
        vm.assume(_from != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_from != address(0));
        _amount = bound(_amount, CCTP_DEFAULT_FORWARD_FEE + 1, type(uint256).max);

        // Attempt to call coreReceiveWithData from non-system address
        vm.prank(_from);
        vm.expectRevert("Caller is not the system address");
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, uint64(0), "");
    }

    function testCoreReceiveWithData_revertsWhenTokenApprovalFails(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount
    ) public {
        vm.assume(_from != address(0));
        _amount = bound(_amount, CCTP_DEFAULT_FORWARD_FEE + 1, type(uint256).max);

        // Mock token approval failure
        bytes memory approvalCall = abi.encodeWithSignature(
            "approve(address,uint256)",
            TOKEN_MESSENGER,
            _amount
        );
        vm.mockCall(TOKEN, approvalCall, abi.encode(false));

        // Attempt to call coreReceiveWithData from non-system address
        vm.prank(TOKEN_SYSTEM_ADDRESS);
        vm.expectRevert("Token approval failed");
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, uint64(0), "");
    }

    function testCoreReceiveWithData_revertsWhenAmountIsLessThanMaxFee(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount
    ) public {
        vm.assume(_from != address(0));
        _amount = bound(_amount, 0, CCTP_DEFAULT_FORWARD_FEE);

        // Attempt to call coreReceiveWithData with insufficient amount
        vm.prank(TOKEN_SYSTEM_ADDRESS);
        vm.expectRevert("Amount must exceed maxFee");
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, uint64(0), "");
    }

    function testCoreReceiveWithData_revertsWhenPaused(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount
    ) public {
        vm.assume(_from != address(0));
       _amount = bound(_amount, CCTP_DEFAULT_FORWARD_FEE + 1, type(uint256).max);

        vm.prank(coreDepositWalletPauser);
        coreDepositWallet.pause();
        assertTrue(coreDepositWallet.paused());

        // Attempt to call coreReceiveWithData when paused
        vm.prank(TOKEN_SYSTEM_ADDRESS);
        vm.expectRevert("Pausable: paused");
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, uint64(0), "");
    }

    function testCoreReceiveWithData_dataEqualsMagicBytes_includesForwardFeeAndEmbedsProvidedData(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        bytes memory userData = abi.encodePacked(CCTP_FORWARD_HOOK_MAGIC_BYTES);

        _amount = bound(_amount, CCTP_DEFAULT_FORWARD_FEE + 1, type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        bytes memory expectedHook = _buildExpectedHook(true, _from, _nonce, userData);
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            CCTP_DEFAULT_FORWARD_FEE,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        vm.mockCall(TOKEN_MESSENGER, expected, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, userData);
    }

    function testCoreReceiveWithData_startsWithMagicBytes_includesForwardFeeAndEmbedsProvidedData(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        bytes memory userData = abi.encodePacked(CCTP_FORWARD_HOOK_MAGIC_BYTES, hex"010203");

        _amount = bound(_amount, CCTP_DEFAULT_FORWARD_FEE + 1, type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        bytes memory expectedHook = _buildExpectedHook(true, _from, _nonce, userData);
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            CCTP_DEFAULT_FORWARD_FEE,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        vm.mockCall(TOKEN_MESSENGER, expected, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, userData);
    }

    function testCoreReceiveWithData_magicBytesWithFeeOverride_usesOverrideForwardFee(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        bytes memory userData = abi.encodePacked(CCTP_FORWARD_HOOK_MAGIC_BYTES, hex"99");
        uint256 overrideForward = 2 * CCTP_DEFAULT_FORWARD_FEE;

        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpForwardFee(_destinationChainId, overrideForward);

        _amount = bound(_amount, overrideForward + 1, type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        bytes memory expectedHook = _buildExpectedHook(true, _from, _nonce, userData);
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            overrideForward, // CCTP_MAX_FEE is 0; override forward fee applies
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        vm.mockCall(TOKEN_MESSENGER, expected, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, userData);
    }

    function testCoreReceiveWithData_shortData_excludesAdditionalFee_buildsZeroMagicHook(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        bytes memory shortData = hex"01";
        _amount = bound(_amount, CCTP_MAX_FEE + 1, type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        bytes memory expectedHook = _buildExpectedHook(false, _from, _nonce, shortData);
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            CCTP_MAX_FEE,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        vm.mockCall(TOKEN_MESSENGER, expected, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, shortData);
    }

    function testCoreReceiveWithData_magicData_withNonZeroMaxFee_addsDefaultPlusMax(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        uint256 newMaxFee = 777;
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpMaxFee(newMaxFee);
        bytes memory userData = abi.encodePacked(CCTP_FORWARD_HOOK_MAGIC_BYTES, hex"AB");
        _amount = bound(_amount, newMaxFee + CCTP_DEFAULT_FORWARD_FEE + 1, type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        bytes memory expectedHook = _buildExpectedHook(true, _from, _nonce, userData);
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            newMaxFee + CCTP_DEFAULT_FORWARD_FEE,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        vm.mockCall(TOKEN_MESSENGER, expected, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, userData);
    }

    function testCoreReceiveWithData_revertsWhenAmountEqualsMaxFee(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId
    ) public {
        vm.assume(_from != address(0));
        uint256 _amount = CCTP_DEFAULT_FORWARD_FEE; // Amount exactly equals maxFee

        // Attempt to call coreReceiveWithData with amount equal to maxFee
        vm.prank(TOKEN_SYSTEM_ADDRESS);
        vm.expectRevert("Amount must exceed maxFee");
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, uint64(0), "");
    }

    function testCoreReceiveWithData_dataExactly24BytesButNotMagicBytes_excludesForwardFee(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        bytes memory userData = hex"deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
        _amount = bound(_amount, CCTP_MAX_FEE + 1, type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        bytes memory expectedHook = _buildExpectedHook(false, _from, _nonce, userData);
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            CCTP_MAX_FEE,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        vm.mockCall(TOKEN_MESSENGER, expected, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, userData);
    }

    function testCoreReceiveWithData_nonMagicDataWithNonZeroMaxFee_excludesForwardFee(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        uint256 newMaxFee = 50000;
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpMaxFee(newMaxFee);
        
        bytes memory userData = hex"deedbeef01";
        _amount = bound(_amount, newMaxFee + 1, type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        bytes memory expectedHook = _buildExpectedHook(false, _from, _nonce, userData);
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            newMaxFee, // Only maxFee, no forward fee
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        vm.mockCall(TOKEN_MESSENGER, expected, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, userData);
    }

    function testCoreReceiveWithData_emptyDataWithNonZeroMaxFee_includesBothFees(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        uint256 newMaxFee = 100000;
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpMaxFee(newMaxFee);
        
        _amount = bound(_amount, newMaxFee + CCTP_DEFAULT_FORWARD_FEE + 1, type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        bytes memory expectedHook = _buildExpectedHook(true, _from, _nonce, hex"");
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            newMaxFee + CCTP_DEFAULT_FORWARD_FEE,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        vm.mockCall(TOKEN_MESSENGER, expected, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, "");
    }

    function testCoreReceiveWithData_differentDestinationChains_useDifferentForwardFees(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId1,
        uint32 _destinationChainId2,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        vm.assume(_destinationChainId1 != _destinationChainId2);
        
        uint256 forwardFee1 = CCTP_DEFAULT_FORWARD_FEE;
        uint256 forwardFee2 = 3 * CCTP_DEFAULT_FORWARD_FEE;
        
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpForwardFee(_destinationChainId2, forwardFee2);
        
        _amount = bound(_amount, forwardFee2 + 1, type(uint256).max);

        // Test chain 1 with default fee
        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId1, _nonce);

        bytes memory expectedHook1 = _buildExpectedHook(true, _from, _nonce, hex"");
        bytes memory expected1 = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId1,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            forwardFee1,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook1
        );
        vm.mockCall(TOKEN_MESSENGER, expected1, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected1, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId1, _amount, _nonce, "");

        // Test chain 2 with override fee
        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId2, _nonce);

        bytes memory expectedHook2 = _buildExpectedHook(true, _from, _nonce, hex"");
        bytes memory expected2 = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId2,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            forwardFee2,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook2
        );
        vm.mockCall(TOKEN_MESSENGER, expected2, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected2, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId2, _amount, _nonce, "");
    }

    function testCoreReceiveWithData_largeNonMagicData_excludesForwardFee(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));
        // Create large data (> 24 bytes) that doesn't start with magic bytes
        // Use a pattern that's clearly not the magic bytes (0x00, 0x01, 0x02, ...)
        // Magic bytes start with 'c' (0x63), so our pattern starting with 0x00 will never match
        bytes memory largeData = new bytes(100);
        for (uint256 i = 0; i < 100; i++) {
            largeData[i] = bytes1(uint8(i % 256));
        }
        
        _amount = bound(_amount, CCTP_MAX_FEE + 1, type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        bytes memory expectedHook = _buildExpectedHook(false, _from, _nonce, largeData);
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            CCTP_MAX_FEE, // Only maxFee, no forward fee for non-magic data
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        vm.mockCall(TOKEN_MESSENGER, expected, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, largeData);
    }

    function testCoreReceiveWithData_revertsWhenDepositForBurnReverts(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount
    ) public {
        vm.assume(_from != address(0));
        _amount = bound(_amount, CCTP_DEFAULT_FORWARD_FEE + 1, type(uint256).max);
        uint64 _nonce = uint64(0);

        bytes memory expectedHook = _buildExpectedHook(true, _from, _nonce, hex"");
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            CCTP_DEFAULT_FORWARD_FEE,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        
        // Mock depositForBurnWithHook to revert
        vm.mockCallRevert(TOKEN_MESSENGER, expected, abi.encode("CCTP error"));

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        vm.expectRevert();
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, "");
    }

    function testCoreReceiveWithData_revertsWhenDataLengthEqualsMaxHookDataSize() public {
        address _from = address(0xBEEF);
        bytes32 _destinationRecipient = bytes32(uint256(0x01));
        uint32 _destinationChainId = 1;
        uint64 _nonce = 123;
        uint256 _amount = 1; // cctpMaxFee defaults to 0, so 1 is sufficient

        // Create user data that exceeds MAX_MESSAGE_BODY_SIZE
        bytes memory userData = new bytes(MAX_HOOK_DATA_SIZE);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        vm.expectRevert(bytes("Data length exceeds MAX_HOOK_DATA_SIZE"));
        coreDepositWallet.coreReceiveWithData(
            _from, _destinationRecipient, _destinationChainId, _amount, _nonce, userData
        );
    }

    function testCoreReceiveWithData_revertsWhenDataLengthExceedsMaxHookDataSize() public {
        address _from = address(0xBEEF);
        bytes32 _destinationRecipient = bytes32(uint256(0x01));
        uint32 _destinationChainId = 1;
        uint64 _nonce = 123;
        uint256 _amount = 1; // cctpMaxFee defaults to 0, so 1 is sufficient

        // Create user data that exceeds MAX_HOOK_DATA_SIZE
        bytes memory userData = new bytes(MAX_HOOK_DATA_SIZE + 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        vm.expectRevert(bytes("Data length exceeds MAX_HOOK_DATA_SIZE"));
        coreDepositWallet.coreReceiveWithData(
            _from, _destinationRecipient, _destinationChainId, _amount, _nonce, userData
        );
    }

    function testCoreReceiveWithData_allowsDataLessThanMaxHookDataSize(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce
    ) public {
        vm.assume(_from != address(0));

        // Data exactly at MAX_HOOK_DATA_SIZE should be allowed
        bytes memory userData = new bytes(MAX_HOOK_DATA_SIZE - 1); // non-magic (all zeros), so shouldForward = false

        // shouldForward = false → maxFee = CCTP_MAX_FEE
        uint256 maxFee = CCTP_MAX_FEE;
        _amount = bound(_amount, maxFee + 1, type(uint256).max);

        // Expect event from the wallet contract
        vm.expectEmit(true, true, true, true, address(coreDepositWallet));
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        // Expect exact depositForBurn calldata with shouldForward=false
        bytes memory expectedHook = _buildExpectedHook(false, _from, _nonce, userData);
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            maxFee,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        vm.mockCall(TOKEN_MESSENGER, expected, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(
            _from, _destinationRecipient, _destinationChainId, _amount, _nonce, userData
        );
    }

    function testCoreReceiveWithData_fuzzedHooks_randomData(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce,
        bytes memory _data
    ) public {
        vm.assume(_from != address(0));
        // Cap data length for test performance
        vm.assume(_data.length <= 512);

        // Derive shouldForward per CrossChainWithdrawalHookData rules
        bool shouldForward;
        if (_data.length == 0) {
            shouldForward = true;
        } else if (_data.length < 24) {
            shouldForward = false;
        } else {
            bytes memory prefix = new bytes(24);
            for (uint256 i = 0; i < 24; i++) {
                prefix[i] = _data[i];
            }
            shouldForward = keccak256(prefix) == keccak256(abi.encodePacked(bytes24("cctp-forward")));
        }

        uint256 forwardFee = shouldForward ? CCTP_DEFAULT_FORWARD_FEE : 0;
        uint256 maxFee = CCTP_MAX_FEE + forwardFee;

        // Amount must exceed the computed max fee
        _amount = bound(_amount, maxFee + 1, type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        bytes memory expectedHook = _buildExpectedHook(shouldForward, _from, _nonce, _data);
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            maxFee,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        vm.mockCall(TOKEN_MESSENGER, expected, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, _data);
    }

    function testCoreReceiveWithData_fuzzedHooks_withChainOverride(
        address _from,
        bytes32 _destinationRecipient,
        uint32 _destinationChainId,
        uint256 _amount,
        uint64 _nonce,
        bytes memory _data
    ) public {
        vm.assume(_from != address(0));
        vm.assume(_data.length <= 512);

        // Set an override forward fee for this destination
        uint256 overrideForward = 2 * CCTP_DEFAULT_FORWARD_FEE;
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpForwardFee(_destinationChainId, overrideForward);

        // Derive shouldForward
        bool shouldForward;
        if (_data.length == 0) {
            shouldForward = true;
        } else if (_data.length < 24) {
            shouldForward = false;
        } else {
            bytes memory prefix = new bytes(24);
            for (uint256 i = 0; i < 24; i++) {
                prefix[i] = _data[i];
            }
            shouldForward = keccak256(prefix) == keccak256(abi.encodePacked(bytes24("cctp-forward")));
        }

        uint256 forwardFee = shouldForward ? overrideForward : 0;
        uint256 maxFee = CCTP_MAX_FEE + forwardFee;
        _amount = bound(_amount, maxFee + 1, type(uint256).max);

        vm.expectEmit(true, true, true, true);
        emit CrossChainWithdraw(_from, _destinationRecipient, _amount, _destinationChainId, _nonce);

        bytes memory expectedHook = _buildExpectedHook(shouldForward, _from, _nonce, _data);
        bytes memory expected = abi.encodeWithSignature(
            "depositForBurnWithHook(uint256,uint32,bytes32,address,bytes32,uint256,uint32,bytes)",
            _amount,
            _destinationChainId,
            _destinationRecipient,
            address(TOKEN),
            bytes32(0),
            maxFee,
            CCTP_FINALIZED_THRESHOLD,
            expectedHook
        );
        vm.mockCall(TOKEN_MESSENGER, expected, abi.encode());
        vm.expectCall(TOKEN_MESSENGER, expected, 1);

        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.coreReceiveWithData(_from, _destinationRecipient, _destinationChainId, _amount, _nonce, _data);
    }

    // ============ calculateCrossChainWithdrawFee Tests ============
    
    function testCalculateFee_flagTrue_usesDefaultAdditionalFee() public view {
        uint32 destDomain = 999;
        uint256 fee = coreDepositWallet.calculateCrossChainWithdrawalFee(true, destDomain);
        assertEq(fee, CCTP_MAX_FEE + CCTP_DEFAULT_FORWARD_FEE, "shouldForward=true should include default additional fee");
    }

    function testCalculateFee_flagFalse_usesOnlyMaxFee() public view {
        uint32 destDomain = 999;
        uint256 fee = coreDepositWallet.calculateCrossChainWithdrawalFee(false, destDomain);
        assertEq(fee, CCTP_MAX_FEE, "shouldForward=false should use only max fee");
    }

    function testCalculateFee_flagTrue_withOverride_usesOverrideAdditionalFee() public {
        uint32 destDomain = 2002;
        uint256 overrideForward = 2 * CCTP_DEFAULT_FORWARD_FEE;
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpForwardFee(destDomain, overrideForward);
        uint256 fee = coreDepositWallet.calculateCrossChainWithdrawalFee(true, destDomain);
        assertEq(fee, CCTP_MAX_FEE + overrideForward, "override additional fee should be applied");
    }

    function testCalculateFee_flagTrue_withZeroOverride_usesZeroAdditionalFee() public {
        uint32 destDomain = 2004;
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpForwardFee(destDomain, 0);
        uint256 fee = coreDepositWallet.calculateCrossChainWithdrawalFee(true, destDomain);
        assertEq(fee, CCTP_MAX_FEE + 0, "zero override should result in zero additional fee");
    }

    function testCalculateFee_flagFalse_withNonZeroMaxFee_usesOnlyMaxFee() public {
        uint32 destDomain = 999;
        uint256 newMaxFee = 12345;
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpMaxFee(newMaxFee);
        uint256 fee = coreDepositWallet.calculateCrossChainWithdrawalFee(false, destDomain);
        assertEq(fee, newMaxFee, "shouldForward=false should use only max fee");
    }

    function testCalculateFee_flagTrue_withNonZeroMaxFee_addsDefaultAdditionalFee() public {
        uint32 destDomain = 999;
        uint256 newMaxFee = 54321;
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpMaxFee(newMaxFee);
        uint256 fee = coreDepositWallet.calculateCrossChainWithdrawalFee(true, destDomain);
        assertEq(fee, newMaxFee + CCTP_DEFAULT_FORWARD_FEE, "shouldForward=true should add default additional fee to max fee");
    }

    function testSendAssetEncoding_matchesSpec(
        address _sender,
        uint256 _amount,
        uint32 _destinationDex
    ) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);

        // Constrain to valid values that avoid scaled amount overflow
        vm.assume(_sender != address(0));
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(_destinationDex != SPOT_DEX_ID);

        _enableDestinationDex(_destinationDex);

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
        coreDepositWallet.deposit(_amount, _destinationDex);
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
                uint256(SPOT_DEX_ID),
                "sourceDex"
            );
            assertEq(uint256(destinationDex), _destinationDex, "destinationDex");
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
            uint256(c.coreTokenIndex),
            uint256(0),
            "coreTokenIndex"
        );
        assertEq(
            uint256(c.coreSpotDexId),
            uint256(SPOT_DEX_ID),
            "coreSpotDexId"
        );
        assertEq(
            uint256(c.corePerpsDexId),
            uint256(0),
            "corePerpsDexId"
        );
        assertEq(
            c.coreWriterPrecompileAddress,
            0x3333333333333333333333333333333333333333,
            "coreWriterPrecompileAddress"
        );
        assertEq(
            c.coreUserExistsPrecompileAddress,
            0x0000000000000000000000000000000000000810,
            "coreUserExistsPrecompileAddress"
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

    function testEnableDexForwarding_onlyOwner() public {
        vm.prank(address(0x999));
        vm.expectRevert("Ownable: caller is not the owner");
        coreDepositWallet.enableDexForwarding();
    }

    function testEnableDexForwarding_alreadyEnabled() public {
        vm.prank(coreDepositWalletOwner);
        vm.expectRevert("Dex forwarding already enabled");
        coreDepositWallet.enableDexForwarding();
    }

    function testEnableDexForwarding_succeeds() public {
        vm.startPrank(coreDepositWalletOwner);

        // Disable then enable
        vm.expectEmit(true, true, true, true);
        emit DexForwardingDisabled();
        coreDepositWallet.disableDexForwarding();
        assertTrue(coreDepositWallet.isDexForwardingDisabled());

        vm.expectEmit(true, true, true, true);
        emit DexForwardingEnabled();
        coreDepositWallet.enableDexForwarding();
        assertFalse(coreDepositWallet.isDexForwardingDisabled());

        vm.stopPrank();
    }

    function testDisableDexForwarding_onlyOwner() public {
        // Non-owner cannot update
        vm.prank(address(0x999));
        vm.expectRevert("Ownable: caller is not the owner");
        coreDepositWallet.disableDexForwarding();
    }

    function testDisableDexForwarding_alreadyDisabled() public {
        vm.startPrank(coreDepositWalletOwner);
        
        coreDepositWallet.disableDexForwarding();
        assertTrue(coreDepositWallet.isDexForwardingDisabled());

        vm.expectRevert("Dex forwarding already disabled");
        coreDepositWallet.disableDexForwarding();
        vm.stopPrank();
    }

    function testDisableDexForwarding_succeeds() public {
        vm.prank(coreDepositWalletOwner);
        vm.expectEmit(true, true, true, true);
        emit DexForwardingDisabled();
        coreDepositWallet.disableDexForwarding();
        assertTrue(coreDepositWallet.isDexForwardingDisabled());
    }

    function testEnableDex_onlyOwner(uint32 dex) public {
        vm.prank(address(0x999));
        vm.expectRevert("Ownable: caller is not the owner");
        coreDepositWallet.enableDex(dex);
    }

    function testEnableDex_cannotEnableSpotDex() public {
        vm.prank(coreDepositWalletOwner);
        vm.expectRevert("Cannot enable spot dex");
        coreDepositWallet.enableDex(SPOT_DEX_ID);
    }

    function testEnableDex_cannotEnableAlreadyEnabledDex(uint32 dex) public {
        vm.assume(dex != PERP_DEX_ID);
        vm.assume(dex != SPOT_DEX_ID);

        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.enableDex(dex);

        vm.prank(coreDepositWalletOwner);
        vm.expectRevert("Dex already enabled");
        coreDepositWallet.enableDex(dex); // try to enable again
    }

    function testEnableDex_succeeds(uint32 dex) public {
        vm.assume(dex != PERP_DEX_ID);
        vm.assume(dex != SPOT_DEX_ID);
        vm.prank(coreDepositWalletOwner);
        vm.expectEmit(true, true, true, true);
        emit DexEnabled(dex);
        coreDepositWallet.enableDex(dex);
    }

    function testDisableDex_onlyOwner(uint32 dex) public {
        vm.prank(address(0x999));
        vm.expectRevert("Ownable: caller is not the owner");
        coreDepositWallet.disableDex(dex);
    }

    function testDisableDex_alreadyDisabled(uint32 dex) public {
        vm.assume(dex != PERP_DEX_ID);
        vm.prank(coreDepositWalletOwner);
        vm.expectRevert("Dex already disabled");
        coreDepositWallet.disableDex(dex);
    }

    function testDisableDex_succeeds(uint32 dex) public {
        vm.assume(dex != PERP_DEX_ID); // already enabled
        vm.assume(dex != SPOT_DEX_ID); // cannot be enabled

        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.enableDex(dex);

        vm.prank(coreDepositWalletOwner);
        vm.expectEmit(true, true, true, true);
        emit DexDisabled(dex);
        coreDepositWallet.disableDex(dex);
    }

    function testDepositFor_existingUser_noFeeApplied(
        uint256 evmDepositAmount,
        uint32 destinationDex
    ) public {
        vm.assume(destinationDex != SPOT_DEX_ID);

        // Bound: 1 <= evmDepositAmount <= MAX_TRANSFER_VALUE_FROM_EVM to avoid scaling overflow
        evmDepositAmount = bound(evmDepositAmount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        uint64 scaledCoreAmount = uint64(evmDepositAmount * 100);
        address recipient = address(0x123);

        // Mock user exists (returns true)
        _mockCoreUserExists(recipient, true);

        _enableDestinationDex(destinationDex);

        // Mock token operations
        _setupTokenMintAndApprove(address(this), evmDepositAmount);

        // Expect full amount to be sent (no fee deduction)
        bytes memory expectedPayload = abi.encode(
            recipient,
            address(0),
            SPOT_DEX_ID,
            destinationDex,
            uint64(0),
            scaledCoreAmount
        );
        bytes memory expectedData = abi.encodePacked(
            uint8(0x01),
            uint24(0x00000D),
            expectedPayload
        );

        vm.expectCall(
            CORE_WRITER_PRECOMPILE_ADDRESS,
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
        emit SendAsset(recipient, scaledCoreAmount, destinationDex); // scaled core amount without any fee deduction

        coreDepositWallet.depositFor(recipient, evmDepositAmount, destinationDex);
    }

    function testDepositFor_newUser_feeApplied(
        uint256 evmDepositAmount,
        uint64 coreNewAccountFee,
        uint32 destinationDex
    ) public {
        vm.assume(destinationDex != SPOT_DEX_ID);

        (uint256 evmAmount, uint64 fee) = _boundDepositAndFee(
            evmDepositAmount,
            coreNewAccountFee
        );
        uint64 coreScaledAmount = _scaleToCore(evmAmount);
        uint64 coreNetScaledAmount = uint64(uint256(coreScaledAmount) - fee);
        address recipient = address(0x123);

        _enableDestinationDex(destinationDex);

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
            SPOT_DEX_ID,
            destinationDex,
            uint64(0),
            coreNetScaledAmount
        );
        bytes memory expectedData = abi.encodePacked(
            uint8(0x01),
            uint24(0x00000D),
            expectedPayload
        );

        vm.expectCall(
            CORE_WRITER_PRECOMPILE_ADDRESS,
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
        emit SendAsset(recipient, coreNetScaledAmount, destinationDex);

        coreDepositWallet.depositFor(recipient, evmAmount, destinationDex);
    }

    function testDepositFor_newUser_insufficientAmount_reverts(
        uint256 evmDepositAmount,
        uint64 coreFee,
        uint32 destinationDex
    ) public {
        vm.assume(destinationDex != SPOT_DEX_ID);

        _enableDestinationDex(destinationDex);

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
        coreDepositWallet.depositFor(recipient, evmDepositAmount, destinationDex);
    }

    function testDepositFor_newUser_exactFeeAmount_reverts(
        uint64 coreFee,
        uint32 destinationDex
    ) public {
        vm.assume(destinationDex != SPOT_DEX_ID);

        // Bound fee (core units) so that depositAmount = coreFee/100 is valid (>0)
        coreFee = uint64(bound(uint256(coreFee), 100, type(uint64).max));
        address recipient = address(0x123);

        _enableDestinationDex(destinationDex);

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
        coreDepositWallet.depositFor(recipient, evmDepositAmount, destinationDex);
    }

    function testDepositFor_newUser_zeroFee_noFeeLogic(
        uint256 evmDepositAmount,
        uint32 destinationDex
    ) public {
        vm.assume(destinationDex != SPOT_DEX_ID);

        _enableDestinationDex(destinationDex);

        // Bound: 1 <= evmDepositAmount <= MAX_TRANSFER_VALUE_FROM_EVM to avoid scaling overflow
        evmDepositAmount = bound(evmDepositAmount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
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
            SPOT_DEX_ID,
            destinationDex,
            uint64(0),
            coreScaledAmount
        );
        bytes memory expectedData = abi.encodePacked(
            uint8(0x01),
            uint24(0x00000D),
            expectedPayload
        );

        vm.expectCall(
            CORE_WRITER_PRECOMPILE_ADDRESS,
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
        emit SendAsset(recipient, coreScaledAmount, destinationDex);

        coreDepositWallet.depositFor(recipient, evmDepositAmount, destinationDex);
    }

    function testDeposit_existingUser_noFeeApplied(
        address _sender,
        uint256 evmDepositAmount,
        uint32 destinationDex
    ) public {
        // Bound: 1 <= evmDepositAmount <= MAX_TRANSFER_VALUE_FROM_EVM to avoid scaling overflow
        evmDepositAmount = bound(evmDepositAmount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        uint64 coreScaledAmount = uint64(evmDepositAmount * 100);
        vm.assume(_sender != address(0));
        vm.assume(destinationDex != SPOT_DEX_ID);

        // Mock user exists (returns true)
        _mockCoreUserExists(_sender, true);

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, evmDepositAmount);
        _enableDestinationDex(destinationDex);

        // Expect full amount to be sent (no fee deduction)
        bytes memory expectedData = _buildCoreWriterAction(
            _sender,
            evmDepositAmount,
            destinationDex
        );

        vm.expectCall(
            CORE_WRITER_PRECOMPILE_ADDRESS,
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
        emit SendAsset(_sender, coreScaledAmount, destinationDex);

        vm.startPrank(_sender);
        coreDepositWallet.deposit(evmDepositAmount, destinationDex);
        vm.stopPrank();
    }

    function testDeposit_newUser_feeApplied(
        address _sender,
        uint256 evmDepositAmount,
        uint64 coreFee,
        uint32 destinationDex
    ) public {
        vm.assume(_sender != address(0));
        vm.assume(destinationDex != SPOT_DEX_ID);

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

        // Enable destination dex
        _enableDestinationDex(destinationDex);

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, evmAmount);
        vm.startPrank(_sender);

        // Expect reduced core amount to be sent (after fee deduction)
        bytes memory expectedPayload = abi.encode(
            _sender,
            address(0),
            SPOT_DEX_ID,
            destinationDex,
            uint64(0),
            coreNetScaledAmount
        );
        bytes memory expectedData = abi.encodePacked(
            uint8(0x01),
            uint24(0x00000D),
            expectedPayload
        );
        vm.expectCall(
            CORE_WRITER_PRECOMPILE_ADDRESS,
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
        emit SendAsset(_sender, coreNetScaledAmount, destinationDex);

        coreDepositWallet.deposit(evmAmount, destinationDex);
        vm.stopPrank();
    }

    function testDeposit_newUser_insufficientAmount_reverts(
        address _sender,
        uint256 evmDepositAmount,
        uint64 coreFee,
        uint32 destinationDex
    ) public {
        vm.assume(destinationDex != SPOT_DEX_ID);
        vm.assume(_sender != address(0));
        // Bound fee (core units) so that there exist deposits with 100*deposit <= fee
        coreFee = uint64(bound(uint256(coreFee), 100, type(uint64).max));
        // Constrain: 1 <= depositAmount <= floor(coreFee/100)
        evmDepositAmount = bound(evmDepositAmount, 1, coreFee / 100);

        // Set up fee
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(coreFee);

        // Enable destination dex
        _enableDestinationDex(destinationDex);

        // Mock user does NOT exist (returns false)
        _mockCoreUserExists(_sender, false);

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, evmDepositAmount);
        vm.startPrank(_sender);

        // Should revert with insufficient amount
        vm.expectRevert("Amount must exceed new account fee");
        coreDepositWallet.deposit(evmDepositAmount, destinationDex);
        vm.stopPrank();
    }

    function testDeposit_newUser_exactFeeAmount_reverts(
        address _sender,
        uint64 coreFee,
        uint32 destinationDex
    ) public {
        vm.assume(destinationDex != SPOT_DEX_ID);

        // Bound fee (core units) so that depositAmount = coreFee/100 is valid
        coreFee = uint64(bound(uint256(coreFee), 100, type(uint64).max));
        vm.assume(_sender != address(0));

        // Set up fee
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(coreFee);

        // Mock user does NOT exist (returns false)
        _mockCoreUserExists(_sender, false);

        // Enable destination dex
        _enableDestinationDex(destinationDex);

        // Setup tokens for sender
        uint256 evmDepositAmount = coreFee / 100;
        _setupTokenMintAndApprove(_sender, evmDepositAmount);
        vm.startPrank(_sender);

        // Should revert when amount equals fee (no net amount)
        vm.expectRevert("Amount must exceed new account fee");
        coreDepositWallet.deposit(evmDepositAmount, destinationDex);
        vm.stopPrank();
    }

    function testDeposit_newUser_zeroFee_noFeeLogic(
        address _sender,
        uint256 evmDepositAmount,
        uint32 destinationDex
    ) public {
        // Bound: 1 <= evmDepositAmount <= MAX_TRANSFER_VALUE_FROM_EVM to avoid scaling overflow
        evmDepositAmount = bound(evmDepositAmount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        uint64 coreScaledAmount = uint64(evmDepositAmount * 100);
        uint64 coreFee = 0; // 0 USDC (core token units)
        vm.assume(_sender != address(0));
        vm.assume(destinationDex != SPOT_DEX_ID);

        // Set fee to 0 for this test
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateNewCoreAccountFee(coreFee);

        // Mock user does NOT exist (returns false)
        _mockCoreUserExists(_sender, false);

        // Setup tokens for sender
        _setupTokenMintAndApprove(_sender, evmDepositAmount);
        _enableDestinationDex(destinationDex);
        vm.startPrank(_sender);

        // Expect full amount to be sent (no fee)
        bytes memory expectedData = _buildCoreWriterAction(
            _sender,
            evmDepositAmount,
            destinationDex
        );
        vm.expectCall(
            CORE_WRITER_PRECOMPILE_ADDRESS,
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
        emit SendAsset(_sender, coreScaledAmount, destinationDex);

        coreDepositWallet.deposit(evmDepositAmount, destinationDex);
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
            SPOT_DEX_ID,
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
            CORE_WRITER_PRECOMPILE_ADDRESS,
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
        emit SendAsset(_sender, coreScaledNetAmount, PERP_DEX_ID);

        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            evmAmount,
            block.timestamp - 1,
            block.timestamp + 1000,
            bytes32(uint256(1)),
            27,
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            PERP_DEX_ID
        );
    }

    function testDepositWithAuth_existingUser_noFeeApplied(
        address _sender,
        uint256 evmDepositAmount,
        uint32 destinationDex
    ) public {
        // Bound: 1 <= evmDepositAmount <= MAX_TRANSFER_VALUE_FROM_EVM to avoid scaling overflow
        evmDepositAmount = bound(evmDepositAmount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        uint64 coreScaledAmount = uint64(evmDepositAmount * 100); // scaled core amount
        vm.assume(_sender != address(0));
        vm.assume(destinationDex != SPOT_DEX_ID);

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
        _enableDestinationDex(destinationDex);

        // Expect CoreWriter call with full amount
        bytes memory expectedData = _buildCoreWriterAction(
            _sender,
            evmDepositAmount,
            destinationDex
        );
        vm.expectCall(
            CORE_WRITER_PRECOMPILE_ADDRESS,
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
        emit SendAsset(_sender, coreScaledAmount, destinationDex);

        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            evmDepositAmount,
            block.timestamp - 1,
            block.timestamp + 1000,
            bytes32(uint256(1)),
            27,
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            destinationDex
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
            bytes32(uint256(3)),
            PERP_DEX_ID
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
            bytes32(uint256(3)),
            PERP_DEX_ID
        );
    }

    function testDepositWithAuth_newUser_zeroFee_noFeeLogic(
        address _sender,
        uint256 evmDepositAmount,
        uint32 destinationDex
    ) public {
        vm.assume(_sender != address(0));
        evmDepositAmount = bound(evmDepositAmount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(destinationDex != SPOT_DEX_ID);
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
        _enableDestinationDex(destinationDex);

        // Expect full amount
        bytes memory expectedData = _buildCoreWriterAction(
            _sender,
            evmDepositAmount,
            destinationDex
        );
        vm.expectCall(
            CORE_WRITER_PRECOMPILE_ADDRESS,
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
        emit SendAsset(_sender, coreScaledAmount, destinationDex);

        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            evmDepositAmount,
            block.timestamp - 1,
            block.timestamp + 1000,
            bytes32(uint256(1)),
            27,
            bytes32(uint256(2)),
            bytes32(uint256(3)),
            destinationDex
        );
    }

    function testDepositWithAuth_depositsToSpotIfDexForwardingDisabled(address _sender, uint256 _amount) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(_sender != address(0));

        // Disable dex forwarding
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.disableDexForwarding();

        // Validate dex forwarding is disabled, and perp dex is enabled
        assertTrue(coreDepositWallet.isDexForwardingDisabled());
        assertTrue(coreDepositWallet.enabledDestinationDexes(PERP_DEX_ID));

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            _sender,
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Start recording logs.
        vm.recordLogs();

        // Deposit tokens into the CoreDepositWallet
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            _amount,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("s"),
            bytes32("v"),
            PERP_DEX_ID
        );

        _assertSuccessfulDepositWithAuthToSpot(_amount);
    }

    function testDepositWithAuth_depositsToSpotIfDexIsSpot(address _sender, uint256 _amount) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(_sender != address(0));

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            _sender,
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Start recording logs.
        vm.recordLogs();

        // Deposit tokens into the CoreDepositWallet
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            _amount,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("s"),
            bytes32("v"),
            SPOT_DEX_ID
        );

        _assertSuccessfulDepositWithAuthToSpot(_amount);
    }

    function testDepositWithAuth_depositsToSpotIfDexIsDisabled(address _sender, uint256 _amount) public {
        _amount = bound(_amount, 1, MAX_TRANSFER_VALUE_FROM_EVM);
        vm.assume(_sender != address(0));

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(
            _sender,
            TOKEN_SYSTEM_ADDRESS,
            _amount
        );

        // Start recording logs.
        vm.recordLogs();

        // Deposit tokens into the CoreDepositWallet
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(
            _amount,
            0,
            1,
            bytes32("nonce"),
            0,
            bytes32("s"),
            bytes32("v"),
            SPOT_DEX_ID
        );

        _assertSuccessfulDepositWithAuthToSpot(_amount);
    }

    function testPrecompileCall_failure_reverts(uint256 depositAmount, uint32 destinationDex) public {
        vm.assume(destinationDex != SPOT_DEX_ID);
        
        address recipient = address(0x123);
        // Bound: 1 <= depositAmount <= MAX_TRANSFER_VALUE_FROM_EVM to avoid scaling overflow
        depositAmount = bound(depositAmount, 1, MAX_TRANSFER_VALUE_FROM_EVM);

        // Mock precompile call failure
        vm.mockCallRevert(
            CORE_USER_EXISTS_PRECOMPILE_ADDRESS,
            abi.encode(recipient),
            "Precompile error"
        );

        // Enable destination dex
        _enableDestinationDex(destinationDex);

        // Mock token operations
        _setupTokenMintAndApprove(address(this), depositAmount);

        // Should revert with precompile error
        vm.expectRevert("Core user exists precompile call failed");
        coreDepositWallet.depositFor(recipient, depositAmount, destinationDex);
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

    function testDeposit_newUser_minimalViableAmount(uint64 coreFee, uint32 destinationDex) public {
        vm.assume(destinationDex != SPOT_DEX_ID);

        // Bound fee (core units)
        uint256 maxDeposit = MAX_TRANSFER_VALUE_FROM_EVM;
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
            CORE_USER_EXISTS_PRECOMPILE_ADDRESS,
            abi.encode(recipient),
            abi.encode(false)
        );

        // Enable destination dex
        _enableDestinationDex(destinationDex);

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
        emit SendAsset(recipient, coreScaledNetAmount, destinationDex); // scaled core net amount
        coreDepositWallet.depositFor(recipient, depositAmount, destinationDex);
    }

    function testUpdateCctpForwardFee_succeeds(uint32 destinationDomain, uint256 newFee, uint256 secondNewFee) public {
        newFee = bound(newFee, 0, CCTP_FEE_LIMIT);
        secondNewFee = bound(secondNewFee, 0, CCTP_FEE_LIMIT);

        vm.expectEmit(true, true, true, true);
        emit CctpForwardFeeUpdated(destinationDomain, 0, newFee);

        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpForwardFee(destinationDomain, newFee);

        assertEq(
            uint256(coreDepositWallet.cctpForwardFees(destinationDomain)),
            uint256(newFee)
        );

        vm.expectEmit(true, true, true, true);
        emit CctpForwardFeeUpdated(destinationDomain, newFee, secondNewFee);

        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpForwardFee(destinationDomain, secondNewFee);

        assertEq(
            uint256(coreDepositWallet.cctpForwardFees(destinationDomain)),
            uint256(secondNewFee)
        );
    }

    function testUpdateCctpForwardFee_revertsWhenSenderIsNotOwner(uint32 destinationDomain, uint256 newFee) public {
        // Non-owner cannot update
        vm.prank(address(0x999));
        vm.expectRevert("Ownable: caller is not the owner");
        coreDepositWallet.updateCctpForwardFee(destinationDomain, newFee);
    }

    function testUpdateCctpForwardFee_revertsWhenFeeExceedsMax(uint32 destinationDomain, uint256 newFee) public {
        newFee = bound(newFee, CCTP_FEE_LIMIT + 1, type(uint256).max);

        vm.prank(coreDepositWalletOwner);
        vm.expectRevert("Forward fee exceeds fee limit");
        coreDepositWallet.updateCctpForwardFee(destinationDomain, newFee);
    }

    function testUnsetCctpForwardFee_succeeds(uint32 destinationDomain, uint256 initialFee) public {
        initialFee = bound(initialFee, 0, CCTP_FEE_LIMIT);

        // First set a fee
        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpForwardFee(destinationDomain, initialFee);
        assertEq(
            uint256(coreDepositWallet.cctpForwardFees(destinationDomain)),
            uint256(initialFee)
        );

        // Now unset it
        vm.expectEmit(true, true, true, true);
        emit CctpForwardFeeUpdated(destinationDomain, initialFee, 0);

        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.unsetCctpForwardFee(destinationDomain);

        assertEq(
            uint256(coreDepositWallet.cctpForwardFees(destinationDomain)),
            uint256(0)
        );
    }

    function testUnsetCctpForwardFee_revertsWhenSenderIsNotOwner(uint32 destinationDomain) public {
        // Non-owner cannot unset
        vm.prank(address(0x999));
        vm.expectRevert("Ownable: caller is not the owner");
        coreDepositWallet.unsetCctpForwardFee(destinationDomain);
    }

    function testUnsetCctpForwardFee_revertsWhenFeeNotSet(uint32 destinationDomain) public {
        // Unsetting when no fee set should revert
        vm.prank(coreDepositWalletOwner);
        vm.expectRevert("Forwarding fee not set");
        coreDepositWallet.unsetCctpForwardFee(destinationDomain);
    }
    
    function testUpdateCctpMaxFee_succeeds(uint256 newFee) public {
        newFee = bound(newFee, 0, CCTP_FEE_LIMIT);

        vm.expectEmit(true, true, true, true);
        emit CctpMaxFeeUpdated(CCTP_MAX_FEE, newFee);

        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpMaxFee(newFee);

        assertEq(
            uint256(coreDepositWallet.cctpMaxFee()),
            uint256(newFee)
        );
    }

    function testUpdateCctpMaxFee_revertsWhenFeeExceedsMax(uint256 newFee) public {
        newFee = bound(newFee, CCTP_FEE_LIMIT + 1, type(uint256).max);

        vm.prank(coreDepositWalletOwner);
        vm.expectRevert("Max fee exceeds fee limit");
        coreDepositWallet.updateCctpMaxFee(newFee);
    }

    function testUpdateCctpMaxFee_revertsWhenSenderIsNotOwner(uint256 newFee) public {
        // Non-owner cannot update
        vm.prank(address(0x999));
        vm.expectRevert("Ownable: caller is not the owner");
        coreDepositWallet.updateCctpMaxFee(newFee);
    }

    function testUpdateCctpDefaultForwardFee_succeeds(uint256 newFee) public {
        newFee = bound(newFee, 0, CCTP_FEE_LIMIT);

        vm.expectEmit(true, true, true, true);
        emit CctpDefaultForwardFeeUpdated(CCTP_DEFAULT_FORWARD_FEE, newFee);

        vm.prank(coreDepositWalletOwner);
        coreDepositWallet.updateCctpDefaultForwardFee(newFee);

        assertEq(
            uint256(coreDepositWallet.cctpDefaultForwardFee()),
            uint256(newFee)
        );
    }

    function testUpdateCctpDefaultForwardFee_revertsWhenFeeExceedsMax(uint256 newFee) public {
        newFee = bound(newFee, CCTP_FEE_LIMIT + 1, type(uint256).max);

        vm.prank(coreDepositWalletOwner);
        vm.expectRevert("Forward fee exceeds fee limit");
        coreDepositWallet.updateCctpDefaultForwardFee(newFee);
    }

    function testUpdateCctpDefaultForwardFee_revertsWhenSenderIsNotOwner(uint256 newFee) public {
        // Non-owner cannot update
        vm.prank(address(0x999));
        vm.expectRevert("Ownable: caller is not the owner");
        coreDepositWallet.updateCctpDefaultForwardFee(newFee);
    }
}
