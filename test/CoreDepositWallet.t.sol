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
import {AdminUpgradableProxy} from "@evm-cctp-contracts/proxy/AdminUpgradableProxy.sol";
import {Test} from "forge-std/Test.sol";
import {TestUtils} from "./TestUtils.sol";
import {MockCoreDepositWalletV2} from "./mocks/MockCoreDepositWalletV2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract CoreDepositWalletTest is Test, TestUtils {
    MockMintBurnToken public USDC = new MockMintBurnToken();
    CoreDepositWallet public coreDepositWalletImpl;
    CoreDepositWallet public coreDepositWallet;

    address public tokenSystemAddress = address(10);
    address public newTokenSystemAddress = address(11);

    CoreDepositWallet.CoreDepositWalletRoles roles =
        CoreDepositWallet.CoreDepositWalletRoles({owner: owner, rescuer: rescuer, pauser: pauser});

    function setUp() public {
        coreDepositWalletImpl = new CoreDepositWallet(address(USDC), tokenSystemAddress);

        AdminUpgradableProxy _proxy = new AdminUpgradableProxy(address(coreDepositWalletImpl), proxyAdmin, bytes(""));

        coreDepositWallet = CoreDepositWallet(address(_proxy));
        coreDepositWallet.initialize(roles);
    }

    // Proxy tests

    function testInitialize_revertsIfOwnerIsZeroAddress() public {
        AdminUpgradableProxy _proxy = new AdminUpgradableProxy(address(coreDepositWalletImpl), proxyAdmin, bytes(""));
        vm.expectRevert("Invalid roles.owner: zero address");
        CoreDepositWallet(address(_proxy)).initialize(
            CoreDepositWallet.CoreDepositWalletRoles({owner: address(0), rescuer: rescuer, pauser: pauser})
        );
    }

    function testInitialize_revertsIfRescuerIsZeroAddress() public {
        AdminUpgradableProxy _proxy = new AdminUpgradableProxy(address(coreDepositWalletImpl), proxyAdmin, bytes(""));
        vm.expectRevert("Rescuable: new rescuer is the zero address");
        CoreDepositWallet(address(_proxy)).initialize(
            CoreDepositWallet.CoreDepositWalletRoles({owner: owner, rescuer: address(0), pauser: pauser})
        );
    }

    function testInitialize_revertsIfPauserIsZeroAddress() public {
        AdminUpgradableProxy _proxy = new AdminUpgradableProxy(address(coreDepositWalletImpl), proxyAdmin, bytes(""));
        vm.expectRevert("Pausable: new pauser is the zero address");
        CoreDepositWallet(address(_proxy)).initialize(
            CoreDepositWallet.CoreDepositWalletRoles({owner: owner, rescuer: rescuer, pauser: address(0)})
        );
    }

    function testInitialize_setsTheOwner() public view {
        assertEq(coreDepositWallet.owner(), owner);
    }

    function testInitialize_setsTheRescuer() public view {
        assertEq(coreDepositWallet.rescuer(), rescuer);
    }

    function testInitialize_setsThePauser() public view {
        assertEq(coreDepositWallet.pauser(), pauser);
    }

    function testInitialize_canBeCalledAtomicallyByTheProxy() public {
        AdminUpgradableProxy _proxy = new AdminUpgradableProxy(
            address(coreDepositWalletImpl),
            proxyAdmin,
            abi.encodeWithSelector(CoreDepositWallet.initialize.selector, roles)
        );
        assertEq(CoreDepositWallet(address(_proxy)).owner(), owner);
        assertEq(CoreDepositWallet(address(_proxy)).rescuer(), rescuer);
        assertEq(CoreDepositWallet(address(_proxy)).pauser(), pauser);
    }

    function testInitialize_revertsIfCalledTwice() public {
        vm.expectRevert("Initializable: invalid initialization");
        coreDepositWallet.initialize(roles);
    }

    function testInitialize_revertsIfCalledOnImplementation() public {
        vm.expectRevert("Initializable: invalid initialization");
        coreDepositWalletImpl.initialize(roles);
    }

    function testUpgrade_succeeds() public {
        AdminUpgradableProxy _proxy = AdminUpgradableProxy(payable(address(coreDepositWallet)));

        // Sanity check
        assertEq(_proxy.implementation(), address(coreDepositWalletImpl));

        // Test that we can upgrade to a v2 CoreDepositWallet
        // Deploy v2 implementation
        MockCoreDepositWalletV2 _implV2 = new MockCoreDepositWalletV2(address(USDC), newTokenSystemAddress);

        // Upgrade
        vm.prank(proxyAdmin);
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
        new CoreDepositWallet(address(0), tokenSystemAddress);
    }

    function testConstructor_revertsIfTokenSystemAddressIsZeroAddress() public {
        vm.expectRevert("Invalid _tokenSystemAddress: zero address");
        new CoreDepositWallet(address(USDC), address(0));
    }

    // Ownable tests

    function testTransferOwnershipAndAcceptOwnership_succeeds(address _newOwner) public {
        vm.assume(_newOwner != coreDepositWallet.owner());
        transferOwnershipAndAcceptOwnership(address(coreDepositWallet), _newOwner);
    }

    function testTransferOwnership_revertsOnNonOwner(address _notOwner, address _newOwner) public {
        vm.assume(_notOwner != coreDepositWallet.owner());
        transferOwnershipFailsIfNotOwner(address(coreDepositWallet), _notOwner, _newOwner);
    }

    function testAcceptOwnership_revertsOnNonPendingOwner(address _newOwner, address _otherAccount) public {
        vm.assume(_newOwner != _otherAccount);
        acceptOwnershipFailsIfNotPendingOwner(address(coreDepositWallet), _newOwner, _otherAccount);
    }

    function testTransferOwnershipWithoutAcceptingThenTransferToNewOwner_succeeds(
        address _newOwner,
        address _secondNewOwner
    ) public {
        transferOwnershipWithoutAcceptingThenTransferToNewOwner(address(coreDepositWallet), _newOwner, _secondNewOwner);
    }

    // Pausable tests

    function testPausable() public {
        assertContractIsPausable(address(coreDepositWallet), pauser, address(100), owner, address(200));
    }

    // Rescuable tests

    function testRescuable() public {
        assertContractIsRescuable(address(coreDepositWallet), rescuer, address(100), 100, address(200));
    }

    function testRescueERC20_revertsIfTokenContractIsToken(address _to, uint256 _amount) public {
        vm.assume(_to != address(0));
        vm.assume(_amount > 0);

        IERC20 tokenContract = coreDepositWallet.token();
        vm.prank(rescuer);
        vm.expectRevert("Cannot rescue token");
        coreDepositWallet.rescueERC20(tokenContract, _to, _amount);
    }

    function testDeposit_revertsWhenPaused(uint256 _amount, address _pauser) public {
        vm.assume(_pauser != address(0));
        vm.assume(_amount > 0);

        vm.prank(owner);
        coreDepositWallet.updatePauser(_pauser);

        vm.prank(_pauser);
        coreDepositWallet.pause();
        assertTrue(coreDepositWallet.paused());

        vm.expectRevert("Pausable: paused");
        coreDepositWallet.deposit(_amount);
    }

    function testDeposit_revertsWithZeroAmount() public {
        vm.expectRevert("Amount must be greater than zero");
        coreDepositWallet.deposit(0);
    }

    function testDepositFor_revertsWhenPaused(address _sender, address _recipient, uint256 _amount, address _pauser)
        public
    {
        vm.assume(_pauser != address(0));
        vm.assume(_sender != address(0));
        vm.assume(_recipient != address(0));
        vm.assume(_amount > 0);

        vm.prank(owner);
        coreDepositWallet.updatePauser(_pauser);

        vm.prank(_pauser);
        coreDepositWallet.pause();
        assertTrue(coreDepositWallet.paused());

        vm.expectRevert("Pausable: paused");
        coreDepositWallet.depositFor(_sender, _recipient, _amount);
    }

    function testDepositFor_revertsWithZeroAmount(address sender, address recipient) public {
        vm.assume(recipient != address(0));
        vm.assume(recipient != tokenSystemAddress);
        vm.assume(recipient != address(coreDepositWallet));

        vm.expectRevert("Amount must be greater than zero");
        coreDepositWallet.depositFor(sender, recipient, 0);
    }

    function testTransfer_revertsWhenPaused(address _to, uint256 _amount, address _pauser) public {
        vm.assume(_pauser != address(0));
        vm.assume(_to != address(0));
        vm.assume(_amount > 0);

        vm.prank(owner);
        coreDepositWallet.updatePauser(_pauser);

        vm.prank(_pauser);
        coreDepositWallet.pause();
        assertTrue(coreDepositWallet.paused());

        vm.expectRevert("Pausable: paused");
        coreDepositWallet.transfer(_to, _amount);
    }

    function testInitialize_emitsEvents() public {
        AdminUpgradableProxy _proxy = new AdminUpgradableProxy(address(coreDepositWalletImpl), proxyAdmin, bytes(""));

        CoreDepositWallet _coreDepositWallet = CoreDepositWallet(address(_proxy));

        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(address(0), owner);

        vm.expectEmit(true, true, true, true);
        emit PauserChanged(pauser);

        vm.expectEmit(true, true, true, true);
        emit RescuerChanged(rescuer);

        _coreDepositWallet.initialize(roles);
    }
}
