// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Capped} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Capped.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

/// @title DevSwapToken ($DSWP)
/// @notice Platform utility token for DevSwap: a BEP-20, burnable, supply-capped ERC20.
/// @dev Burnable enables the escrow's buyback-and-burn (escrow calls `burn()` on tokens it bought).
///      The cap is an absolute ceiling on `totalSupply` — burning frees headroom but supply can never
///      exceed `MAX_SUPPLY`. Distribution/vesting is handled in a later phase via owner `mint`.
contract DevSwapToken is ERC20, ERC20Burnable, ERC20Capped, Ownable2Step {
    /// @notice Absolute maximum supply: 100,000,000 DSWP (18 decimals).
    uint256 public constant MAX_SUPPLY = 100_000_000e18;

    /// @param initialOwner Address that receives ownership (later a multisig/timelock).
    constructor(address initialOwner) ERC20("DevSwap", "DSWP") ERC20Capped(MAX_SUPPLY) Ownable(initialOwner) {}

    /// @notice Mint new tokens up to the cap. Restricted to the owner.
    /// @dev Reverts via ERC20Capped if `totalSupply + amount` would exceed MAX_SUPPLY.
    /// @param to Recipient of the minted tokens.
    /// @param amount Amount to mint (in wei, 18 decimals).
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /// @dev Resolves the diamond inheritance of `_update` between ERC20 and ERC20Capped.
    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Capped) {
        super._update(from, to, value);
    }
}
