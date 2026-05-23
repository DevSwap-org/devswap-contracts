// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DevSwapToken} from "../src/DevSwapToken.sol";
import {DevSwapEscrow} from "../src/DevSwapEscrow.sol";
import {MockERC20} from "../test/mocks/MockERC20.sol";
import {MockPancakeRouter} from "../test/mocks/MockPancakeRouter.sol";

/// @notice LOCAL-ONLY deploy for an anvil node: deploys mock USDT + mock router alongside the real
///         DevSwapToken/Escrow, funds the default anvil accounts, and seeds tasks across every
///         status so the dApp has real on-chain data to read. NOT for testnet/mainnet.
///
/// Run: anvil &  then
///   forge script script/DeployLocal.s.sol:DeployLocal --rpc-url http://127.0.0.1:8545 --broadcast
contract DeployLocal is Script {
    // Standard anvil deterministic keys
    uint256 internal constant PK0 = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80; // owner/deployer
    uint256 internal constant PK1 = 0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d; // client
    uint256 internal constant PK2 = 0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a; // developer

    function run() external {
        address owner = vm.addr(PK0);
        address client = vm.addr(PK1);
        address developer = vm.addr(PK2);

        // --- deploy + fund (as owner) ---
        vm.startBroadcast(PK0);
        MockERC20 usdt = new MockERC20("Tether USD", "USDT");
        DevSwapToken dswp = new DevSwapToken(owner);
        MockPancakeRouter router = new MockPancakeRouter();
        DevSwapEscrow escrow = new DevSwapEscrow(address(usdt), address(dswp), address(router), owner, owner);
        escrow.setKeeper(owner);
        dswp.mint(address(router), 5_000_000e18); // router buyback liquidity
        usdt.mint(owner, 100_000e18);
        usdt.mint(client, 100_000e18);
        usdt.mint(developer, 100_000e18);
        vm.stopBroadcast();

        // --- seed tasks across statuses ---
        // #0 Open
        _create(escrow, usdt, 1_000e18);
        // #1 Accepted
        uint256 t1 = _create(escrow, usdt, 2_000e18);
        _accept(escrow, t1);
        // #2 Submitted
        uint256 t2 = _create(escrow, usdt, 3_000e18);
        _accept(escrow, t2);
        _submit(escrow, t2);
        // #3 Disputed
        uint256 t3 = _create(escrow, usdt, 1_500e18);
        _accept(escrow, t3);
        _submit(escrow, t3);
        vm.broadcast(PK1);
        escrow.raiseDispute(t3);
        // #4 Released
        uint256 t4 = _create(escrow, usdt, 5_000e18);
        _accept(escrow, t4);
        _submit(escrow, t4);
        vm.broadcast(PK1);
        escrow.releaseFunds(t4);

        console2.log("CHAIN_ID         ", block.chainid);
        console2.log("NEXT_PUBLIC_USDT_LOCAL  =", address(usdt));
        console2.log("NEXT_PUBLIC_DSWP_LOCAL  =", address(dswp));
        console2.log("NEXT_PUBLIC_ESCROW_LOCAL=", address(escrow));
        console2.log("owner/client/developer:", owner, client, developer);
    }

    function _create(DevSwapEscrow escrow, MockERC20 usdt, uint256 amount) internal returns (uint256 id) {
        vm.startBroadcast(PK1);
        usdt.approve(address(escrow), amount);
        id = escrow.createTask(amount, "ipfs://stub-local-spec");
        vm.stopBroadcast();
    }

    function _accept(DevSwapEscrow escrow, uint256 id) internal {
        vm.broadcast(PK2);
        escrow.acceptTask(id);
    }

    function _submit(DevSwapEscrow escrow, uint256 id) internal {
        vm.broadcast(PK2);
        escrow.submitTask(id, "ipfs://stub-local-delivery");
    }
}
