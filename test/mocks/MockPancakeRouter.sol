// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {IPancakeRouter02} from "../../src/interfaces/IPancakeRouter02.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Test double for PancakeSwap V2 router. Pulls path[0] from the caller and sends
///         path[last] to `to` at a configurable rate. Can be forced to revert to simulate
///         a failing swap (used to prove buyback failure does not block developer payment).
/// @dev Must be pre-funded with the output token. Not for production use.
contract MockPancakeRouter is IPancakeRouter02 {
    uint256 public rateNum = 1; // out = in * rateNum / rateDen
    uint256 public rateDen = 1;
    bool public shouldRevert;

    function setRate(uint256 n, uint256 d) external {
        rateNum = n;
        rateDen = d;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function _out(uint256 amountIn) internal view returns (uint256) {
        return (amountIn * rateNum) / rateDen;
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override returns (uint256[] memory amounts) {
        require(!shouldRevert, "ROUTER_FAIL");
        require(block.timestamp <= deadline, "EXPIRED");
        require(path.length >= 2, "BAD_PATH");
        require(IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn), "TRANSFER_FROM_FAILED");
        uint256 out = _out(amountIn);
        require(out >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        require(IERC20(path[path.length - 1]).transfer(to, out), "TRANSFER_FAILED");
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = out;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        override
        returns (uint256[] memory amounts)
    {
        require(!shouldRevert, "ROUTER_FAIL"); // simulate a fully-down router (quote also fails)
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        amounts[path.length - 1] = _out(amountIn);
    }

    function factory() external view override returns (address) {
        return address(this);
    }

    // forge-lint: disable-next-line(mixed-case-function) -- WETH() is a fixed PancakeSwap/Uniswap interface name
    function WETH() external pure override returns (address) {
        return address(0);
    }
}
