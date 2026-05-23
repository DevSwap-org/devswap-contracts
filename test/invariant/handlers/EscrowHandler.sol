// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {DevSwapEscrow} from "../../../src/DevSwapEscrow.sol";
import {MockERC20} from "../../mocks/MockERC20.sol";
import {MockPancakeRouter} from "../../mocks/MockPancakeRouter.sol";

/// @notice Stateful actor for invariant testing. Drives random-but-valid escrow lifecycles
///         across a small set of disjoint clients/developers and tracks `ghostLocked`, the sum
///         of USDT that *should* still be held against live (non-terminal) tasks.
contract EscrowHandler is Test {
    DevSwapEscrow internal escrow;
    MockERC20 internal usdt;
    MockPancakeRouter internal router;
    address internal owner;

    address[3] internal clients;
    address[3] internal devs;
    uint256[] internal taskIds;

    uint256 public ghostLocked; // read by the invariant

    uint256 internal constant MAX_TASKS = 20;
    uint256 internal constant MAX_AMOUNT = 1e24;

    constructor(DevSwapEscrow _escrow, MockERC20 _usdt, MockPancakeRouter _router, address _owner) {
        escrow = _escrow;
        usdt = _usdt;
        router = _router;
        owner = _owner;
        clients = [makeAddr("c0"), makeAddr("c1"), makeAddr("c2")];
        devs = [makeAddr("d0"), makeAddr("d1"), makeAddr("d2")];
    }

    function _find(DevSwapEscrow.Status s, uint256 seed) internal view returns (bool, uint256) {
        uint256 n = taskIds.length;
        for (uint256 i = 0; i < n; i++) {
            uint256 id = taskIds[(seed + i) % n];
            if (escrow.getTask(id).status == s) return (true, id);
        }
        return (false, 0);
    }

    function createTask(uint256 amount, uint256 seed) external {
        if (taskIds.length >= MAX_TASKS) return;
        amount = bound(amount, 1, MAX_AMOUNT);
        address c = clients[seed % 3];
        usdt.mint(c, amount);
        vm.startPrank(c);
        usdt.approve(address(escrow), amount);
        uint256 id = escrow.createTask(amount, "");
        vm.stopPrank();
        taskIds.push(id);
        ghostLocked += amount;
    }

    function acceptTask(uint256 seed, uint256 dseed) external {
        (bool ok, uint256 id) = _find(DevSwapEscrow.Status.Open, seed);
        if (!ok) return;
        vm.prank(devs[dseed % 3]);
        escrow.acceptTask(id);
    }

    function submitTask(uint256 seed) external {
        (bool ok, uint256 id) = _find(DevSwapEscrow.Status.Accepted, seed);
        if (!ok) return;
        vm.prank(escrow.getTask(id).developer);
        escrow.submitTask(id, "");
    }

    function releaseFunds(uint256 seed) external {
        (bool ok, uint256 id) = _find(DevSwapEscrow.Status.Submitted, seed);
        if (!ok) return;
        DevSwapEscrow.Task memory t = escrow.getTask(id);
        vm.prank(t.client);
        escrow.releaseFunds(id);
        ghostLocked -= t.amount;
    }

    function cancelOpen(uint256 seed) external {
        (bool ok, uint256 id) = _find(DevSwapEscrow.Status.Open, seed);
        if (!ok) return;
        DevSwapEscrow.Task memory t = escrow.getTask(id);
        vm.prank(t.client);
        escrow.cancelTask(id);
        ghostLocked -= t.amount;
    }

    function cancelTimedOut(uint256 seed, uint256 dt) external {
        (bool ok, uint256 id) = _find(DevSwapEscrow.Status.Accepted, seed);
        if (!ok) return;
        vm.warp(block.timestamp + escrow.submitTimeout() + bound(dt, 1, 10 days));
        DevSwapEscrow.Task memory t = escrow.getTask(id);
        vm.prank(t.client);
        escrow.cancelTask(id);
        ghostLocked -= t.amount;
    }

    function dispute(uint256 seed, uint256 who) external {
        (bool ok, uint256 id) = _find(DevSwapEscrow.Status.Submitted, seed);
        if (!ok) (ok, id) = _find(DevSwapEscrow.Status.Accepted, seed);
        if (!ok) return;
        DevSwapEscrow.Task memory t = escrow.getTask(id);
        vm.prank(who % 2 == 0 ? t.client : t.developer);
        escrow.raiseDispute(id);
    }

    function resolve(uint256 seed, bool pay) external {
        (bool ok, uint256 id) = _find(DevSwapEscrow.Status.Disputed, seed);
        if (!ok) return;
        DevSwapEscrow.Task memory t = escrow.getTask(id);
        vm.prank(owner);
        escrow.resolveDispute(id, pay);
        ghostLocked -= t.amount;
    }

    function buyback() external {
        if (escrow.buybackReserve() == 0) return;
        router.setRate(1, 1);
        vm.prank(owner);
        escrow.executeBuybackBurn(0, block.timestamp + 1);
    }
}
