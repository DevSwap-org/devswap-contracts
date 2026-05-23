// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {EscrowV2_1Base} from "../utils/EscrowV2_1Base.sol";
import {DevSwapEscrowV2_1} from "../../src/DevSwapEscrowV2_1.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DevSwapEscrowV2_1Test is EscrowV2_1Base {
    // --------------------------------------------------------------------- constructor
    function test_constructor_setsStateAndBootstrapArbiter() public view {
        assertEq(escrow.owner(), owner);
        assertEq(escrow.feeRecipient(), feeRecipient);
        assertEq(escrow.submitTimeout(), 14 days);
        assertEq(escrow.reviewTimeout(), 7 days);
        assertEq(escrow.ARBITER_TIMELOCK(), 48 hours);
        assertTrue(escrow.isArbiter(arbiter)); // bootstrapped
        assertGt(escrow.arbiterSince(arbiter), 0);
        assertFalse(escrow.isArbiter(owner)); // owner is NOT an implicit arbiter
    }

    function test_constructor_revertsOnZeroCoreAddress() public {
        vm.expectRevert(DevSwapEscrowV2_1.ZeroAddress.selector);
        new DevSwapEscrowV2_1(address(0), address(dswp), address(router), feeRecipient, owner, arbiter);
    }

    function test_constructor_zeroInitialArbiterAllowed() public {
        DevSwapEscrowV2_1 e =
            new DevSwapEscrowV2_1(address(usdt), address(dswp), address(router), feeRecipient, owner, address(0));
        assertFalse(e.isArbiter(address(0)));
    }

    // --------------------------------------------------------------------- createJob / lifecycle
    function test_createJob_singleAndMulti() public {
        uint256 id = _createJob(1000e18);
        assertEq(usdt.balanceOf(address(escrow)), 1000e18);
        assertEq(escrow.getReputation(client).jobsPosted, 1);

        uint256[] memory amts = new uint256[](3);
        amts[0] = 100e18;
        amts[1] = 200e18;
        amts[2] = 300e18;
        uint256 id2 = _createJobMulti(amts);
        assertEq(escrow.getJob(id2).milestoneCount, 3);
        assertEq(usdt.balanceOf(address(escrow)), 1000e18 + 600e18);
        assertEq(escrow.getMilestones(id2).length, 3);
        assertTrue(id != id2);
    }

    function test_createJob_reverts() public {
        uint256[] memory none = new uint256[](0);
        vm.prank(client);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidMilestoneCount.selector);
        escrow.createJob(none, "x");

        uint256[] memory big = new uint256[](21);
        for (uint256 i; i < 21; ++i) {
            big[i] = 1e18;
        }
        vm.startPrank(client);
        usdt.approve(address(escrow), 21e18);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidMilestoneCount.selector);
        escrow.createJob(big, "x");

        uint256[] memory zero = new uint256[](1);
        zero[0] = 0;
        vm.expectRevert(DevSwapEscrowV2_1.ZeroAmount.selector);
        escrow.createJob(zero, "x");
        vm.stopPrank();

        vm.prank(owner);
        escrow.pause();
        uint256[] memory one = _singleton(1e18);
        vm.prank(client);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.createJob(one, "x");
    }

    function test_acceptJob_andReverts() public {
        uint256 id = _createJob(1000e18);
        _accept(id);
        assertEq(uint8(escrow.getJob(id).status), uint8(DevSwapEscrowV2_1.JobStatus.Accepted));
        assertEq(escrow.getReputation(developer).jobsAccepted, 1);

        vm.prank(makeAddr("dev2"));
        vm.expectRevert(DevSwapEscrowV2_1.InvalidJobStatus.selector);
        escrow.acceptJob(id);

        uint256 id2 = _createJob(1000e18);
        vm.prank(client);
        vm.expectRevert(DevSwapEscrowV2_1.ClientCannotAcceptOwnJob.selector);
        escrow.acceptJob(id2);
    }

    function test_submitMilestone_andReverts() public {
        uint256 id = _createJob(1000e18);
        _accept(id);
        _submit(id, 0);
        assertEq(uint8(escrow.getMilestone(id, 0).status), uint8(DevSwapEscrowV2_1.MilestoneStatus.Submitted));

        vm.prank(client);
        vm.expectRevert(DevSwapEscrowV2_1.NotDeveloper.selector);
        escrow.submitMilestone(id, 0, "x");

        uint256 id2 = _createJob(1000e18);
        vm.prank(developer);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidJobStatus.selector);
        escrow.submitMilestone(id2, 0, "x");
    }

    function test_releaseMilestone_splitBurnReputationCompletion() public {
        uint256 amount = 1000e18;
        uint256 id = _toSubmitted(amount);
        (uint256 devNet, uint256 fee, uint256 buyback) = _expectedSplit(amount);
        uint256 supplyBefore = dswp.totalSupply();

        vm.prank(client);
        escrow.releaseMilestone(id, 0);

        assertEq(usdt.balanceOf(developer), devNet);
        assertEq(usdt.balanceOf(feeRecipient), fee);
        assertEq(usdt.balanceOf(address(escrow)), 0);
        assertEq(dswp.totalSupply(), supplyBefore - buyback);
        assertEq(uint8(escrow.getJob(id).status), uint8(DevSwapEscrowV2_1.JobStatus.Completed));
        assertEq(escrow.getReputation(developer).milestonesPaid, 1);
        assertEq(escrow.getReputation(client).totalSpent, amount);
    }

    function test_releaseMilestone_reverts() public {
        uint256 id = _toSubmitted(1000e18);
        vm.prank(developer);
        vm.expectRevert(DevSwapEscrowV2_1.NotClient.selector);
        escrow.releaseMilestone(id, 0);

        uint256 id2 = _createJob(1000e18);
        _accept(id2);
        vm.prank(client);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidMilestoneStatus.selector);
        escrow.releaseMilestone(id2, 0);

        vm.prank(owner);
        escrow.pause();
        vm.prank(client);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.releaseMilestone(id, 0);
    }

    function test_releaseMilestone_deferOnFailAndWhenDisabled() public {
        uint256 amount = 1000e18;
        (,, uint256 buyback) = _expectedSplit(amount);

        uint256 id = _toSubmitted(amount);
        router.setShouldRevert(true);
        vm.prank(client);
        escrow.releaseMilestone(id, 0);
        assertEq(escrow.buybackReserve(), buyback);
        router.setShouldRevert(false);

        vm.prank(owner);
        escrow.setAutoBuybackEnabled(false);
        uint256 id2 = _toSubmitted(amount);
        vm.prank(client);
        escrow.releaseMilestone(id2, 0);
        assertEq(escrow.buybackReserve(), buyback * 2);
    }

    function test_releaseMilestone_tinyAmountNoBuyback() public {
        uint256 id = _toSubmitted(50);
        vm.prank(client);
        escrow.releaseMilestone(id, 0);
        assertEq(usdt.balanceOf(developer), 50);
        assertEq(escrow.buybackReserve(), 0);
    }

    function test_multiMilestone_partialThenComplete() public {
        uint256[] memory amts = new uint256[](2);
        amts[0] = 100e18;
        amts[1] = 200e18;
        uint256 id = _createJobMulti(amts);
        _accept(id);
        _submit(id, 0);
        vm.prank(client);
        escrow.releaseMilestone(id, 0);
        assertEq(uint8(escrow.getJob(id).status), uint8(DevSwapEscrowV2_1.JobStatus.Accepted));
        _submit(id, 1);
        vm.prank(client);
        escrow.releaseMilestone(id, 1);
        assertEq(uint8(escrow.getJob(id).status), uint8(DevSwapEscrowV2_1.JobStatus.Completed));
        assertEq(escrow.getReputation(developer).milestonesPaid, 2);
    }

    function test_invalidMilestoneStatus_paths() public {
        // submit again on an already-submitted milestone -> not Funded
        uint256 id = _toSubmitted(1000e18);
        vm.prank(developer);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidMilestoneStatus.selector);
        escrow.submitMilestone(id, 0, "x");

        // cancel a submitted milestone -> not Funded
        vm.prank(client);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidMilestoneStatus.selector);
        escrow.cancelMilestone(id, 0);

        // claim a funded (not submitted) milestone -> not Submitted
        uint256 id2 = _createJob(1000e18);
        _accept(id2);
        vm.warp(block.timestamp + 8 days);
        vm.prank(developer);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidMilestoneStatus.selector);
        escrow.claimMilestone(id2, 0);

        // raise dispute on a released milestone (job still Accepted) -> not Funded/Submitted
        uint256[] memory amts = new uint256[](2);
        amts[0] = 100e18;
        amts[1] = 200e18;
        uint256 id3 = _createJobMulti(amts);
        _accept(id3);
        _submit(id3, 0);
        vm.prank(client);
        escrow.releaseMilestone(id3, 0);
        vm.prank(client);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidMilestoneStatus.selector);
        escrow.raiseDispute(id3, 0);
    }

    // --------------------------------------------------------------------- claim / cancel
    function test_claimMilestone_afterReviewAndReverts() public {
        uint256 amount = 1000e18;
        uint256 id = _toSubmitted(amount);
        (uint256 devNet,,) = _expectedSplit(amount);

        vm.prank(developer);
        vm.expectRevert(DevSwapEscrowV2_1.ReviewWindowOpen.selector);
        escrow.claimMilestone(id, 0);

        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(DevSwapEscrowV2_1.NotAuthorized.selector);
        escrow.claimMilestone(id, 0);

        vm.prank(developer);
        escrow.claimMilestone(id, 0);
        assertEq(usdt.balanceOf(developer), devNet);
    }

    function test_claimMilestone_keeper() public {
        uint256 id = _toSubmitted(1000e18);
        vm.warp(block.timestamp + 8 days);
        vm.prank(keeper);
        escrow.claimMilestone(id, 0);
        assertEq(uint8(escrow.getMilestone(id, 0).status), uint8(DevSwapEscrowV2_1.MilestoneStatus.Released));
    }

    function test_cancelMilestone_openTimeoutAndReverts() public {
        uint256 id = _createJob(1000e18);
        uint256 bal = usdt.balanceOf(client);
        vm.prank(client);
        escrow.cancelMilestone(id, 0);
        assertEq(usdt.balanceOf(client), bal + 1000e18);
        assertEq(uint8(escrow.getJob(id).status), uint8(DevSwapEscrowV2_1.JobStatus.Cancelled));

        uint256 id2 = _createJob(1000e18);
        _accept(id2);
        vm.prank(client);
        vm.expectRevert(DevSwapEscrowV2_1.CannotCancel.selector);
        escrow.cancelMilestone(id2, 0);
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(client);
        escrow.cancelMilestone(id2, 0);

        uint256 id3 = _toSubmitted(1000e18);
        vm.prank(developer);
        vm.expectRevert(DevSwapEscrowV2_1.NotClient.selector);
        escrow.cancelMilestone(id3, 0);
    }

    function test_cancelMilestone_worksWhenPaused() public {
        uint256 id = _createJob(1000e18);
        vm.prank(owner);
        escrow.pause();
        vm.prank(client);
        escrow.cancelMilestone(id, 0);
        assertEq(uint8(escrow.getMilestone(id, 0).status), uint8(DevSwapEscrowV2_1.MilestoneStatus.Cancelled));
    }

    // --------------------------------------------------------------------- disputes (snapshot)
    function test_raiseDispute_snapshotsTimeAndReverts() public {
        uint256 id = _toSubmitted(1000e18);
        vm.prank(client);
        escrow.raiseDispute(id, 0);
        DevSwapEscrowV2_1.Milestone memory m = escrow.getMilestone(id, 0);
        assertEq(uint8(m.status), uint8(DevSwapEscrowV2_1.MilestoneStatus.Disputed));
        assertEq(m.disputeRaisedAt, block.timestamp);
        assertEq(escrow.getReputation(client).disputesRaised, 1);

        uint256 id2 = _createJob(1000e18); // Open, not accepted
        vm.prank(client);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidJobStatus.selector);
        escrow.raiseDispute(id2, 0);

        uint256 id3 = _toSubmitted(1000e18);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(DevSwapEscrowV2_1.NotParty.selector);
        escrow.raiseDispute(id3, 0);
    }

    // MANDATORY 1: the owner cannot resolve a dispute (not an implicit arbiter).
    function test_resolveDispute_ownerCannotResolve() public {
        uint256 id = _toDisputed(1000e18);
        vm.prank(owner);
        vm.expectRevert(DevSwapEscrowV2_1.NotArbiter.selector);
        escrow.resolveDispute(id, 0, true);
    }

    function test_resolveDispute_bootstrapArbiterPaysDeveloper() public {
        uint256 amount = 1000e18;
        uint256 id = _toDisputed(amount);
        (uint256 devNet, uint256 fee,) = _expectedSplit(amount);
        vm.prank(arbiter);
        escrow.resolveDispute(id, 0, true);
        assertEq(usdt.balanceOf(developer), devNet);
        assertEq(usdt.balanceOf(feeRecipient), fee);
        assertEq(escrow.getReputation(client).disputesLost, 1);
    }

    function test_resolveDispute_refundClient() public {
        uint256 amount = 1000e18;
        uint256 id = _toDisputed(amount);
        uint256 bal = usdt.balanceOf(client);
        vm.prank(arbiter);
        escrow.resolveDispute(id, 0, false);
        assertEq(usdt.balanceOf(client), bal + amount);
        assertEq(escrow.getReputation(developer).disputesLost, 1);
    }

    function test_resolveDispute_revertsIfNotDisputed() public {
        uint256 id = _toSubmitted(1000e18);
        vm.prank(arbiter);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidMilestoneStatus.selector);
        escrow.resolveDispute(id, 0, true);
    }

    // MANDATORY 4: an arbiter added AFTER a dispute is opened cannot resolve it.
    function test_resolveDispute_arbiterAddedAfterDisputeCannotResolve() public {
        uint256 id = _toDisputed(1000e18); // disputeRaisedAt = now
        address late = makeAddr("lateArbiter");
        _addArbiter(late); // arbiterSince = now + 48h+1 > disputeRaisedAt
        assertTrue(escrow.isArbiter(late));
        vm.prank(late);
        vm.expectRevert(DevSwapEscrowV2_1.ArbiterNotEligible.selector);
        escrow.resolveDispute(id, 0, true);
    }

    // MANDATORY 5 (per check #6 — implemented (A): a removed arbiter cannot resolve).
    // The "removed-but-was-eligible can still resolve" alternative is debated in ADR-0003.
    function test_resolveDispute_removedArbiterCannotResolve() public {
        uint256 id = _toDisputed(1000e18);
        vm.prank(owner);
        escrow.removeArbiter(arbiter);
        vm.prank(arbiter);
        vm.expectRevert(DevSwapEscrowV2_1.NotArbiter.selector);
        escrow.resolveDispute(id, 0, true);
    }

    function test_resolveDispute_arbiterAddedBeforeDisputeCanResolve() public {
        address a2 = makeAddr("a2");
        _addArbiter(a2); // arbiterSince = T (now)
        uint256 id = _toDisputed(1000e18); // disputeRaisedAt > T
        vm.prank(a2);
        escrow.resolveDispute(id, 0, true);
        assertEq(uint8(escrow.getMilestone(id, 0).status), uint8(DevSwapEscrowV2_1.MilestoneStatus.Released));
    }

    // --------------------------------------------------------------------- arbiter registry (timelock)
    // MANDATORY 2: execute before the timelock elapses fails.
    function test_queueExecuteArbiter_timelock() public {
        address a = makeAddr("newArb");
        vm.startPrank(owner);
        escrow.queueArbiter(a);
        vm.expectRevert(DevSwapEscrowV2_1.TimelockNotElapsed.selector);
        escrow.executeArbiter(a); // immediately -> too early
        vm.warp(block.timestamp + TIMELOCK + 1);
        escrow.executeArbiter(a);
        vm.stopPrank();
        assertTrue(escrow.isArbiter(a));
        assertEq(escrow.arbiterSince(a), block.timestamp);
    }

    function test_queueArbiter_reverts() public {
        vm.startPrank(owner);
        vm.expectRevert(DevSwapEscrowV2_1.ZeroAddress.selector);
        escrow.queueArbiter(address(0));
        vm.expectRevert(DevSwapEscrowV2_1.AlreadyArbiter.selector);
        escrow.queueArbiter(arbiter); // already an arbiter
        vm.stopPrank();

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, client));
        escrow.queueArbiter(makeAddr("x"));
    }

    function test_executeArbiter_revertsIfNotQueued() public {
        vm.prank(owner);
        vm.expectRevert(DevSwapEscrowV2_1.NotQueued.selector);
        escrow.executeArbiter(makeAddr("never"));
    }

    // MANDATORY 3: cancelling a queued change prevents execution.
    function test_cancelArbiterChange() public {
        address a = makeAddr("pending");
        vm.startPrank(owner);
        escrow.queueArbiter(a);
        escrow.cancelArbiterChange(a);
        vm.warp(block.timestamp + TIMELOCK + 1);
        vm.expectRevert(DevSwapEscrowV2_1.NotQueued.selector);
        escrow.executeArbiter(a);
        vm.stopPrank();
        assertFalse(escrow.isArbiter(a));
    }

    function test_cancelArbiterChange_revertsIfNotQueued() public {
        vm.prank(owner);
        vm.expectRevert(DevSwapEscrowV2_1.NotQueued.selector);
        escrow.cancelArbiterChange(makeAddr("never"));
    }

    function test_removeArbiter_immediateAndReverts() public {
        vm.prank(owner);
        escrow.removeArbiter(arbiter);
        assertFalse(escrow.isArbiter(arbiter));
        assertEq(escrow.arbiterSince(arbiter), 0);

        vm.prank(owner);
        vm.expectRevert(DevSwapEscrowV2_1.NotArbiter.selector);
        escrow.removeArbiter(makeAddr("never"));

        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, client));
        escrow.removeArbiter(arbiter);
    }

    // --------------------------------------------------------------------- buyback / admin / views
    function test_executeBuybackBurn_andReverts() public {
        uint256 id = _toSubmitted(1000e18);
        (,, uint256 buyback) = _expectedSplit(1000e18);
        router.setShouldRevert(true);
        vm.prank(client);
        escrow.releaseMilestone(id, 0);
        router.setShouldRevert(false);

        vm.prank(client);
        vm.expectRevert(DevSwapEscrowV2_1.NotAuthorized.selector);
        escrow.executeBuybackBurn(0, block.timestamp);

        uint256 supplyBefore = dswp.totalSupply();
        vm.prank(keeper);
        escrow.executeBuybackBurn(0, block.timestamp);
        assertEq(escrow.buybackReserve(), 0);
        assertEq(dswp.totalSupply(), supplyBefore - buyback);

        vm.prank(owner);
        vm.expectRevert(DevSwapEscrowV2_1.NothingToBuyback.selector);
        escrow.executeBuybackBurn(0, block.timestamp);
    }

    function test_autoBuybackAndBurn_onlySelf() public {
        vm.prank(owner);
        vm.expectRevert(DevSwapEscrowV2_1.OnlySelf.selector);
        escrow.autoBuybackAndBurn(1e18);
    }

    function test_admin_settersAndBounds() public {
        vm.startPrank(owner);
        escrow.setFeeRecipient(makeAddr("nr"));
        assertEq(escrow.feeRecipient(), makeAddr("nr"));
        vm.expectRevert(DevSwapEscrowV2_1.ZeroAddress.selector);
        escrow.setFeeRecipient(address(0));

        escrow.setKeeper(address(0));
        escrow.setSubmitTimeout(30 days);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidTimeout.selector);
        escrow.setSubmitTimeout(1 hours);
        escrow.setReviewTimeout(3 days);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidTimeout.selector);
        escrow.setReviewTimeout(61 days);
        escrow.setBuybackSlippageBps(500);
        vm.expectRevert(DevSwapEscrowV2_1.InvalidSlippage.selector);
        escrow.setBuybackSlippageBps(1001);
        escrow.setAutoBuybackEnabled(false);
        assertFalse(escrow.autoBuybackEnabled());
        escrow.pause();
        assertTrue(escrow.paused());
        escrow.unpause();
        vm.stopPrank();
    }

    function test_admin_onlyOwner() public {
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, client));
        escrow.setFeeRecipient(client);
    }

    function test_ownable2Step() public {
        address n = makeAddr("newOwner");
        vm.prank(owner);
        escrow.transferOwnership(n);
        assertEq(escrow.owner(), owner);
        vm.prank(n);
        escrow.acceptOwnership();
        assertEq(escrow.owner(), n);
    }
}
