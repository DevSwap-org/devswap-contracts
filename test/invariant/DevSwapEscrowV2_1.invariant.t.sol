// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {DevSwapEscrowV2_1} from "../../src/DevSwapEscrowV2_1.sol";
import {DevSwapToken} from "../../src/DevSwapToken.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockPancakeRouter} from "../mocks/MockPancakeRouter.sol";
import {EscrowV2_1Handler} from "./handlers/EscrowV2_1Handler.sol";

contract DevSwapEscrowV2_1InvariantTest is StdInvariant, Test {
    DevSwapEscrowV2_1 internal escrow;
    MockERC20 internal usdt;
    DevSwapToken internal dswp;
    MockPancakeRouter internal router;
    EscrowV2_1Handler internal handler;

    address internal owner = makeAddr("owner");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal arbiter = makeAddr("arbiter");

    function setUp() public {
        usdt = new MockERC20("Tether USD", "USDT");
        dswp = new DevSwapToken(owner);
        router = new MockPancakeRouter();
        vm.startPrank(owner);
        escrow = new DevSwapEscrowV2_1(address(usdt), address(dswp), address(router), feeRecipient, owner, arbiter);
        dswp.mint(address(router), 50_000_000e18);
        vm.stopPrank();

        handler = new EscrowV2_1Handler(escrow, usdt, router, owner, arbiter);

        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = EscrowV2_1Handler.createJob.selector;
        selectors[1] = EscrowV2_1Handler.acceptJob.selector;
        selectors[2] = EscrowV2_1Handler.submitMilestone.selector;
        selectors[3] = EscrowV2_1Handler.releaseMilestone.selector;
        selectors[4] = EscrowV2_1Handler.claimMilestone.selector;
        selectors[5] = EscrowV2_1Handler.cancelOpen.selector;
        selectors[6] = EscrowV2_1Handler.cancelTimedOut.selector;
        selectors[7] = EscrowV2_1Handler.dispute.selector;
        selectors[8] = EscrowV2_1Handler.resolve.selector;
        selectors[9] = EscrowV2_1Handler.buyback.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// @notice Solvency: escrow USDT balance == funds owed to live milestones + buyback reserve.
    function invariant_Solvency() public view {
        assertEq(usdt.balanceOf(address(escrow)), handler.ghostLocked() + escrow.buybackReserve());
    }

    function invariant_ReserveNeverExceedsBalance() public view {
        assertLe(escrow.buybackReserve(), usdt.balanceOf(address(escrow)));
    }
}
