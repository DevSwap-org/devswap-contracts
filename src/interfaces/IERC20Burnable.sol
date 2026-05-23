// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IERC20Burnable
/// @notice IERC20 extended with `burn`, used by the escrow to burn bought-back $DSWP.
interface IERC20Burnable is IERC20 {
    /// @notice Destroys `amount` tokens from the caller's balance.
    function burn(uint256 amount) external;
}
