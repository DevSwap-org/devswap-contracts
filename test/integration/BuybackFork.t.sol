// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {DevSwapToken} from "../../src/DevSwapToken.sol";
import {DevSwapEscrow} from "../../src/DevSwapEscrow.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Extended router surface needed only by this fork test (escrow itself uses the minimal one).
interface IRouterFull {
    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
}

/// @notice Exercises executeBuybackBurn against the REAL PancakeSwap V2 router + real USDT on a
///         BSC mainnet fork — the one path the unit/fuzz mocks cannot cover. Auto-skips when
///         BSC_RPC_URL is unset, so CI without an RPC stays green.
///
/// Run: BSC_RPC_URL=https://bsc-dataseed.binance.org forge test --match-contract BuybackFork -vvv
contract BuybackForkTest is Test {
    address internal constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address internal constant ROUTER = 0x10ED43C718714eb63d5aA57B78B54704E256024E;

    DevSwapToken internal dswp;
    DevSwapEscrow internal escrow;
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal client = makeAddr("client");
    address internal developer = makeAddr("developer");

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;
        vm.createSelectFork(rpc);
        forked = true;

        // this contract is owner of both -> can mint DSWP and call executeBuybackBurn
        dswp = new DevSwapToken(address(this));
        escrow = new DevSwapEscrow(USDT, address(dswp), ROUTER, feeRecipient, address(this));

        // seed a DSWP/USDT pool on the real router (1:1, deep enough for low slippage)
        uint256 poolUsdt = 200_000e18;
        uint256 poolDswp = 200_000e18;
        deal(USDT, address(this), poolUsdt);
        dswp.mint(address(this), poolDswp);
        IERC20(USDT).approve(ROUTER, poolUsdt);
        dswp.approve(ROUTER, poolDswp);
        IRouterFull(ROUTER)
            .addLiquidity(USDT, address(dswp), poolUsdt, poolDswp, 0, 0, address(this), block.timestamp + 1000);
    }

    function _runTaskToReleased(uint256 amount) internal returns (uint256 id) {
        deal(USDT, client, amount);
        vm.startPrank(client);
        IERC20(USDT).approve(address(escrow), amount);
        id = escrow.createTask(amount, "ipfs://spec");
        vm.stopPrank();
        vm.prank(developer);
        escrow.acceptTask(id);
        vm.prank(developer);
        escrow.submitTask(id, "ipfs://delivery");
        vm.prank(client);
        escrow.releaseFunds(id);
    }

    function test_RealInlineBuybackBurn_OnRelease() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        uint256 amount = 10_000e18;
        uint256 buyback = (amount * 150) / 10_000;
        uint256 devNet = amount - 2 * buyback;
        uint256 supplyBefore = dswp.totalSupply();

        _runTaskToReleased(amount); // Option C: inline buyback-burn against the REAL router

        assertEq(IERC20(USDT).balanceOf(developer), devNet, "developer paid");
        assertEq(escrow.buybackReserve(), 0, "burned inline, nothing deferred");
        assertEq(IERC20(USDT).balanceOf(address(escrow)), 0, "no USDT left in escrow");
        uint256 burned = supplyBefore - dswp.totalSupply();
        assertGt(burned, 0, "DSWP burned inline via real PancakeSwap");
        assertGe(burned, (buyback * 90) / 100, "burned ~ buyback within slippage/fee");
    }

    function test_RealDeferredThenBulkBurn() public {
        if (!forked) {
            vm.skip(true);
            return;
        }
        escrow.setAutoBuybackEnabled(false); // force the deferred path (owner == this)
        uint256 amount = 10_000e18;
        uint256 buyback = (amount * 150) / 10_000;
        uint256 devNet = amount - 2 * buyback;

        _runTaskToReleased(amount);
        assertEq(IERC20(USDT).balanceOf(developer), devNet, "developer paid regardless of market");
        assertEq(escrow.buybackReserve(), buyback, "1.5% deferred to reserve");

        address[] memory path = new address[](2);
        path[0] = USDT;
        path[1] = address(dswp);
        uint256 minOut = (IRouterFull(ROUTER).getAmountsOut(buyback, path)[1] * 99) / 100;
        uint256 supplyBefore = dswp.totalSupply();

        escrow.executeBuybackBurn(minOut, block.timestamp + 1000); // real bulk swap+burn
        assertEq(escrow.buybackReserve(), 0, "reserve drained");
        assertGe(supplyBefore - dswp.totalSupply(), minOut, "bulk burn >= minOut");
    }
}
