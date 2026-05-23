// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {DevSwapEscrow} from "../../src/DevSwapEscrow.sol";
import {DevSwapToken} from "../../src/DevSwapToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPancakeRouter} from "../mocks/MockPancakeRouter.sol";

/// @dev Common deployment + lifecycle helpers shared by unit/fuzz/invariant suites.
contract EscrowBase is Test {
    DevSwapEscrow internal escrow;
    MockERC20 internal usdt;
    DevSwapToken internal dswp;
    MockPancakeRouter internal router;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal keeper = makeAddr("keeper");
    address internal client = makeAddr("client");
    address internal developer = makeAddr("developer");

    uint256 internal constant FEE_BPS = 150;
    uint256 internal constant BUYBACK_BPS = 150;
    uint256 internal constant BPS = 10_000;

    function setUp() public virtual {
        usdt = new MockERC20("Tether USD", "USDT");
        dswp = new DevSwapToken(owner);
        router = new MockPancakeRouter();

        vm.startPrank(owner);
        escrow = new DevSwapEscrow(address(usdt), address(dswp), address(router), feeRecipient, owner);
        escrow.setKeeper(keeper);
        dswp.mint(address(router), 10_000_000e18); // router liquidity for swaps
        vm.stopPrank();

        usdt.mint(client, 1_000_000e18);
    }

    function _createTask(uint256 amount) internal returns (uint256 id) {
        vm.startPrank(client);
        usdt.approve(address(escrow), amount);
        id = escrow.createTask(amount, "ipfs://spec");
        vm.stopPrank();
    }

    function _accept(uint256 id) internal {
        vm.prank(developer);
        escrow.acceptTask(id);
    }

    function _submit(uint256 id) internal {
        vm.prank(developer);
        escrow.submitTask(id, "ipfs://delivery");
    }

    function _toSubmitted(uint256 amount) internal returns (uint256 id) {
        id = _createTask(amount);
        _accept(id);
        _submit(id);
    }

    function _expectedSplit(uint256 amount) internal pure returns (uint256 devNet, uint256 fee, uint256 buyback) {
        fee = (amount * FEE_BPS) / BPS;
        buyback = (amount * BUYBACK_BPS) / BPS;
        devNet = amount - fee - buyback;
    }
}
