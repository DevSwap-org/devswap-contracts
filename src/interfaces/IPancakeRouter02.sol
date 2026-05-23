// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

/// @title IPancakeRouter02
/// @notice Minimal PancakeSwap V2 router surface used by DevSwapEscrow for buyback-and-burn.
/// @dev Only the functions the escrow actually calls are declared, to keep the trust surface small.
interface IPancakeRouter02 {
    /// @notice Swaps an exact amount of input tokens for as many output tokens as possible.
    /// @param amountIn Exact amount of input tokens to send.
    /// @param amountOutMin Minimum acceptable amount of output tokens (slippage guard).
    /// @param path Token swap path; path[0] is input, path[last] is output.
    /// @param to Recipient of the output tokens.
    /// @param deadline Unix timestamp after which the transaction reverts.
    /// @return amounts Input/output amounts for each step of the path.
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Read-only quote helper, useful for keepers computing amountOutMin off-chain.
    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts);

    function factory() external view returns (address);

    function WETH() external view returns (address);
}
