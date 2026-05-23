// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {EscrowV2_1Base} from "../utils/EscrowV2_1Base.sol";

contract DevSwapEscrowV2_1FuzzTest is EscrowV2_1Base {
    function testFuzz_splitConservation(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        uint256 id = _toSubmitted(amount);
        (uint256 devNet, uint256 fee, uint256 buyback) = _expectedSplit(amount);
        assertEq(devNet + fee + buyback, amount);
        vm.prank(client);
        escrow.releaseMilestone(id, 0);
        assertEq(usdt.balanceOf(developer), devNet);
        assertEq(usdt.balanceOf(feeRecipient), fee);
        assertEq(usdt.balanceOf(address(escrow)), 0);
    }

    function testFuzz_cancelRefundsExact(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        uint256 id = _createJob(amount);
        uint256 before = usdt.balanceOf(client);
        vm.prank(client);
        escrow.cancelMilestone(id, 0);
        assertEq(usdt.balanceOf(client), before + amount);
        assertEq(usdt.balanceOf(address(escrow)), 0);
    }

    function testFuzz_multiMilestoneFundingExact(uint256 a, uint256 b, uint256 c) public {
        a = bound(a, 1, 3e23);
        b = bound(b, 1, 3e23);
        c = bound(c, 1, 3e23);
        uint256[] memory amts = new uint256[](3);
        amts[0] = a;
        amts[1] = b;
        amts[2] = c;
        uint256 id = _createJobMulti(amts);
        assertEq(usdt.balanceOf(address(escrow)), a + b + c);
        assertEq(escrow.getJob(id).milestoneCount, 3);
    }

    function testFuzz_deferredBuybackKeepsSolvency(uint256 amount) public {
        amount = bound(amount, 1, 1_000_000e18);
        uint256 id = _toSubmitted(amount);
        (uint256 devNet, uint256 fee, uint256 buyback) = _expectedSplit(amount);
        router.setShouldRevert(true);
        vm.prank(client);
        escrow.releaseMilestone(id, 0);
        assertEq(usdt.balanceOf(developer), devNet);
        assertEq(usdt.balanceOf(feeRecipient), fee);
        assertEq(escrow.buybackReserve(), buyback);
        assertEq(usdt.balanceOf(address(escrow)), buyback);
    }

    /// @dev An arbiter added after a dispute is opened is never eligible, for any positive delay.
    function testFuzz_lateArbiterNeverEligible(uint256 amount, uint256 delay) public {
        amount = bound(amount, 1, 1_000_000e18);
        delay = bound(delay, 0, 30 days);
        uint256 id = _toDisputed(amount);
        vm.warp(block.timestamp + delay);
        address late = makeAddr("late");
        _addArbiter(late); // arbiterSince > disputeRaisedAt
        vm.prank(late);
        vm.expectRevert(); // ArbiterNotEligible
        escrow.resolveDispute(id, 0, true);
    }
}
