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
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CoreDepositWalletTest is TestUtils, DeployScriptTestUtils {
    event Transfer(address indexed from, address indexed to, uint256 amount);

    event Withdraw(address to, uint256 value);

    address public newTokenSystemAddress = address(11);

    function setUp() public {
        _deployImplementations();
        _deployProxies();
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
        emit Transfer(_sender, TOKEN_SYSTEM_ADDRESS, _amount);

        // Deposit tokens into the CoreDepositWallet
        coreDepositWallet.deposit(_amount);
        vm.stopPrank();

        // Check the balance of the CoreDepositWallet
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(
                address(coreDepositWallet)
            ),
            _amount
        );
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

    function testDeposit_revertsWhenPaused(
        uint256 _amount
    ) public {
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
        emit Transfer(_recipient, TOKEN_SYSTEM_ADDRESS, _amount);

        // Deposit tokens into the CoreDepositWallet
        coreDepositWallet.depositFor(_recipient, _amount);
        vm.stopPrank();

        // Check the balance of the CoreDepositWallet
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(
                address(coreDepositWallet)
            ),
            _amount
        );
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
        vm.assume(_sender != address(0));

        // Mint tokens to the sender
        MockDepositableToken(TOKEN).mint(_sender, _amount);

        // Check that the Transfer event was emitted
        vm.expectEmit(true, true, true, true);
        emit Transfer(_sender, TOKEN_SYSTEM_ADDRESS, _amount);

        // Deposit tokens into the CoreDepositWallet
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(_amount, 0, 1, bytes32("nonce"), 0, bytes32("s"), bytes32("v"));

        // Check the balance of the CoreDepositWallet
        assertEq(
            MockDepositableToken(TOKEN).balanceOf(
                address(coreDepositWallet)
            ),
            _amount
        );
    }

    function testDepositWithAuth_revertsWhenPaused(uint256 _amount, address _sender) public {
        vm.assume(_amount > 0);
        vm.assume(_sender != address(0));

        vm.prank(coreDepositWalletPauser);
        coreDepositWallet.pause();
        assertTrue(coreDepositWallet.paused());

        vm.expectRevert("Pausable: paused");
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(_amount, 0, 1, bytes32("nonce"), 0, bytes32("s"), bytes32("v"));
    }

    function testDepositWithAuth_revertsWithZeroAmount(address _sender) public {
        vm.assume(_sender != address(0));

        vm.expectRevert("Amount must be greater than zero");
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(0, 0, 1, bytes32("nonce"), 0, bytes32("s"), bytes32("v"));
    }

    function testDepositWithAuth_revertsWhenReceiveFails(uint256 _amount, address _sender) public {
        vm.assume(_amount > 0);
        vm.assume(_sender != address(0));

        vm.mockCallRevert(
            address(TOKEN),
            abi.encodeWithSelector(MockEIP3009Token.receiveWithAuthorization.selector),
            abi.encode("revert")
        );

        vm.expectRevert();
        vm.prank(_sender);
        coreDepositWallet.depositWithAuth(_amount, 0, 1, bytes32("nonce"), 0, bytes32("s"), bytes32("v"));
    }

    function testTransfer_succeeds(address _to, uint256 _amount) public {
        vm.assume(_to != address(0));
        vm.assume(_to != TOKEN_SYSTEM_ADDRESS);
        vm.assume(_amount > 0);

        // Mint tokens to the CoreDepositWallet
        MockDepositableToken(TOKEN).mint(
            address(coreDepositWallet),
            _amount
        );

        // Check that the Withdraw event was emitted
        vm.expectEmit(true, true, true, true);
        emit Withdraw(_to, _amount);

        // Transfer tokens from the CoreDepositWallet
        vm.prank(TOKEN_SYSTEM_ADDRESS);
        coreDepositWallet.transfer(_to, _amount);

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
}
