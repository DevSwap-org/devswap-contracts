// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @notice Malicious 18-decimal ERC20 that re-enters a target on every transfer.
/// @dev Stands in for USDT to prove the escrow's ReentrancyGuard + CEI ordering hold.
///      When armed, `_update` calls `reenterTarget` with `reenterData`; if that inner call
///      reverts (e.g. the ReentrancyGuard fires), the original revert is bubbled up so tests
///      can assert on the exact error.
contract ReentrantERC20 is ERC20 {
    address public reenterTarget;
    bytes public reenterData;
    bool private _attacking;

    constructor() ERC20("ReentrantUSD", "rUSD") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address target, bytes calldata data) external {
        reenterTarget = target;
        reenterData = data;
    }

    function disarm() external {
        reenterTarget = address(0);
        reenterData = "";
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (reenterTarget != address(0) && !_attacking) {
            _attacking = true;
            (bool ok, bytes memory ret) = reenterTarget.call(reenterData);
            _attacking = false;
            if (!ok) {
                // bubble the inner revert reason (e.g. ReentrancyGuardReentrantCall)
                assembly {
                    revert(add(ret, 0x20), mload(ret))
                }
            }
        }
    }
}
