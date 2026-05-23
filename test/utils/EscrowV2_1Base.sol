// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {DevSwapEscrowV2_1} from "../../src/DevSwapEscrowV2_1.sol";
import {DevSwapToken} from "../../src/DevSwapToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPancakeRouter} from "../mocks/MockPancakeRouter.sol";

/// @dev Common deployment + lifecycle helpers for the V2.1 unit/fuzz/invariant suites.
contract EscrowV2_1Base is Test {
    DevSwapEscrowV2_1 internal escrow;
    MockERC20 internal usdt;
    DevSwapToken internal dswp;
    MockPancakeRouter internal router;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal keeper = makeAddr("keeper");
    address internal client = makeAddr("client");
    address internal developer = makeAddr("developer");
    address internal arbiter = makeAddr("arbiter"); // bootstrapped initial arbiter

    uint256 internal constant FEE_BPS = 150;
    uint256 internal constant BUYBACK_BPS = 150;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant TIMELOCK = 48 hours;

    function setUp() public virtual {
        usdt = new MockERC20("Tether USD", "USDT");
        dswp = new DevSwapToken(owner);
        router = new MockPancakeRouter();

        vm.startPrank(owner);
        escrow = new DevSwapEscrowV2_1(address(usdt), address(dswp), address(router), feeRecipient, owner, arbiter);
        escrow.setKeeper(keeper);
        dswp.mint(address(router), 10_000_000e18);
        vm.stopPrank();

        usdt.mint(client, 1_000_000e18);
    }

    function _singleton(uint256 amount) internal pure returns (uint256[] memory a) {
        a = new uint256[](1);
        a[0] = amount;
    }

    function _createJob(uint256 amount) internal returns (uint256 id) {
        return _createJobMulti(_singleton(amount));
    }

    function _createJobMulti(uint256[] memory amts) internal returns (uint256 id) {
        uint256 total;
        for (uint256 i; i < amts.length; ++i) {
            total += amts[i];
        }
        vm.startPrank(client);
        usdt.approve(address(escrow), total);
        id = escrow.createJob(amts, "ipfs://spec");
        vm.stopPrank();
    }

    function _accept(uint256 id) internal {
        vm.prank(developer);
        escrow.acceptJob(id);
    }

    function _submit(uint256 id, uint256 index) internal {
        vm.prank(developer);
        escrow.submitMilestone(id, index, "ipfs://delivery");
    }

    function _toSubmitted(uint256 amount) internal returns (uint256 id) {
        id = _createJob(amount);
        _accept(id);
        _submit(id, 0);
    }

    function _toDisputed(uint256 amount) internal returns (uint256 id) {
        id = _toSubmitted(amount);
        vm.prank(client);
        escrow.raiseDispute(id, 0);
    }

    /// @dev Queue an arbiter, warp past the timelock, and execute (owner-driven).
    function _addArbiter(address a) internal {
        vm.startPrank(owner);
        escrow.queueArbiter(a);
        vm.warp(block.timestamp + TIMELOCK + 1);
        escrow.executeArbiter(a);
        vm.stopPrank();
    }

    function _expectedSplit(uint256 amount) internal pure returns (uint256 devNet, uint256 fee, uint256 buyback) {
        fee = (amount * FEE_BPS) / BPS;
        buyback = (amount * BUYBACK_BPS) / BPS;
        devNet = amount - fee - buyback;
    }
}
