// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DevSwapToken} from "../src/DevSwapToken.sol";
import {DevSwapEscrow} from "../src/DevSwapEscrow.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";

/// @notice BSC TESTNET (97) deploy: a mock test-USDT (no canonical 18-dec USDT on testnet) +
///         $DSWP + escrow wired to the real testnet PancakeSwap V2 router. Mints test USDT to the
///         deployer and seeds a few Open tasks so the live app shows real on-chain data.
///         Inline buyback defers gracefully until a DSWP/USDT testnet pool exists.
///
/// Run: cd contracts && forge script script/DeployTestnet.s.sol:DeployTestnet \
///        --rpc-url $BSC_TESTNET_RPC_URL --broadcast -vvvv
contract DeployTestnet is Script {
    address constant PANCAKE_ROUTER_TESTNET = 0xD99D1c33F9fC3444f8101754aBC46c52416550D1;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);

        vm.startBroadcast(pk);

        MockERC20 usdt = new MockERC20("Test USDT", "USDT");
        DevSwapToken dswp = new DevSwapToken(deployer);
        DevSwapEscrow escrow =
            new DevSwapEscrow(address(usdt), address(dswp), PANCAKE_ROUTER_TESTNET, deployer, deployer);

        // Demo liquidity: mint test USDT to the deployer and seed Open tasks (deployer as client).
        usdt.mint(deployer, 100_000e18);
        usdt.approve(address(escrow), type(uint256).max);
        escrow.createTask(500e18, "ipfs://demo-build-landing-page");
        escrow.createTask(1_200e18, "ipfs://demo-smart-contract-audit");
        escrow.createTask(800e18, "ipfs://demo-react-dashboard");

        vm.stopBroadcast();

        console2.log("NEXT_PUBLIC_USDT_TESTNET  =", address(usdt));
        console2.log("NEXT_PUBLIC_DSWP_TESTNET  =", address(dswp));
        console2.log("NEXT_PUBLIC_ESCROW_TESTNET=", address(escrow));
        console2.log("deployer/owner            =", deployer);
    }
}
