// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {DevSwapEscrow} from "../../src/DevSwapEscrow.sol";
import {DevSwapToken} from "../../src/DevSwapToken.sol";
import {MockPancakeRouter} from "../mocks/MockPancakeRouter.sol";
import {ReentrantERC20} from "../mocks/ReentrantERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Proves the escrow resists reentrancy on the USDT transfer path using a malicious
///         token whose `transfer` re-enters the escrow. Both the ReentrancyGuard and the CEI
///         status update protect the funds (defense in depth).
contract ReentrancyTest is Test {
    DevSwapEscrow internal escrow;
    ReentrantERC20 internal usdt;
    DevSwapToken internal dswp;
    MockPancakeRouter internal router;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal client = makeAddr("client");
    address internal developer = makeAddr("developer");

    function setUp() public {
        usdt = new ReentrantERC20();
        dswp = new DevSwapToken(owner);
        router = new MockPancakeRouter();
        vm.prank(owner);
        escrow = new DevSwapEscrow(address(usdt), address(dswp), address(router), feeRecipient, owner);
        usdt.mint(client, 1_000_000e18);
    }

    function _toSubmitted(uint256 amount) internal returns (uint256 id) {
        vm.startPrank(client);
        usdt.approve(address(escrow), amount);
        id = escrow.createTask(amount, "ipfs://spec");
        vm.stopPrank();
        vm.prank(developer);
        escrow.acceptTask(id);
        vm.prank(developer);
        escrow.submitTask(id, "ipfs://delivery");
    }

    function test_Reentrancy_ReleaseFunds_Blocked() public {
        uint256 id = _toSubmitted(10_000e18);
        // arm the token to re-enter releaseFunds during the developer payout transfer
        usdt.arm(address(escrow), abi.encodeWithSelector(DevSwapEscrow.releaseFunds.selector, id));
        vm.prank(client);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        escrow.releaseFunds(id);
    }

    function test_Reentrancy_CrossFunction_CancelDuringRelease_Blocked() public {
        uint256 id = _toSubmitted(10_000e18);
        // re-enter a *different* fund-moving function: cancelTask
        usdt.arm(address(escrow), abi.encodeWithSelector(DevSwapEscrow.cancelTask.selector, id));
        vm.prank(client);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        escrow.releaseFunds(id);
    }

    function test_Reentrancy_CancelTask_Blocked() public {
        vm.startPrank(client);
        usdt.approve(address(escrow), 10_000e18);
        uint256 id = escrow.createTask(10_000e18, "ipfs://spec");
        vm.stopPrank();
        usdt.arm(address(escrow), abi.encodeWithSelector(DevSwapEscrow.cancelTask.selector, id));
        vm.prank(client);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        escrow.cancelTask(id);
    }

    function test_NoReentrancy_HappyPath_Succeeds() public {
        // sanity: with the token disarmed, the same flow settles normally
        uint256 id = _toSubmitted(10_000e18);
        vm.prank(client);
        escrow.releaseFunds(id);
        assertEq(usdt.balanceOf(developer), 9_700e18);
        assertEq(usdt.balanceOf(feeRecipient), 150e18);
        assertEq(escrow.buybackReserve(), 150e18);
    }
}
