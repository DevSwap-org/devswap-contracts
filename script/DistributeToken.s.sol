// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {DevSwapToken} from "../src/DevSwapToken.sol";
import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

/// @notice Deploys $DSWP and mints the full 100M supply per the tokenomics split, putting the
///         team allocation behind an OpenZeppelin linear VestingWallet. Run by the deployer (who
///         temporarily owns the token to mint), then ownership is handed to the configured owner
///         (a multisig on mainnet) via Ownable2Step (owner must call acceptOwnership()).
///
/// Split (of 100,000,000 DSWP):
///   50% activity mining   -> ACTIVITY_DISTRIBUTOR (or TREASURY)
///   25% liquidity         -> TREASURY (provisioned into the PancakeSwap LP, then LP locked)
///   15% team              -> VestingWallet(TEAM_BENEFICIARY) linear over TEAM_VEST_DURATION
///   10% community airdrop -> AIRDROP_DISTRIBUTOR
///
/// Required env: PRIVATE_KEY, TREASURY, AIRDROP_DISTRIBUTOR, TEAM_BENEFICIARY
/// Optional env: ESCROW_OWNER (default deployer), ACTIVITY_DISTRIBUTOR (default TREASURY),
///               TEAM_VEST_START (default now), TEAM_VEST_DURATION (default 4y)
contract DistributeToken is Script {
    uint256 internal constant TOTAL = 100_000_000e18;
    uint256 internal constant ACTIVITY = 50_000_000e18;
    uint256 internal constant LIQUIDITY = 25_000_000e18;
    uint256 internal constant TEAM = 15_000_000e18;
    uint256 internal constant AIRDROP = 10_000_000e18;

    function run() external returns (DevSwapToken dswp, VestingWallet teamVesting) {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address owner = vm.envOr("ESCROW_OWNER", deployer);
        address treasury = vm.envAddress("TREASURY");
        address airdrop = vm.envAddress("AIRDROP_DISTRIBUTOR");
        address activity = vm.envOr("ACTIVITY_DISTRIBUTOR", treasury);
        address teamBeneficiary = vm.envAddress("TEAM_BENEFICIARY");
        uint64 vestStart = uint64(vm.envOr("TEAM_VEST_START", block.timestamp));
        uint64 vestDuration = uint64(vm.envOr("TEAM_VEST_DURATION", uint256(4 * 365 days)));

        require(treasury != address(0) && airdrop != address(0) && teamBeneficiary != address(0), "bad env");

        vm.startBroadcast(pk);

        dswp = new DevSwapToken(deployer); // deployer mints, then hands ownership over

        teamVesting = new VestingWallet(teamBeneficiary, vestStart, vestDuration);

        dswp.mint(activity, ACTIVITY);
        dswp.mint(treasury, LIQUIDITY);
        dswp.mint(address(teamVesting), TEAM);
        dswp.mint(airdrop, AIRDROP);

        if (owner != deployer) {
            dswp.transferOwnership(owner); // 2-step: owner must acceptOwnership()
        }

        vm.stopBroadcast();

        require(dswp.totalSupply() == TOTAL, "supply != 100M");

        console2.log("DevSwapToken ($DSWP):", address(dswp));
        console2.log("team VestingWallet:  ", address(teamVesting));
        console2.log("activity ->", activity, ACTIVITY);
        console2.log("liquidity ->", treasury, LIQUIDITY);
        console2.log("team ->", address(teamVesting), TEAM);
        console2.log("airdrop ->", airdrop, AIRDROP);
        console2.log("pending owner (accept 2-step):", owner);
    }
}
