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

import {Test} from "forge-std/Test.sol";
import {Pausable} from "@evm-cctp-contracts/roles/Pausable.sol";
import {Rescuable} from "@evm-cctp-contracts/roles/Rescuable.sol";
import {Ownable2Step} from "@evm-cctp-contracts/roles/Ownable2Step.sol";
import {MockMintBurnToken} from "lib/evm-cctp-contracts/test/mocks/MockMintBurnToken.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract TestUtils is Test {
    event OwnershipTransferred(
        address indexed previousOwner,
        address indexed newOwner
    );

    event OwnershipTransferStarted(
        address indexed previousOwner,
        address indexed newOwner
    );

    event Pause();

    event Unpause();

    event PauserChanged(address indexed newAddress);

    event RescuerChanged(address indexed newRescuer);

    event Upgraded(address indexed implementation);

    function assertContractIsPausable(
        address _pausableContractAddress,
        address _currentPauser,
        address _newPauser,
        address _owner,
        address _nonOwner
    ) public {
        vm.assume(_newPauser != address(0));
        vm.assume(_owner != _nonOwner);
        vm.assume(_currentPauser != _newPauser);

        Pausable _pausableContract = Pausable(_pausableContractAddress);
        assertEq(_pausableContract.pauser(), _currentPauser);
        assertFalse(_pausableContract.paused());

        // Check that the current pauser can pause / unpause
        vm.startPrank(_currentPauser);

        vm.expectEmit(true, true, true, true);
        emit Pause();
        _pausableContract.pause();
        assertTrue(_pausableContract.paused());

        vm.expectEmit(true, true, true, true);
        emit Unpause();
        _pausableContract.unpause();
        assertFalse(_pausableContract.paused());

        vm.stopPrank();

        // Check that a non-pauser cannot pause / unpause
        assertTrue(_newPauser != _currentPauser);
        vm.startPrank(_newPauser);

        vm.expectRevert("Pausable: caller is not the pauser");
        _pausableContract.pause();

        vm.expectRevert("Pausable: caller is not the pauser");
        _pausableContract.unpause();

        vm.stopPrank();

        // Check that a non-owner cannot rotate the pauser
        assertTrue(_nonOwner != _owner);
        vm.prank(_nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        _pausableContract.updatePauser(_newPauser);
        vm.stopPrank();

        // Check that owner can rotate pauser, and it emits an event
        vm.expectEmit(true, true, true, true);
        emit PauserChanged(_newPauser);
        vm.prank(_owner);
        _pausableContract.updatePauser(_newPauser);

        assertEq(_pausableContract.pauser(), _newPauser);
    }

    function assertContractIsRescuable(
        address _rescuableContractAddress,
        address _rescuer,
        address _rescueRecipient,
        uint256 _amount,
        address _nonRescuer
    ) public {
        Rescuable _rescuableContract = Rescuable(_rescuableContractAddress);

        vm.assume(_rescuer != address(0));
        vm.assume(_rescueRecipient != address(0));
        vm.assume(_rescuer != _nonRescuer);
        vm.assume(_nonRescuer != _rescuableContract.owner());

        // Send erc20 to _rescuableContractAddress
        MockMintBurnToken _mockMintBurnToken = new MockMintBurnToken();

        // _rescueRecipient's initial balance of _mockMintBurnToken is 0
        assertEq(_mockMintBurnToken.balanceOf(_rescueRecipient), 0);

        // Mint _mockMintBurnToken to _rescueRecipient
        _mockMintBurnToken.mint(_rescueRecipient, _amount);

        // Test updating the rescuer
        // (Updating rescuer to zero-address is not permitted)
        vm.prank(_rescuableContract.owner());
        vm.expectRevert("Rescuable: new rescuer is the zero address");
        _rescuableContract.updateRescuer(address(0));

        assertTrue(_rescuer != address(0));

        // Update rescuer to a valid address
        vm.expectEmit(true, true, true, true);
        emit RescuerChanged(_rescuer);
        vm.prank(_rescuableContract.owner());
        _rescuableContract.updateRescuer(_rescuer);

        // Check that _rescuer cannot rescue more tokens than are available
        vm.prank(_rescuer);
        vm.expectRevert("ERC20: transfer amount exceeds balance");
        _rescuableContract.rescueERC20(
            IERC20(address(_mockMintBurnToken)),
            _rescueRecipient,
            _amount
        );

        // _rescueRecipient accidentally sends _mockMintBurnToken to the _rescuableContractAddress
        vm.prank(_rescueRecipient);
        _mockMintBurnToken.transfer(_rescuableContractAddress, _amount);
        assertEq(
            _mockMintBurnToken.balanceOf(_rescuableContractAddress),
            _amount
        );

        // Rescue erc20 to _rescueRecipient
        vm.prank(_rescuer);
        _rescuableContract.rescueERC20(
            IERC20(address(_mockMintBurnToken)),
            _rescueRecipient,
            _amount
        );

        // Assert funds are rescued
        assertEq(_mockMintBurnToken.balanceOf(_rescueRecipient), _amount);

        // Check that non-rescuer address cannot rescue funds
        assertTrue(_rescuableContract.rescuer() != _nonRescuer);
        vm.prank(_nonRescuer);
        vm.expectRevert("Rescuable: caller is not the rescuer");
        _rescuableContract.rescueERC20(
            IERC20(address(_mockMintBurnToken)),
            _rescueRecipient,
            _amount
        );

        // Check that non-owner cannot update rescuer
        vm.prank(_nonRescuer);
        vm.expectRevert("Ownable: caller is not the owner");
        _rescuableContract.updateRescuer(_nonRescuer);
        vm.stopPrank();
    }

    function expectRevertWithWrongOwner(address wrongOwner) public {
        vm.prank(wrongOwner);
        vm.expectRevert("Ownable: caller is not the owner");
    }

    function transferOwnershipFailsIfNotOwner(
        address _ownableContractAddress,
        address _notOwner,
        address _newOwner
    ) public {
        Ownable2Step _ownableContract = Ownable2Step(_ownableContractAddress);
        address _initialOwner = _ownableContract.owner();
        expectRevertWithWrongOwner(_notOwner);
        _ownableContract.transferOwnership(_newOwner);

        // Sanity check
        assertEq(_initialOwner, _ownableContract.owner());
    }

    function acceptOwnershipFailsIfNotPendingOwner(
        address _ownableContractAddress,
        address _newOwner,
        address _otherAccount
    ) public {
        Ownable2Step _ownableContract = Ownable2Step(_ownableContractAddress);
        address _initialOwner = _ownableContract.owner();

        vm.prank(_initialOwner);
        _ownableContract.transferOwnership(_newOwner);
        assertEq(_ownableContract.pendingOwner(), _newOwner);

        vm.prank(_otherAccount);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        _ownableContract.acceptOwnership();

        // Sanity check
        assertEq(_initialOwner, _ownableContract.owner());
        assertEq(_newOwner, _ownableContract.pendingOwner());
    }

    function transferOwnership_revertsFromNonOwner(
        address _ownableContractAddress,
        address _newOwner,
        address _nonOwner
    ) public {
        Ownable2Step _ownableContract = Ownable2Step(_ownableContractAddress);
        address initialOwner = _ownableContract.owner();
        vm.assume(initialOwner != _nonOwner);
        vm.assume(initialOwner != _newOwner);
        vm.assume(_newOwner != _nonOwner);

        assertTrue(_nonOwner != initialOwner);

        // Test non-owner cannot transfer ownership
        vm.prank(_nonOwner);
        vm.expectRevert("Ownable: caller is not the owner");
        _ownableContract.transferOwnership(_newOwner);
        vm.stopPrank();
    }

    function acceptOwnership_revertsFromNonPendingOwner(
        address _ownableContractAddress,
        address _newOwner,
        address _nonOwner
    ) public {
        Ownable2Step _ownableContract = Ownable2Step(_ownableContractAddress);
        address _initialOwner = _ownableContract.owner();
        vm.assume(_initialOwner != _nonOwner);
        vm.assume(_initialOwner != _newOwner);
        vm.assume(_newOwner != _nonOwner);

        // First, transfer ownership
        vm.prank(_initialOwner);
        _ownableContract.transferOwnership(_newOwner);
        vm.stopPrank();
        assertEq(_ownableContract.owner(), _initialOwner);
        assertEq(_ownableContract.pendingOwner(), _newOwner);

        // Test non-pending owner cannot acceptOwnership
        vm.prank(_nonOwner);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        _ownableContract.acceptOwnership();
        vm.stopPrank();
    }

    function transferOwnershipAndAcceptOwnership(
        address _ownableContractAddress,
        address _newOwner
    ) public {
        Ownable2Step _ownableContract = Ownable2Step(_ownableContractAddress);
        address initialOwner = _ownableContract.owner();
        vm.assume(initialOwner != _newOwner);
        // assert that the owner is still unchanged
        assertEq(_ownableContract.owner(), initialOwner);

        // set pending owner
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferStarted(initialOwner, _newOwner);
        vm.prank(initialOwner);
        _ownableContract.transferOwnership(_newOwner);
        // assert that the owner is still unchanged, but pending owner is changed
        assertEq(_ownableContract.owner(), initialOwner);
        assertEq(_ownableContract.pendingOwner(), _newOwner);

        // accept ownership
        vm.prank(_newOwner);
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(initialOwner, _newOwner);
        _ownableContract.acceptOwnership();

        // assert that the owner is now _newOwner
        assertEq(_ownableContract.owner(), _newOwner);

        // sanity check owner changed
        assertFalse(_newOwner == initialOwner);
    }

    function transferOwnershipWithoutAcceptingThenTransferToNewOwner(
        address _ownableContractAddress,
        address _newOwner,
        address _secondNewOwner
    ) public {
        Ownable2Step _ownableContract = Ownable2Step(_ownableContractAddress);
        address initialOwner = _ownableContract.owner();
        vm.assume(_newOwner != address(0));
        vm.assume(
            _secondNewOwner != _newOwner &&
                _secondNewOwner != address(0) &&
                _secondNewOwner != _ownableContractAddress &&
                _secondNewOwner != initialOwner
        );
        assertEq(_ownableContract.owner(), initialOwner);

        // set pending owner
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferStarted(initialOwner, _newOwner);
        vm.prank(initialOwner);
        _ownableContract.transferOwnership(_newOwner);
        // assert that the owner is still unchanged, but pending owner is changed
        assertEq(_ownableContract.owner(), initialOwner);
        assertEq(_ownableContract.pendingOwner(), _newOwner);

        // change the owner again, because we realize _newOwner cannot accept ownership
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferStarted(initialOwner, _secondNewOwner);
        vm.prank(initialOwner);
        _ownableContract.transferOwnership(_secondNewOwner);

        // accept ownership
        vm.prank(_secondNewOwner);
        vm.expectEmit(true, true, true, true);
        emit OwnershipTransferred(initialOwner, _secondNewOwner);
        _ownableContract.acceptOwnership();

        // assert that the owner is now _secondNewOwner
        assertEq(_ownableContract.owner(), _secondNewOwner);
    }
}
