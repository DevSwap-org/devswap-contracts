// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {EscrowBase} from "../utils/EscrowBase.sol";
import {DevSwapEscrow} from "../../src/DevSwapEscrow.sol";

contract DevSwapEscrowFuzzTest is EscrowBase {
    uint256 internal constant MAX_AMOUNT = 1e30; // 1e12 tokens @ 18 decimals — large but overflow-safe

    function _fund(uint256 amount) internal {
        usdt.mint(client, amount);
    }

    function testFuzz_CreateLocksExactAmount(uint256 amount) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        _fund(amount);
        uint256 before = usdt.balanceOf(address(escrow));
        uint256 id = _createTask(amount);
        assertEq(usdt.balanceOf(address(escrow)) - before, amount);
        assertEq(escrow.getTask(id).amount, amount);
    }

    function testFuzz_ReleaseSplitSumsToAmount(uint256 amount) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        _fund(amount);
        // Pure split accounting with auto-buyback OFF -> deterministic & liquidity-independent
        vm.prank(owner);
        escrow.setAutoBuybackEnabled(false);
        uint256 id = _toSubmitted(amount);
        (uint256 devNet, uint256 fee, uint256 buyback) = _expectedSplit(amount);

        // exact split invariant: parts always reconstruct the whole, no dust lost
        assertEq(devNet + fee + buyback, amount, "split must sum to amount");
        assertEq(fee, (amount * FEE_BPS) / BPS);
        assertEq(buyback, (amount * BUYBACK_BPS) / BPS);

        uint256 reserveBefore = escrow.buybackReserve();
        vm.prank(client);
        escrow.releaseFunds(id);

        assertEq(usdt.balanceOf(developer), devNet);
        assertEq(usdt.balanceOf(feeRecipient), fee);
        assertEq(escrow.buybackReserve(), reserveBefore + buyback);
    }

    function testFuzz_DeveloperNeverLosesToRounding(uint256 amount) public {
        // developer must always receive at least 97% (remainder absorbs rounding in their favor)
        amount = bound(amount, 1, MAX_AMOUNT);
        _fund(amount);
        uint256 id = _toSubmitted(amount);
        (uint256 devNet,,) = _expectedSplit(amount);
        assertGe(devNet * BPS, amount * 9700, "dev gets >= 97%");
        vm.prank(client);
        escrow.releaseFunds(id);
        assertEq(usdt.balanceOf(developer), devNet);
    }

    function testFuzz_CancelRefundsFull(uint256 amount) public {
        amount = bound(amount, 1, MAX_AMOUNT);
        _fund(amount);
        uint256 balBefore = usdt.balanceOf(client);
        uint256 id = _createTask(amount);
        vm.prank(client);
        escrow.cancelTask(id);
        assertEq(usdt.balanceOf(client), balBefore, "full refund, net zero");
    }

    function testFuzz_FullLifecycle_NoFundsStuck(uint256 amount) public {
        // bound so the inline buyback (router 1:1) stays within router DSWP liquidity
        // (DSWP is hard-capped at 100M; the swap leg is liquidity-bounded, the escrow logic is not)
        amount = bound(amount, 1, 1e26);
        _fund(amount);
        uint256 id = _toSubmitted(amount);
        (uint256 devNet, uint256 fee, uint256 buyback) = _expectedSplit(amount);
        uint256 supplyBefore = dswp.totalSupply();

        vm.prank(client);
        escrow.releaseFunds(id);

        // Option C: 1.5% bought & burned inline -> no USDT stuck, nothing deferred
        assertEq(usdt.balanceOf(address(escrow)), 0, "no USDT stuck");
        assertEq(escrow.buybackReserve(), 0, "nothing deferred");
        assertEq(usdt.balanceOf(developer), devNet);
        assertEq(usdt.balanceOf(feeRecipient), fee);
        assertEq(supplyBefore - dswp.totalSupply(), buyback, "DSWP burned == buyback (1:1)");
    }

    function testFuzz_TimeoutBoundary(uint256 elapsed) public {
        uint256 amount = 1_000e18;
        _fund(amount);
        uint256 id = _createTask(amount);
        _accept(id);
        uint256 timeout = escrow.submitTimeout();
        elapsed = bound(elapsed, 0, timeout * 3);
        vm.warp(block.timestamp + elapsed);
        vm.prank(client);
        if (elapsed > timeout) {
            escrow.cancelTask(id); // allowed strictly after timeout
            assertEq(uint8(escrow.getTask(id).status), uint8(DevSwapEscrow.Status.Cancelled));
        } else {
            vm.expectRevert(DevSwapEscrow.CannotCancel.selector);
            escrow.cancelTask(id);
        }
    }

    function testFuzz_OnlyClientCanRelease(address caller) public {
        uint256 id = _toSubmitted(1_000e18);
        vm.assume(caller != client);
        vm.prank(caller);
        vm.expectRevert(DevSwapEscrow.NotClient.selector);
        escrow.releaseFunds(id);
    }
}
