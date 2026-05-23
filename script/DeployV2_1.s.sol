// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DevSwapToken} from "../src/DevSwapToken.sol";
import {DevSwapEscrowV2_1} from "../src/DevSwapEscrowV2_1.sol";

/// @notice Deploys DevSwapEscrowV2_1 (hardened arbiter: separation + 48h timelock + dispute
///         snapshot). Reuses the existing $DSWP when DSWP_ADDRESS is set; reads everything from the
///         environment so no secrets live in the repo. Testnet (97) first; mainnet (56) only after
///         the P5 gate (audit + multisig + timelock).
///
/// Usage:
///   forge script script/DeployV2_1.s.sol:DeployV2_1 \
///     --rpc-url $BSC_TESTNET_RPC_URL --broadcast --verify -vvvv
///
/// Required env:
///   PRIVATE_KEY     deployer key (hex)
///   USDT_ADDRESS    settlement token (BSC mainnet USDT 0x55d3...7955; a test token on 97)
///   PANCAKE_ROUTER  PancakeSwap V2 router (mainnet 0x10ED...024E; testnet 0xD99D...50D1)
///   FEE_RECIPIENT   receives the 1.5% owner fee
/// Optional env:
///   DSWP_ADDRESS    existing $DSWP to reuse (defaults to deploying a fresh token)
///   ESCROW_OWNER    owner of the contract (defaults to deployer; set to a multisig for mainnet)
///   KEEPER_ADDRESS  buyback / auto-release keeper (defaults to unset/owner-only)
///   INITIAL_ARBITER bootstrap arbiter registered at deploy with no timelock (defaults to deployer)
contract DeployV2_1 is Script {
    function run() external returns (DevSwapEscrowV2_1 escrow, address dswp) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address usdt = vm.envAddress("USDT_ADDRESS");
        address router = vm.envAddress("PANCAKE_ROUTER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");
        address owner = vm.envOr("ESCROW_OWNER", deployer);
        address keeper = vm.envOr("KEEPER_ADDRESS", address(0));
        address initialArbiter = vm.envOr("INITIAL_ARBITER", deployer);
        dswp = vm.envOr("DSWP_ADDRESS", address(0));

        require(usdt != address(0) && router != address(0) && feeRecipient != address(0), "bad env");

        vm.startBroadcast(pk);

        if (dswp == address(0)) {
            dswp = address(new DevSwapToken(owner));
        }
        escrow = new DevSwapEscrowV2_1(usdt, dswp, router, feeRecipient, owner, initialArbiter);

        if (keeper != address(0) && owner == deployer) {
            escrow.setKeeper(keeper);
        }

        vm.stopBroadcast();

        console2.log("DevSwapEscrowV2_1:", address(escrow));
        console2.log("dswp:           ", dswp);
        console2.log("owner:          ", owner);
        console2.log("initialArbiter: ", initialArbiter);
        console2.log("usdt:           ", usdt);
        console2.log("router:         ", router);
        console2.log("feeRecipient:   ", feeRecipient);
    }
}
