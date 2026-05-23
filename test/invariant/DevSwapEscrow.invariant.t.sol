// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DevSwapEscrow} from "../../src/DevSwapEscrow.sol";
import {DevSwapToken} from "../../src/DevSwapToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPancakeRouter} from "../mocks/MockPancakeRouter.sol";
import {EscrowHandler} from "./handlers/EscrowHandler.sol";

contract DevSwapEscrowInvariantTest is StdInvariant, Test {
    DevSwapEscrow internal escrow;
    MockERC20 internal usdt;
    DevSwapToken internal dswp;
    MockPancakeRouter internal router;
    EscrowHandler internal handler;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");

    function setUp() public {
        usdt = new MockERC20("Tether USD", "USDT");
        dswp = new DevSwapToken(owner);
        router = new MockPancakeRouter();
        vm.startPrank(owner);
        escrow = new DevSwapEscrow(address(usdt), address(dswp), address(router), feeRecipient, owner);
        dswp.mint(address(router), 50_000_000e18); // within 100M cap; ample router liquidity for buybacks
        vm.stopPrank();

        handler = new EscrowHandler(escrow, usdt, router, owner);

        bytes4[] memory selectors = new bytes4[](9);
        selectors[0] = EscrowHandler.createTask.selector;
        selectors[1] = EscrowHandler.acceptTask.selector;
        selectors[2] = EscrowHandler.submitTask.selector;
        selectors[3] = EscrowHandler.releaseFunds.selector;
        selectors[4] = EscrowHandler.cancelOpen.selector;
        selectors[5] = EscrowHandler.cancelTimedOut.selector;
        selectors[6] = EscrowHandler.dispute.selector;
        selectors[7] = EscrowHandler.resolve.selector;
        selectors[8] = EscrowHandler.buyback.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Core solvency: the escrow's USDT balance always equals the funds still owed to
    ///         live tasks plus the accumulated buyback reserve — no leak, no shortfall.
    function invariant_Solvency() public view {
        assertEq(usdt.balanceOf(address(escrow)), handler.ghostLocked() + escrow.buybackReserve());
    }

    /// @notice The buyback reserve can never exceed what the contract actually holds.
    function invariant_ReserveNeverExceedsBalance() public view {
        assertLe(escrow.buybackReserve(), usdt.balanceOf(address(escrow)));
    }
}
