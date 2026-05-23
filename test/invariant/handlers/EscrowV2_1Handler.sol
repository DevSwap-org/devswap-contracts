// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {DevSwapEscrowV2_1} from "../../../src/DevSwapEscrowV2_1.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPancakeRouter} from "../../mocks/MockPancakeRouter.sol";

/// @notice Stateful actor for V2.1 invariant testing (single-milestone jobs). Disputes are resolved
///         by the bootstrap arbiter, which is registered at deployment (before any dispute) and is
///         therefore always eligible. Tracks `ghostLocked` = USDT owed to live milestones.
contract EscrowV2_1Handler is Test {
    DevSwapEscrowV2_1 internal escrow;
    MockERC20 internal usdt;
    MockPancakeRouter internal router;
    address internal owner;
    address internal arbiter;

    address[3] internal clients;
    address[3] internal devs;
    uint256[] internal jobIds;

    uint256 public ghostLocked;

    uint256 internal constant MAX_JOBS = 20;
    uint256 internal constant MAX_AMOUNT = 1e24;

    constructor(
        DevSwapEscrowV2_1 _escrow,
        MockERC20 _usdt,
        MockPancakeRouter _router,
        address _owner,
        address _arbiter
    ) {
        escrow = _escrow;
        usdt = _usdt;
        router = _router;
        owner = _owner;
        arbiter = _arbiter;
        clients = [makeAddr("c0"), makeAddr("c1"), makeAddr("c2")];
        devs = [makeAddr("d0"), makeAddr("d1"), makeAddr("d2")];
    }

    function _findJob(DevSwapEscrowV2_1.JobStatus s, uint256 seed) internal view returns (bool, uint256) {
        uint256 n = jobIds.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = jobIds[(seed + i) % n];
            if (escrow.getJob(id).status == s) return (true, id);
        }
        return (false, 0);
    }

    function _findMilestone(DevSwapEscrowV2_1.MilestoneStatus s, uint256 seed) internal view returns (bool, uint256) {
        uint256 n = jobIds.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = jobIds[(seed + i) % n];
            if (escrow.getMilestone(id, 0).status == s) return (true, id);
        }
        return (false, 0);
    }

    function createJob(uint256 amount, uint256 seed) external {
        if (jobIds.length >= MAX_JOBS) return;
        amount = bound(amount, 1, MAX_AMOUNT);
        address c = clients[seed % 3];
        usdt.mint(c, amount);
        uint256[] memory amts = new uint256[](1);
        amts[0] = amount;
        vm.startPrank(c);
        usdt.approve(address(escrow), amount);
        uint256 id = escrow.createJob(amts, "");
        vm.stopPrank();
        jobIds.push(id);
        ghostLocked += amount;
    }

    function acceptJob(uint256 seed, uint256 dseed) external {
        (bool ok, uint256 id) = _findJob(DevSwapEscrowV2_1.JobStatus.Open, seed);
        if (!ok) return;
        vm.prank(devs[dseed % 3]);
        escrow.acceptJob(id);
    }

    function submitMilestone(uint256 seed) external {
        (bool ok, uint256 id) = _findJob(DevSwapEscrowV2_1.JobStatus.Accepted, seed);
        if (!ok) return;
        if (escrow.getMilestone(id, 0).status != DevSwapEscrowV2_1.MilestoneStatus.Funded) return;
        vm.prank(escrow.getJob(id).developer);
        escrow.submitMilestone(id, 0, "");
    }

    function releaseMilestone(uint256 seed) external {
        (bool ok, uint256 id) = _findMilestone(DevSwapEscrowV2_1.MilestoneStatus.Submitted, seed);
        if (!ok) return;
        uint256 amt = escrow.getMilestone(id, 0).amount;
        router.setShouldRevert(false);
        router.setRate(1, 1);
        vm.prank(escrow.getJob(id).client);
        escrow.releaseMilestone(id, 0);
        ghostLocked -= amt;
    }

    function claimMilestone(uint256 seed, uint256 dt) external {
        (bool ok, uint256 id) = _findMilestone(DevSwapEscrowV2_1.MilestoneStatus.Submitted, seed);
        if (!ok) return;
        uint256 amt = escrow.getMilestone(id, 0).amount;
        vm.warp(block.timestamp + escrow.reviewTimeout() + bound(dt, 1, 10 days));
        router.setShouldRevert(false);
        router.setRate(1, 1);
        vm.prank(escrow.getJob(id).developer);
        escrow.claimMilestone(id, 0);
        ghostLocked -= amt;
    }

    function cancelOpen(uint256 seed) external {
        (bool ok, uint256 id) = _findJob(DevSwapEscrowV2_1.JobStatus.Open, seed);
        if (!ok) return;
        uint256 amt = escrow.getMilestone(id, 0).amount;
        vm.prank(escrow.getJob(id).client);
        escrow.cancelMilestone(id, 0);
        ghostLocked -= amt;
    }

    function cancelTimedOut(uint256 seed, uint256 dt) external {
        (bool ok, uint256 id) = _findJob(DevSwapEscrowV2_1.JobStatus.Accepted, seed);
        if (!ok) return;
        if (escrow.getMilestone(id, 0).status != DevSwapEscrowV2_1.MilestoneStatus.Funded) return;
        vm.warp(block.timestamp + escrow.submitTimeout() + bound(dt, 1, 10 days));
        uint256 amt = escrow.getMilestone(id, 0).amount;
        vm.prank(escrow.getJob(id).client);
        escrow.cancelMilestone(id, 0);
        ghostLocked -= amt;
    }

    function dispute(uint256 seed, uint256 who) external {
        (bool ok, uint256 id) = _findMilestone(DevSwapEscrowV2_1.MilestoneStatus.Submitted, seed);
        if (!ok) (ok, id) = _findMilestone(DevSwapEscrowV2_1.MilestoneStatus.Funded, seed);
        if (!ok) return;
        if (escrow.getJob(id).status != DevSwapEscrowV2_1.JobStatus.Accepted) return;
        DevSwapEscrowV2_1.Job memory j = escrow.getJob(id);
        vm.prank(who % 2 == 0 ? j.client : j.developer);
        escrow.raiseDispute(id, 0);
    }

    function resolve(uint256 seed, bool pay) external {
        (bool ok, uint256 id) = _findMilestone(DevSwapEscrowV2_1.MilestoneStatus.Disputed, seed);
        if (!ok) return;
        uint256 amt = escrow.getMilestone(id, 0).amount;
        router.setShouldRevert(false);
        router.setRate(1, 1);
        vm.prank(arbiter); // bootstrap arbiter, eligible for every dispute
        escrow.resolveDispute(id, 0, pay);
        ghostLocked -= amt;
    }

    function buyback() external {
        if (escrow.buybackReserve() == 0) return;
        router.setShouldRevert(false);
        router.setRate(1, 1);
        vm.prank(owner);
        escrow.executeBuybackBurn(0, block.timestamp + 1);
    }
}
