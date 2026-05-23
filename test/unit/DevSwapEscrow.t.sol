// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {EscrowBase} from "../utils/EscrowBase.sol";
import {DevSwapEscrow} from "../../src/DevSwapEscrow.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract DevSwapEscrowTest is EscrowBase {
    // ---------------------------------------------------------------- deploy
    function test_Constructor_SetsImmutables() public view {
        assertEq(address(escrow.usdt()), address(usdt));
        assertEq(address(escrow.dswp()), address(dswp));
        assertEq(address(escrow.router()), address(router));
        assertEq(escrow.feeRecipient(), feeRecipient);
        assertEq(escrow.owner(), owner);
        assertEq(escrow.keeper(), keeper);
        assertEq(escrow.buybackReserve(), 0);
        assertEq(escrow.submitTimeout(), 14 days);
        assertTrue(escrow.autoBuybackEnabled());
        assertEq(escrow.buybackSlippageBps(), 300);
    }

    function test_Constructor_RevertsOnZeroAddress() public {
        vm.expectRevert(DevSwapEscrow.ZeroAddress.selector);
        new DevSwapEscrow(address(0), address(dswp), address(router), feeRecipient, owner);
        vm.expectRevert(DevSwapEscrow.ZeroAddress.selector);
        new DevSwapEscrow(address(usdt), address(0), address(router), feeRecipient, owner);
        vm.expectRevert(DevSwapEscrow.ZeroAddress.selector);
        new DevSwapEscrow(address(usdt), address(dswp), address(0), feeRecipient, owner);
        vm.expectRevert(DevSwapEscrow.ZeroAddress.selector);
        new DevSwapEscrow(address(usdt), address(dswp), address(router), address(0), owner);
    }

    // ---------------------------------------------------------------- createTask
    function test_CreateTask_LocksUsdtAndStores() public {
        uint256 amount = 1_000e18;
        uint256 id = _createTask(amount);
        assertEq(id, 0);
        assertEq(usdt.balanceOf(address(escrow)), amount);
        DevSwapEscrow.Task memory t = escrow.getTask(id);
        assertEq(t.client, client);
        assertEq(t.amount, amount);
        assertEq(uint8(t.status), uint8(DevSwapEscrow.Status.Open));
        assertEq(escrow.nextTaskId(), 1);
    }

    function test_CreateTask_RevertsOnZeroAmount() public {
        vm.startPrank(client);
        usdt.approve(address(escrow), 1);
        vm.expectRevert(DevSwapEscrow.ZeroAmount.selector);
        escrow.createTask(0, "ipfs://x");
        vm.stopPrank();
    }

    function test_CreateTask_RevertsWithoutApproval() public {
        vm.prank(client);
        vm.expectRevert();
        escrow.createTask(1_000e18, "ipfs://x");
    }

    function test_CreateTask_IncrementsIds() public {
        uint256 a = _createTask(100e18);
        uint256 b = _createTask(200e18);
        assertEq(a, 0);
        assertEq(b, 1);
    }

    // ---------------------------------------------------------------- acceptTask
    function test_AcceptTask_SetsDeveloperAndTimestamp() public {
        uint256 id = _createTask(1_000e18);
        _accept(id);
        DevSwapEscrow.Task memory t = escrow.getTask(id);
        assertEq(t.developer, developer);
        assertEq(uint8(t.status), uint8(DevSwapEscrow.Status.Accepted));
        assertEq(t.acceptedAt, block.timestamp);
    }

    function test_AcceptTask_RevertsIfClientAcceptsOwn() public {
        uint256 id = _createTask(1_000e18);
        vm.prank(client);
        vm.expectRevert(DevSwapEscrow.ClientCannotAcceptOwnTask.selector);
        escrow.acceptTask(id);
    }

    function test_AcceptTask_RevertsIfNotOpen() public {
        uint256 id = _createTask(1_000e18);
        _accept(id);
        vm.prank(makeAddr("other"));
        vm.expectRevert(DevSwapEscrow.InvalidTaskStatus.selector);
        escrow.acceptTask(id);
    }

    // ---------------------------------------------------------------- submitTask
    function test_SubmitTask_SetsDeliveryHash() public {
        uint256 id = _createTask(1_000e18);
        _accept(id);
        _submit(id);
        DevSwapEscrow.Task memory t = escrow.getTask(id);
        assertEq(uint8(t.status), uint8(DevSwapEscrow.Status.Submitted));
        assertEq(t.deliveryHash, "ipfs://delivery");
    }

    function test_SubmitTask_RevertsIfNotDeveloper() public {
        uint256 id = _createTask(1_000e18);
        _accept(id);
        vm.prank(makeAddr("intruder"));
        vm.expectRevert(DevSwapEscrow.NotDeveloper.selector);
        escrow.submitTask(id, "ipfs://x");
    }

    function test_SubmitTask_RevertsIfNotAccepted() public {
        uint256 id = _createTask(1_000e18);
        vm.prank(developer);
        vm.expectRevert(DevSwapEscrow.InvalidTaskStatus.selector);
        escrow.submitTask(id, "ipfs://x");
    }

    // ---------------------------------------------------------------- releaseFunds
    function test_ReleaseFunds_PaysSplit() public {
        uint256 amount = 10_000e18;
        uint256 id = _toSubmitted(amount);
        (uint256 devNet, uint256 fee, uint256 buyback) = _expectedSplit(amount);
        uint256 supplyBefore = dswp.totalSupply();

        vm.prank(client);
        escrow.releaseFunds(id);

        assertEq(usdt.balanceOf(developer), devNet, "dev net");
        assertEq(usdt.balanceOf(feeRecipient), fee, "fee");
        // Option C: 1.5% is bought & burned inline (router rate 1:1) -> reserve stays 0, no USDT left
        assertEq(escrow.buybackReserve(), 0, "reserve (burned inline)");
        assertEq(usdt.balanceOf(address(escrow)), 0, "no USDT left in escrow");
        assertEq(supplyBefore - dswp.totalSupply(), buyback, "DSWP burned == buyback (1:1)");
        assertEq(uint8(escrow.getTask(id).status), uint8(DevSwapEscrow.Status.Released));
    }

    function test_ReleaseFunds_97_15_15_Split() public {
        uint256 amount = 10_000e18;
        uint256 id = _toSubmitted(amount);
        uint256 supplyBefore = dswp.totalSupply();
        vm.prank(client);
        escrow.releaseFunds(id);
        assertEq(usdt.balanceOf(developer), 9_700e18); // 97%
        assertEq(usdt.balanceOf(feeRecipient), 150e18); // 1.5%
        assertEq(escrow.buybackReserve(), 0); // 1.5% burned inline
        assertEq(supplyBefore - dswp.totalSupply(), 150e18); // 1.5% -> DSWP burned
    }

    function test_ReleaseFunds_DefersWhenAutoBuybackDisabled() public {
        vm.prank(owner);
        escrow.setAutoBuybackEnabled(false);
        uint256 amount = 10_000e18;
        uint256 id = _toSubmitted(amount);
        (,, uint256 buyback) = _expectedSplit(amount);
        uint256 supplyBefore = dswp.totalSupply();
        vm.prank(client);
        escrow.releaseFunds(id);
        assertEq(escrow.buybackReserve(), buyback, "accrued (auto-buyback off)");
        assertEq(dswp.totalSupply(), supplyBefore, "nothing burned");
        assertEq(usdt.balanceOf(address(escrow)), buyback, "USDT held for bulk burn");
    }

    function test_ReleaseFunds_RevertsIfNotClient() public {
        uint256 id = _toSubmitted(1_000e18);
        vm.prank(developer);
        vm.expectRevert(DevSwapEscrow.NotClient.selector);
        escrow.releaseFunds(id);
    }

    function test_ReleaseFunds_RevertsIfNotSubmitted() public {
        uint256 id = _createTask(1_000e18);
        _accept(id);
        vm.prank(client);
        vm.expectRevert(DevSwapEscrow.InvalidTaskStatus.selector);
        escrow.releaseFunds(id);
    }

    function test_ReleaseFunds_CannotDoubleRelease() public {
        uint256 id = _toSubmitted(1_000e18);
        vm.startPrank(client);
        escrow.releaseFunds(id);
        vm.expectRevert(DevSwapEscrow.InvalidTaskStatus.selector);
        escrow.releaseFunds(id);
        vm.stopPrank();
    }

    function test_ReleaseFunds_DefersReserveAcrossTasksWhenRouterDown() public {
        router.setShouldRevert(true); // market down -> each release defers its 1.5%
        uint256 id1 = _toSubmitted(10_000e18);
        uint256 id2 = _toSubmitted(20_000e18);
        vm.startPrank(client);
        escrow.releaseFunds(id1);
        escrow.releaseFunds(id2);
        vm.stopPrank();
        assertEq(escrow.buybackReserve(), 150e18 + 300e18);
    }

    // ---------------------------------------------------------------- cancelTask
    function test_CancelTask_RefundsWhenOpen() public {
        uint256 amount = 5_000e18;
        uint256 id = _createTask(amount);
        uint256 balBefore = usdt.balanceOf(client);
        vm.prank(client);
        escrow.cancelTask(id);
        assertEq(usdt.balanceOf(client), balBefore + amount);
        assertEq(uint8(escrow.getTask(id).status), uint8(DevSwapEscrow.Status.Cancelled));
    }

    function test_CancelTask_RevertsIfAcceptedBeforeTimeout() public {
        uint256 id = _createTask(1_000e18);
        _accept(id);
        vm.prank(client);
        vm.expectRevert(DevSwapEscrow.CannotCancel.selector);
        escrow.cancelTask(id);
    }

    function test_CancelTask_AllowedAfterSubmitTimeout() public {
        uint256 amount = 1_000e18;
        uint256 id = _createTask(amount);
        _accept(id);
        uint256 balBefore = usdt.balanceOf(client);
        vm.warp(block.timestamp + 14 days + 1);
        vm.prank(client);
        escrow.cancelTask(id);
        assertEq(usdt.balanceOf(client), balBefore + amount);
    }

    function test_CancelTask_RevertsIfSubmitted() public {
        uint256 id = _toSubmitted(1_000e18);
        vm.warp(block.timestamp + 100 days);
        vm.prank(client);
        vm.expectRevert(DevSwapEscrow.CannotCancel.selector);
        escrow.cancelTask(id);
    }

    function test_CancelTask_RevertsIfNotClient() public {
        uint256 id = _createTask(1_000e18);
        vm.prank(developer);
        vm.expectRevert(DevSwapEscrow.NotClient.selector);
        escrow.cancelTask(id);
    }

    // ---------------------------------------------------------------- disputes
    function test_RaiseDispute_ByClient() public {
        uint256 id = _toSubmitted(1_000e18);
        vm.prank(client);
        escrow.raiseDispute(id);
        assertEq(uint8(escrow.getTask(id).status), uint8(DevSwapEscrow.Status.Disputed));
    }

    function test_RaiseDispute_ByDeveloper() public {
        uint256 id = _createTask(1_000e18);
        _accept(id);
        vm.prank(developer);
        escrow.raiseDispute(id);
        assertEq(uint8(escrow.getTask(id).status), uint8(DevSwapEscrow.Status.Disputed));
    }

    function test_RaiseDispute_RevertsIfNotParty() public {
        uint256 id = _toSubmitted(1_000e18);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(DevSwapEscrow.NotParty.selector);
        escrow.raiseDispute(id);
    }

    function test_RaiseDispute_RevertsIfInvalidStatus() public {
        // client is a party but the task is still Open (not Accepted/Submitted) -> InvalidTaskStatus
        uint256 id = _createTask(1_000e18);
        vm.prank(client);
        vm.expectRevert(DevSwapEscrow.InvalidTaskStatus.selector);
        escrow.raiseDispute(id);
    }

    function test_ResolveDispute_PayDeveloper() public {
        uint256 amount = 10_000e18;
        uint256 id = _toSubmitted(amount);
        vm.prank(client);
        escrow.raiseDispute(id);
        (uint256 devNet, uint256 fee, uint256 buyback) = _expectedSplit(amount);
        uint256 supplyBefore = dswp.totalSupply();
        vm.prank(owner);
        escrow.resolveDispute(id, true);
        assertEq(usdt.balanceOf(developer), devNet);
        assertEq(usdt.balanceOf(feeRecipient), fee);
        assertEq(escrow.buybackReserve(), 0); // burned inline via _payout
        assertEq(supplyBefore - dswp.totalSupply(), buyback);
        assertEq(uint8(escrow.getTask(id).status), uint8(DevSwapEscrow.Status.Released));
    }

    function test_ResolveDispute_RefundClient() public {
        uint256 amount = 10_000e18;
        uint256 id = _toSubmitted(amount);
        uint256 balBefore = usdt.balanceOf(client);
        vm.prank(developer);
        escrow.raiseDispute(id);
        vm.prank(owner);
        escrow.resolveDispute(id, false);
        assertEq(usdt.balanceOf(client), balBefore + amount);
        assertEq(uint8(escrow.getTask(id).status), uint8(DevSwapEscrow.Status.Cancelled));
    }

    function test_ResolveDispute_RevertsIfNotOwner() public {
        uint256 id = _toSubmitted(1_000e18);
        vm.prank(client);
        escrow.raiseDispute(id);
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, client));
        escrow.resolveDispute(id, true);
    }

    function test_ResolveDispute_RevertsIfNotDisputed() public {
        uint256 id = _toSubmitted(1_000e18);
        vm.prank(owner);
        vm.expectRevert(DevSwapEscrow.InvalidTaskStatus.selector);
        escrow.resolveDispute(id, true);
    }

    // ---------------------------------------------------------------- buyback-burn
    /// @dev Helper: release with a broken router so the 1.5% is DEFERRED to buybackReserve.
    function _deferOneTask(uint256 amount) internal returns (uint256 id) {
        router.setShouldRevert(true);
        id = _toSubmitted(amount);
        vm.prank(client);
        escrow.releaseFunds(id);
        router.setShouldRevert(false);
    }

    function test_ExecuteBuybackBurn_SwapsAndBurns() public {
        _deferOneTask(10_000e18); // -> 150e18 deferred to reserve
        assertEq(escrow.buybackReserve(), 150e18);

        router.setRate(2, 1); // 2 DSWP per 1 USDT
        uint256 burnedBefore = dswp.totalSupply();

        vm.prank(keeper);
        escrow.executeBuybackBurn(0, block.timestamp + 1);

        assertEq(escrow.buybackReserve(), 0, "reserve zeroed");
        assertEq(usdt.balanceOf(address(escrow)), 0, "usdt swapped out");
        assertEq(dswp.totalSupply(), burnedBefore - 300e18, "300 DSWP burned");
    }

    function test_ExecuteBuybackBurn_OwnerCanCall() public {
        _deferOneTask(10_000e18);
        vm.prank(owner);
        escrow.executeBuybackBurn(0, block.timestamp + 1);
        assertEq(escrow.buybackReserve(), 0);
    }

    function test_ExecuteBuybackBurn_RevertsIfUnauthorized() public {
        _deferOneTask(10_000e18);
        vm.prank(makeAddr("randomBot"));
        vm.expectRevert(DevSwapEscrow.NotAuthorized.selector);
        escrow.executeBuybackBurn(0, block.timestamp + 1);
    }

    function test_ExecuteBuybackBurn_RevertsIfNothingToBuyback() public {
        // normal release burns inline -> reserve stays 0 -> nothing to bulk-burn
        uint256 id = _toSubmitted(10_000e18);
        vm.prank(client);
        escrow.releaseFunds(id);
        vm.prank(keeper);
        vm.expectRevert(DevSwapEscrow.NothingToBuyback.selector);
        escrow.executeBuybackBurn(0, block.timestamp + 1);
    }

    function test_ExecuteBuybackBurn_RevertsOnSlippage() public {
        _deferOneTask(10_000e18);
        router.setRate(1, 1); // 150 DSWP out
        vm.prank(keeper);
        vm.expectRevert(); // INSUFFICIENT_OUTPUT_AMOUNT from router
        escrow.executeBuybackBurn(151e18, block.timestamp + 1);
    }

    // ---- the critical isolation property (Option C: inline buyback, deferred on failure) ----
    function test_SwapFailure_DoesNotBlockDeveloperPayment() public {
        uint256 amount = 10_000e18;
        uint256 id = _toSubmitted(amount);
        (uint256 devNet,, uint256 buyback) = _expectedSplit(amount);

        // Market broken: releaseFunds must STILL succeed, pay the developer, and defer the buyback.
        router.setShouldRevert(true);
        vm.prank(client);
        escrow.releaseFunds(id); // inline swap fails -> caught -> deferred; dev paid
        assertEq(usdt.balanceOf(developer), devNet, "developer paid despite broken market");
        assertEq(escrow.buybackReserve(), buyback, "buyback deferred to reserve");
        assertEq(uint8(escrow.getTask(id).status), uint8(DevSwapEscrow.Status.Released));

        // Later, once the market recovers, the deferred amount drains via the bulk burn.
        router.setShouldRevert(false);
        uint256 supplyBefore = dswp.totalSupply();
        vm.prank(keeper);
        escrow.executeBuybackBurn(0, block.timestamp + 1);
        assertEq(escrow.buybackReserve(), 0);
        assertEq(supplyBefore - dswp.totalSupply(), buyback, "deferred buyback eventually burned");
    }

    function test_ReleaseFunds_InlineBurn_AutoBuybackHookIsSelfOnly() public {
        vm.expectRevert(DevSwapEscrow.OnlySelf.selector);
        escrow.autoBuybackAndBurn(1e18);
    }

    // ---------------------------------------------------------------- admin
    function test_SetFeeRecipient() public {
        address nf = makeAddr("newFee");
        vm.prank(owner);
        escrow.setFeeRecipient(nf);
        assertEq(escrow.feeRecipient(), nf);
    }

    function test_SetFeeRecipient_RevertsOnZero() public {
        vm.prank(owner);
        vm.expectRevert(DevSwapEscrow.ZeroAddress.selector);
        escrow.setFeeRecipient(address(0));
    }

    function test_SetFeeRecipient_RevertsIfNotOwner() public {
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, client));
        escrow.setFeeRecipient(client);
    }

    function test_SetSubmitTimeout_WithinBounds() public {
        vm.prank(owner);
        escrow.setSubmitTimeout(30 days);
        assertEq(escrow.submitTimeout(), 30 days);
    }

    function test_SetSubmitTimeout_RevertsOutOfBounds() public {
        vm.startPrank(owner);
        vm.expectRevert(DevSwapEscrow.InvalidTimeout.selector);
        escrow.setSubmitTimeout(1 hours);
        vm.expectRevert(DevSwapEscrow.InvalidTimeout.selector);
        escrow.setSubmitTimeout(100 days);
        vm.stopPrank();
    }

    function test_SetKeeper() public {
        address nk = makeAddr("newKeeper");
        vm.prank(owner);
        escrow.setKeeper(nk);
        assertEq(escrow.keeper(), nk);
    }

    function test_SetAutoBuybackEnabled() public {
        assertTrue(escrow.autoBuybackEnabled());
        vm.prank(owner);
        escrow.setAutoBuybackEnabled(false);
        assertFalse(escrow.autoBuybackEnabled());
    }

    function test_SetAutoBuybackEnabled_RevertsIfNotOwner() public {
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, client));
        escrow.setAutoBuybackEnabled(false);
    }

    function test_SetBuybackSlippageBps() public {
        assertEq(escrow.buybackSlippageBps(), 300);
        vm.prank(owner);
        escrow.setBuybackSlippageBps(500);
        assertEq(escrow.buybackSlippageBps(), 500);
    }

    function test_SetBuybackSlippageBps_RevertsAboveMax() public {
        vm.prank(owner);
        vm.expectRevert(DevSwapEscrow.InvalidSlippage.selector);
        escrow.setBuybackSlippageBps(1_001); // > MAX_SLIPPAGE_BPS (1000)
    }

    // ---------------------------------------------------------------- pausable
    function test_Pause_BlocksCreate() public {
        vm.prank(owner);
        escrow.pause();
        vm.startPrank(client);
        usdt.approve(address(escrow), 1_000e18);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        escrow.createTask(1_000e18, "ipfs://x");
        vm.stopPrank();
    }

    function test_Pause_AllowsCancelEscapeHatch() public {
        uint256 amount = 1_000e18;
        uint256 id = _createTask(amount);
        vm.prank(owner);
        escrow.pause();
        uint256 balBefore = usdt.balanceOf(client);
        vm.prank(client);
        escrow.cancelTask(id); // refund must work while paused
        assertEq(usdt.balanceOf(client), balBefore + amount);
    }

    function test_Unpause() public {
        vm.startPrank(owner);
        escrow.pause();
        escrow.unpause();
        vm.stopPrank();
        uint256 id = _createTask(1_000e18);
        assertEq(uint8(escrow.getTask(id).status), uint8(DevSwapEscrow.Status.Open));
    }

    function test_Pause_RevertsIfNotOwner() public {
        vm.prank(client);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, client));
        escrow.pause();
    }
}
