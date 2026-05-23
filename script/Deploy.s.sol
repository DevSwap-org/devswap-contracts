// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DevSwapToken} from "../src/DevSwapToken.sol";
import {DevSwapEscrow} from "../src/DevSwapEscrow.sol";

/// @notice Deploys $DSWP + the USDT escrow. Reads addresses/keys from the environment so no
///         secrets live in the repo. Run against BSC testnet (97) first, then mainnet (56).
///
/// Usage:
///   forge script script/Deploy.s.sol:Deploy \
///     --rpc-url $BSC_TESTNET_RPC_URL --broadcast --verify -vvvv
///
/// Required env:
///   PRIVATE_KEY    deployer key (hex)
///   USDT_ADDRESS   settlement token (BSC mainnet USDT: 0x55d3...7955; supply a test token on 97)
///   PANCAKE_ROUTER PancakeSwap V2 router (mainnet: 0x10ED...024E)
///   FEE_RECIPIENT  receives the 1.5% owner fee
/// Optional env:
///   ESCROW_OWNER   owner of both contracts (defaults to deployer; set to a multisig for mainnet)
///   KEEPER_ADDRESS buyback keeper (defaults to unset/owner-only)
contract Deploy is Script {
    function run() external returns (DevSwapToken dswp, DevSwapEscrow escrow) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdt = vm.envAddress("USDT_ADDRESS");
        address router = vm.envAddress("PANCAKE_ROUTER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address owner = vm.envOr("ESCROW_OWNER", deployer);
        address keeper = vm.envOr("KEEPER_ADDRESS", address(0));

        require(usdt != address(0) && router != address(0) && feeRecipient != address(0), "bad env");

        vm.startBroadcast(pk);

        dswp = new DevSwapToken(owner);
        escrow = new DevSwapEscrow(usdt, address(dswp), router, feeRecipient, owner);

        // If a keeper was provided and the deployer still owns the escrow, wire it now.
        if (keeper != address(0) && owner == deployer) {
            escrow.setKeeper(keeper);
        }

        vm.stopBroadcast();

        console2.log("DevSwapToken ($DSWP):", address(dswp));
        console2.log("DevSwapEscrow:       ", address(escrow));
        console2.log("owner:               ", owner);
        console2.log("usdt:                ", usdt);
        console2.log("router:              ", router);
        console2.log("feeRecipient:        ", feeRecipient);
        console2.log("keeper:              ", keeper);
    }
}
