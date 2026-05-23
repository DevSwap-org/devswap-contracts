// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Minimal 18-decimal mintable ERC20 used to stand in for BSC USDT in tests.
/// @dev BSC USDT has 18 decimals (unlike Ethereum's 6) and returns bool on transfer.
contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s) ERC20(n, s) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
