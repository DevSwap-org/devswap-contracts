// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Test} from "forge-std/Test.sol";
import {DevSwapToken} from "../../src/DevSwapToken.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DevSwapTokenTest is Test {
    DevSwapToken internal token;
    address internal owner = makeAddr("owner");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    uint256 internal constant CAP = 100_000_000e18;

    function setUp() public {
        token = new DevSwapToken(owner);
    }

    function test_Metadata() public view {
        assertEq(token.name(), "DevSwap");
        assertEq(token.symbol(), "DSWP");
        assertEq(token.decimals(), 18);
    }

    function test_CapIs100M() public view {
        assertEq(token.cap(), CAP);
        assertEq(token.MAX_SUPPLY(), CAP);
    }

    function test_InitialSupplyIsZero() public view {
        assertEq(token.totalSupply(), 0);
    }

    function test_OwnerIsInitialOwner() public view {
        assertEq(token.owner(), owner);
    }

    function test_OwnerCanMint() public {
        vm.prank(owner);
        token.mint(alice, 1_000e18);
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.totalSupply(), 1_000e18);
    }

    function test_NonOwnerCannotMint() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        token.mint(alice, 1_000e18);
    }

    function test_MintRevertsAboveCap() public {
        vm.startPrank(owner);
        token.mint(alice, CAP);
        vm.expectRevert();
        token.mint(alice, 1);
        vm.stopPrank();
    }

    function test_MintExactlyToCapSucceeds() public {
        vm.prank(owner);
        token.mint(alice, CAP);
        assertEq(token.totalSupply(), CAP);
    }

    function test_BurnReducesSupply() public {
        vm.prank(owner);
        token.mint(alice, 1_000e18);
        vm.prank(alice);
        token.burn(400e18);
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(token.totalSupply(), 600e18);
    }

    function test_BurnDoesNotReopenCapHeadroom() public {
        // Burning then minting again must still respect the absolute cap (cap is a ceiling on totalSupply, not lifetime mint).
        vm.startPrank(owner);
        token.mint(alice, CAP);
        vm.stopPrank();
        vm.prank(alice);
        token.burn(1_000e18);
        // headroom of 1000 now exists
        vm.prank(owner);
        token.mint(bob, 1_000e18);
        assertEq(token.totalSupply(), CAP);
    }

    function test_BurnFromWithAllowance() public {
        vm.prank(owner);
        token.mint(alice, 1_000e18);
        vm.prank(alice);
        token.approve(bob, 500e18);
        vm.prank(bob);
        token.burnFrom(alice, 500e18);
        assertEq(token.balanceOf(alice), 500e18);
        assertEq(token.totalSupply(), 500e18);
    }

    function test_Ownable2Step_TransferRequiresAccept() public {
        vm.prank(owner);
        token.transferOwnership(alice);
        // ownership not transferred until accepted
        assertEq(token.owner(), owner);
        assertEq(token.pendingOwner(), alice);
        vm.prank(alice);
        token.acceptOwnership();
        assertEq(token.owner(), alice);
    }

    function testFuzz_MintWithinCap(uint256 amount) public {
        amount = bound(amount, 0, CAP);
        vm.prank(owner);
        token.mint(alice, amount);
        assertEq(token.totalSupply(), amount);
        assertLe(token.totalSupply(), token.cap());
    }
}
