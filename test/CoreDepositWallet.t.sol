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
import {ICoreWriter} from "../src/interfaces/ICoreWriter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Vm} from "forge-std/Vm.sol";

contract CoreDepositWalletTest is TestUtils, DeployScriptTestUtils {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Withdraw(address indexed to, uint256 value);

    event SendRawAction(address indexed user, bytes data);

    address public newTokenSystemAddress = address(11);

    function setUp() public {
        _deployCreate2Factory();
        _deployMockCoreWriter();
        _deployCoreDepositWallet();
    }

    function _deployMockCoreWriter() internal {
        // Deploy MockCoreWriter at the hardcoded CoreWriter address
        address coreWriterAddress = 0x3333333333333333333333333333333333333333;
        vm.etch(coreWriterAddress, type(MockCoreWriter).runtimeCode);
    }

    // Helper functions
    function _buildCoreWriterAction(
        address sender,
        uint256 amount
    ) internal pure returns (bytes memory data) {
        bytes memory encodedAction = abi.encode(
            sender, // recipient
            address(0), // subAccount
            type(uint32).max, // SOURCE_SPOT_DEX
            uint32(0), // DESTINATION_PERP_DEX
            uint64(0), // TOKEN_INDEX
            uint64(amount) // amount as uint64
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
        vm.assume(_amount <= type(uint64).max); // Ensure amount fits in uint64
        vm.assume(_sender != address(0));

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Approve the CoreDepositWallet to spend the tokens
        vm.startPrank(_sender);
        MockDepositableToken(TOKEN).approve(
            address(coreDepositWallet),
            _amount
        );

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
        uint256 amount = type(uint64).max;
        vm.assume(_sender != address(0));

        // Arrange
        MockDepositableToken(TOKEN).mint(_sender, amount);
        vm.startPrank(_sender);
        MockDepositableToken(TOKEN).approve(address(coreDepositWallet), amount);

        // Expect Transfer and CoreWriter action
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(coreDepositWallet), TOKEN_SYSTEM_ADDRESS, amount);

        bytes memory expectedData = _buildCoreWriterAction(_sender, amount);
        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

        // Act
        coreDepositWallet.deposit(amount);
        vm.stopPrank();

        // Assert balance
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(address(coreDepositWallet)),
            amount
        );
    }

    function testDeposit_revertsOnAmountOverflow(
        uint256 _amount,
        address _sender
    ) public {
        vm.assume(_amount > type(uint64).max);
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
        vm.assume(_amount <= type(uint64).max); // Ensure amount fits in uint64
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
        uint256 amount = type(uint64).max;
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_recipient != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_recipient != address(coreDepositWallet));

        // Arrange
        MockDepositableToken(TOKEN).mint(_sender, amount);
        vm.startPrank(_sender);
        MockDepositableToken(TOKEN).approve(address(coreDepositWallet), amount);

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

    function testDepositFor_revertsOnAmountOverflow(
        uint256 _amount,
        address _sender,
        address _recipient
    ) public {
        vm.assume(_amount > type(uint64).max);
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
        vm.assume(_amount <= type(uint64).max); // Bound amount to fit in uint64 for SafeCast
        vm.assume(_sender != address(0));

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
        uint256 amount = type(uint64).max;
        vm.assume(_sender != address(0));

        // Arrange (token is pulled via receiveWithAuthorization)
        MockDepositableToken(TOKEN).mint(_sender, amount);

        // Expect Transfer and CoreWriter action
        vm.expectEmit(true, true, true, true);
        emit Transfer(address(coreDepositWallet), TOKEN_SYSTEM_ADDRESS, amount);

        bytes memory expectedData = _buildCoreWriterAction(_sender, amount);
        vm.expectEmit(true, true, true, true);
        emit SendRawAction(address(coreDepositWallet), expectedData);

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

    function testDepositWithAuth_revertsOnAmountOverflow(
        uint256 _amount,
        address _sender
    ) public {
        vm.assume(_amount > type(uint64).max);
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
        // Constrain to valid values that avoid SafeCast revert
        vm.assume(_sender != address(0));
        vm.assume(_amount > 0 && _amount <= type(uint64).max);

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
            assertEq(uint256(amount64), uint256(_amount), "amount");
        }
    }

    function testGetSendAssetConstants_returnsExpectedValues() public view {
        CoreDepositWallet.SendAssetConstants memory c = coreDepositWallet
            .getSendAssetConstants();
        assertEq(uint256(c.actionVersion), uint256(0x01), "actionVersion");
        assertEq(uint256(c.sendAssetActionId), uint256(0x00000D), "actionId");
        assertEq(uint256(c.tokenIndex), uint256(0), "tokenIndex");
        assertEq(
            uint256(c.sourceSpotDex),
            uint256(type(uint32).max),
            "sourceSpotDex"
        );
        assertEq(uint256(c.destinationPerpDex), uint256(0), "destPerpDex");
        assertEq(
            c.coreWriterAddress,
            0x3333333333333333333333333333333333333333,
            "coreWriterAddress"
        );
    }
}
