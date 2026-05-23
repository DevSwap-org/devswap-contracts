// SPDX-License-Identifier: MIT
pragma solidity =0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IPancakeRouter02} from "./interfaces/IPancakeRouter02.sol";
import {IERC20Burnable} from "./interfaces/IERC20Burnable.sol";

/// @title DevSwapEscrowV2_1
/// @notice Milestone escrow with on-chain reputation and a HARDENED tier-2 dispute system.
///         Supersedes DevSwapEscrowV2 (deprecated): the owner is no longer an implicit arbiter,
///         adding an arbiter is behind a 48h timelock, and each dispute snapshots its open time so
///         an arbiter added after a dispute is raised cannot resolve it.
/// @dev Separation of powers: the owner manages the arbiter registry but cannot itself resolve a
///      dispute unless explicitly registered as an arbiter. Adding an arbiter = queue -> wait
///      ARBITER_TIMELOCK -> execute (anti "puppet arbiter mid-dispute"); removal is immediate
///      (revoke-fast). Eligibility at resolution: isArbiter[caller] && arbiterSince[caller] <=
///      disputeRaisedAt. Money model + security otherwise identical to V2: 97/1.5/1.5 split,
///      Option-C inline buyback with safe deferral, CEI + ReentrancyGuard + SafeERC20 +
///      Ownable2Step + Pausable, burn() (never address(0)). Assumes non-fee-on-transfer USDT.
contract DevSwapEscrowV2_1 is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- types
    enum JobStatus {
        None,
        Open,
        Accepted,
        Completed,
        Cancelled
    }

    enum MilestoneStatus {
        None,
        Funded,
        Submitted,
        Released,
        Cancelled,
        Disputed
    }

    struct Milestone {
        uint256 amount;
        MilestoneStatus status;
        uint64 submittedAt;
        uint64 disputeRaisedAt; // snapshot of when this milestone's dispute was opened (0 if none)
        string deliveryHash;
    }

    struct Job {
        address client;
        address developer;
        JobStatus status;
        uint64 createdAt;
        uint64 acceptedAt;
        uint32 milestoneCount;
        uint32 terminalCount;
        string metadataHash;
    }

    struct Reputation {
        uint64 jobsPosted;
        uint64 jobsAccepted;
        uint64 milestonesPaid;
        uint64 disputesRaised;
        uint64 disputesLost;
        uint256 totalEarned;
        uint256 totalSpent;
    }

    // --------------------------------------------------------------------- constants
    uint256 public constant FEE_BPS = 150;
    uint256 public constant BUYBACK_BPS = 150;
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_TIMEOUT = 1 days;
    uint256 public constant MAX_TIMEOUT = 60 days;
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000;
    uint32 public constant MAX_MILESTONES = 20;
    uint256 public constant ARBITER_TIMELOCK = 48 hours; // delay before a queued arbiter goes live

    // --------------------------------------------------------------------- storage
    IERC20 public immutable usdt;
    IERC20Burnable public immutable dswp;
    IPancakeRouter02 public immutable router;

    address public feeRecipient;
    address public keeper;
    uint256 public submitTimeout;
    uint256 public reviewTimeout;
    uint256 public buybackReserve;
    uint256 public nextJobId;
    bool public autoBuybackEnabled;
    uint256 public buybackSlippageBps;

    mapping(uint256 => Job) private _jobs;
    mapping(uint256 => mapping(uint256 => Milestone)) private _milestones;
    mapping(address => Reputation) private _reputation;

    // Arbiter registry (separation of powers; the owner is NOT an implicit arbiter):
    mapping(address => bool) public isArbiter; // current membership
    mapping(address => uint256) public arbiterSince; // timestamp registered (0 = never/removed)
    mapping(address => uint256) public arbiterQueuedAt; // timestamp queued for add (0 = not queued)

    // --------------------------------------------------------------------- events
    event JobCreated(
        uint256 indexed jobId, address indexed client, uint256 totalAmount, uint32 milestoneCount, string metadataHash
    );
    event JobAccepted(uint256 indexed jobId, address indexed developer);
    event JobClosed(uint256 indexed jobId, JobStatus status);
    event MilestoneSubmitted(uint256 indexed jobId, uint256 indexed index, string deliveryHash);
    event MilestoneReleased(
        uint256 indexed jobId,
        uint256 indexed index,
        address developer,
        uint256 developerNet,
        uint256 fee,
        uint256 buyback
    );
    event MilestoneAutoReleased(uint256 indexed jobId, uint256 indexed index, address indexed by);
    event MilestoneCancelled(uint256 indexed jobId, uint256 indexed index, address client, uint256 amount);
    event DisputeRaised(uint256 indexed jobId, uint256 indexed index, address indexed by, uint64 raisedAt);
    event DisputeResolved(uint256 indexed jobId, uint256 indexed index, address indexed arbiter, bool paidDeveloper);
    event BuybackBurned(uint256 usdtSpent, uint256 dswpBurned);
    event BuybackDeferred(uint256 indexed jobId, uint256 indexed index, uint256 usdtAmount);
    event AutoBuybackToggled(bool enabled);
    event BuybackSlippageUpdated(uint256 bps);
    event FeeRecipientUpdated(address indexed newRecipient);
    event KeeperUpdated(address indexed newKeeper);
    event SubmitTimeoutUpdated(uint256 newTimeout);
    event ReviewTimeoutUpdated(uint256 newTimeout);
    event ArbiterQueued(address indexed arbiter, uint256 executableAt);
    event ArbiterAdded(address indexed arbiter, uint256 since);
    event ArbiterRemoved(address indexed arbiter);
    event ArbiterChangeCancelled(address indexed arbiter);

    // --------------------------------------------------------------------- errors
    error ZeroAddress();
    error ZeroAmount();
    error InvalidMilestoneCount();
    error InvalidJobStatus();
    error InvalidMilestoneStatus();
    error NotClient();
    error NotDeveloper();
    error NotParty();
    error NotAuthorized();
    error ClientCannotAcceptOwnJob();
    error CannotCancel();
    error ReviewWindowOpen();
    error NothingToBuyback();
    error InvalidTimeout();
    error InvalidSlippage();
    error OnlySelf();
    error NotArbiter();
    error ArbiterNotEligible();
    error AlreadyArbiter();
    error NotQueued();
    error TimelockNotElapsed();

    // --------------------------------------------------------------------- constructor
    constructor(
        address _usdt,
        address _dswp,
        address _router,
        address _feeRecipient,
        address initialOwner,
        address initialArbiter
    ) Ownable(initialOwner) {
        if (_usdt == address(0) || _dswp == address(0) || _router == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        usdt = IERC20(_usdt);
        dswp = IERC20Burnable(_dswp);
        router = IPancakeRouter02(_router);
        feeRecipient = _feeRecipient;
        submitTimeout = 14 days;
        reviewTimeout = 7 days;
        autoBuybackEnabled = true;
        buybackSlippageBps = 300;

        // Clean bootstrap: the deployer designates one initial arbiter immediately (no timelock),
        // so disputes can be resolved from day one without waiting out the 48h queue.
        if (initialArbiter != address(0)) {
            isArbiter[initialArbiter] = true;
            arbiterSince[initialArbiter] = block.timestamp;
            emit ArbiterAdded(initialArbiter, block.timestamp);
        }
    }

    // --------------------------------------------------------------------- modifiers
    modifier onlyArbiter() {
        _checkArbiter();
        _;
    }

    /// @dev The owner is NOT an implicit arbiter — it manages the registry but cannot resolve a
    ///      dispute unless explicitly registered (separation of powers).
    function _checkArbiter() internal view {
        if (!isArbiter[msg.sender]) revert NotArbiter();
    }

    // --------------------------------------------------------------------- lifecycle
    function createJob(uint256[] calldata milestoneAmounts, string calldata metadataHash)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 jobId)
    {
        uint256 n = milestoneAmounts.length;
        if (n == 0 || n > MAX_MILESTONES) revert InvalidMilestoneCount();
        // n is bounded by MAX_MILESTONES (20) above, so the uint32 cast cannot truncate.
        uint32 count = uint32(n); // forge-lint: disable-line(unsafe-typecast)

        jobId = nextJobId++;
        Job storage j = _jobs[jobId];
        j.client = msg.sender;
        j.status = JobStatus.Open;
        j.createdAt = uint64(block.timestamp);
        j.milestoneCount = count;
        j.metadataHash = metadataHash;

        uint256 total = 0;
        for (uint256 i; i < n; ++i) {
            uint256 amt = milestoneAmounts[i];
            if (amt == 0) revert ZeroAmount();
            Milestone storage m = _milestones[jobId][i];
            m.amount = amt;
            m.status = MilestoneStatus.Funded;
            total += amt;
        }

        _reputation[msg.sender].jobsPosted += 1;
        emit JobCreated(jobId, msg.sender, total, count, metadataHash);
        usdt.safeTransferFrom(msg.sender, address(this), total);
    }

    function acceptJob(uint256 jobId) external whenNotPaused {
        Job storage j = _jobs[jobId];
        if (j.status != JobStatus.Open) revert InvalidJobStatus();
        if (msg.sender == j.client) revert ClientCannotAcceptOwnJob();
        j.developer = msg.sender;
        j.acceptedAt = uint64(block.timestamp);
        j.status = JobStatus.Accepted;
        _reputation[msg.sender].jobsAccepted += 1;
        emit JobAccepted(jobId, msg.sender);
    }

    function submitMilestone(uint256 jobId, uint256 index, string calldata deliveryHash) external whenNotPaused {
        Job storage j = _jobs[jobId];
        if (j.status != JobStatus.Accepted) revert InvalidJobStatus();
        if (msg.sender != j.developer) revert NotDeveloper();
        Milestone storage m = _milestones[jobId][index];
        if (m.status != MilestoneStatus.Funded) revert InvalidMilestoneStatus();
        m.status = MilestoneStatus.Submitted;
        m.submittedAt = uint64(block.timestamp);
        m.deliveryHash = deliveryHash;
        emit MilestoneSubmitted(jobId, index, deliveryHash);
    }

    function releaseMilestone(uint256 jobId, uint256 index) external whenNotPaused nonReentrant {
        Job storage j = _jobs[jobId];
        if (msg.sender != j.client) revert NotClient();
        Milestone storage m = _milestones[jobId][index];
        if (m.status != MilestoneStatus.Submitted) revert InvalidMilestoneStatus();
        m.status = MilestoneStatus.Released;
        _recordTerminal(jobId);
        _payout(jobId, index, m.amount, j.developer, j.client);
    }

    function claimMilestone(uint256 jobId, uint256 index) external whenNotPaused nonReentrant {
        Job storage j = _jobs[jobId];
        if (msg.sender != j.developer && msg.sender != keeper) revert NotAuthorized();
        Milestone storage m = _milestones[jobId][index];
        if (m.status != MilestoneStatus.Submitted) revert InvalidMilestoneStatus();
        if (block.timestamp <= uint256(m.submittedAt) + reviewTimeout) revert ReviewWindowOpen();
        m.status = MilestoneStatus.Released;
        _recordTerminal(jobId);
        emit MilestoneAutoReleased(jobId, index, msg.sender);
        _payout(jobId, index, m.amount, j.developer, j.client);
    }

    function cancelMilestone(uint256 jobId, uint256 index) external nonReentrant {
        Job storage j = _jobs[jobId];
        if (msg.sender != j.client) revert NotClient();
        Milestone storage m = _milestones[jobId][index];
        if (m.status != MilestoneStatus.Funded) revert InvalidMilestoneStatus();
        bool isOpen = j.status == JobStatus.Open;
        bool timedOut = j.status == JobStatus.Accepted && block.timestamp > uint256(j.acceptedAt) + submitTimeout;
        if (!isOpen && !timedOut) revert CannotCancel();
        m.status = MilestoneStatus.Cancelled;
        _recordTerminal(jobId);
        uint256 amount = m.amount;
        emit MilestoneCancelled(jobId, index, j.client, amount);
        usdt.safeTransfer(j.client, amount);
    }

    /// @notice Either party freezes a funded/submitted milestone for arbitration; snapshots the time.
    function raiseDispute(uint256 jobId, uint256 index) external whenNotPaused {
        Job storage j = _jobs[jobId];
        if (j.status != JobStatus.Accepted) revert InvalidJobStatus();
        if (msg.sender != j.client && msg.sender != j.developer) revert NotParty();
        Milestone storage m = _milestones[jobId][index];
        if (m.status != MilestoneStatus.Funded && m.status != MilestoneStatus.Submitted) {
            revert InvalidMilestoneStatus();
        }
        m.status = MilestoneStatus.Disputed;
        m.disputeRaisedAt = uint64(block.timestamp); // snapshot for arbiter-eligibility
        _reputation[msg.sender].disputesRaised += 1;
        emit DisputeRaised(jobId, index, msg.sender, m.disputeRaisedAt);
    }

    /// @notice A registered, ELIGIBLE arbiter resolves a disputed milestone (tier 2).
    /// @dev Eligibility: the caller must be a current arbiter AND have been registered at/before the
    ///      dispute was opened (`arbiterSince <= disputeRaisedAt`) — an arbiter added after the
    ///      dispute cannot resolve it. Combined with the 48h add-timelock, this blocks inserting a
    ///      puppet arbiter to swing a live dispute.
    function resolveDispute(uint256 jobId, uint256 index, bool payDeveloper) external onlyArbiter nonReentrant {
        Job storage j = _jobs[jobId];
        Milestone storage m = _milestones[jobId][index];
        if (m.status != MilestoneStatus.Disputed) revert InvalidMilestoneStatus();
        if (arbiterSince[msg.sender] > uint256(m.disputeRaisedAt)) revert ArbiterNotEligible();

        if (payDeveloper) {
            m.status = MilestoneStatus.Released;
            _recordTerminal(jobId);
            _reputation[j.client].disputesLost += 1;
            emit DisputeResolved(jobId, index, msg.sender, true);
            _payout(jobId, index, m.amount, j.developer, j.client);
        } else {
            m.status = MilestoneStatus.Cancelled;
            _recordTerminal(jobId);
            _reputation[j.developer].disputesLost += 1;
            uint256 amount = m.amount;
            emit MilestoneCancelled(jobId, index, j.client, amount);
            emit DisputeResolved(jobId, index, msg.sender, false);
            usdt.safeTransfer(j.client, amount);
        }
    }

    // --------------------------------------------------------------------- arbiter registry (timelocked)
    /// @notice Queue an address to become an arbiter; it goes live only after ARBITER_TIMELOCK (48h).
    function queueArbiter(address arbiter) external onlyOwner {
        if (arbiter == address(0)) revert ZeroAddress();
        if (isArbiter[arbiter]) revert AlreadyArbiter();
        arbiterQueuedAt[arbiter] = block.timestamp;
        emit ArbiterQueued(arbiter, block.timestamp + ARBITER_TIMELOCK);
    }

    /// @notice Execute a queued arbiter addition after the timelock has elapsed.
    function executeArbiter(address arbiter) external onlyOwner {
        uint256 q = arbiterQueuedAt[arbiter];
        if (q == 0) revert NotQueued();
        if (block.timestamp < q + ARBITER_TIMELOCK) revert TimelockNotElapsed();
        arbiterQueuedAt[arbiter] = 0;
        isArbiter[arbiter] = true;
        arbiterSince[arbiter] = block.timestamp;
        emit ArbiterAdded(arbiter, block.timestamp);
    }

    /// @notice Cancel a pending (queued, not yet executed) arbiter addition.
    function cancelArbiterChange(address arbiter) external onlyOwner {
        if (arbiterQueuedAt[arbiter] == 0) revert NotQueued();
        arbiterQueuedAt[arbiter] = 0;
        emit ArbiterChangeCancelled(arbiter);
    }

    /// @notice Remove an arbiter immediately (revoke-fast; no timelock on removal).
    function removeArbiter(address arbiter) external onlyOwner {
        if (!isArbiter[arbiter]) revert NotArbiter();
        isArbiter[arbiter] = false;
        arbiterSince[arbiter] = 0;
        emit ArbiterRemoved(arbiter);
    }

    // --------------------------------------------------------------------- buyback
    function executeBuybackBurn(uint256 minDswpOut, uint256 deadline) external whenNotPaused nonReentrant {
        if (msg.sender != owner() && msg.sender != keeper) revert NotAuthorized();
        uint256 reserve = buybackReserve;
        if (reserve == 0) revert NothingToBuyback();
        buybackReserve = 0;

        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(dswp);

        usdt.forceApprove(address(router), reserve);
        uint256[] memory amounts = router.swapExactTokensForTokens(reserve, minDswpOut, path, address(this), deadline);
        uint256 received = amounts[amounts.length - 1];
        dswp.burn(received);
        emit BuybackBurned(reserve, received);
    }

    function autoBuybackAndBurn(uint256 amountIn) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _swapAndBurn(amountIn);
    }

    // --------------------------------------------------------------------- admin
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setKeeper(address newKeeper) external onlyOwner {
        keeper = newKeeper;
        emit KeeperUpdated(newKeeper);
    }

    function setSubmitTimeout(uint256 newTimeout) external onlyOwner {
        if (newTimeout < MIN_TIMEOUT || newTimeout > MAX_TIMEOUT) revert InvalidTimeout();
        submitTimeout = newTimeout;
        emit SubmitTimeoutUpdated(newTimeout);
    }

    function setReviewTimeout(uint256 newTimeout) external onlyOwner {
        if (newTimeout < MIN_TIMEOUT || newTimeout > MAX_TIMEOUT) revert InvalidTimeout();
        reviewTimeout = newTimeout;
        emit ReviewTimeoutUpdated(newTimeout);
    }

    function setAutoBuybackEnabled(bool enabled) external onlyOwner {
        autoBuybackEnabled = enabled;
        emit AutoBuybackToggled(enabled);
    }

    function setBuybackSlippageBps(uint256 bps) external onlyOwner {
        if (bps > MAX_SLIPPAGE_BPS) revert InvalidSlippage();
        buybackSlippageBps = bps;
        emit BuybackSlippageUpdated(bps);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // --------------------------------------------------------------------- views
    function getJob(uint256 jobId) external view returns (Job memory) {
        return _jobs[jobId];
    }

    function getMilestone(uint256 jobId, uint256 index) external view returns (Milestone memory) {
        return _milestones[jobId][index];
    }

    function getMilestones(uint256 jobId) external view returns (Milestone[] memory list) {
        uint256 n = _jobs[jobId].milestoneCount;
        list = new Milestone[](n);
        for (uint256 i; i < n; ++i) {
            list[i] = _milestones[jobId][i];
        }
    }

    function getReputation(address account) external view returns (Reputation memory) {
        return _reputation[account];
    }

    // --------------------------------------------------------------------- internal
    function _recordTerminal(uint256 jobId) private {
        Job storage j = _jobs[jobId];
        j.terminalCount += 1;
        if (j.terminalCount == j.milestoneCount) {
            JobStatus end = j.status == JobStatus.Open ? JobStatus.Cancelled : JobStatus.Completed;
            j.status = end;
            emit JobClosed(jobId, end);
        }
    }

    function _payout(uint256 jobId, uint256 index, uint256 amount, address developer, address client) private {
        uint256 fee = (amount * FEE_BPS) / BPS_DENOMINATOR;
        uint256 buyback = (amount * BUYBACK_BPS) / BPS_DENOMINATOR;
        uint256 developerNet = amount - fee - buyback;

        Reputation storage devRep = _reputation[developer];
        devRep.milestonesPaid += 1;
        devRep.totalEarned += developerNet;
        _reputation[client].totalSpent += amount;

        emit MilestoneReleased(jobId, index, developer, developerNet, fee, buyback);

        usdt.safeTransfer(developer, developerNet);
        usdt.safeTransfer(feeRecipient, fee);

        if (buyback == 0) return;
        if (autoBuybackEnabled) {
            try this.autoBuybackAndBurn(buyback) {}
            catch {
                buybackReserve += buyback;
                emit BuybackDeferred(jobId, index, buyback);
            }
        } else {
            buybackReserve += buyback;
            emit BuybackDeferred(jobId, index, buyback);
        }
    }

    function _swapAndBurn(uint256 amountIn) private {
        address[] memory path = new address[](2);
        path[0] = address(usdt);
        path[1] = address(dswp);
        uint256 expectedOut = router.getAmountsOut(amountIn, path)[1];
        uint256 minOut = (expectedOut * (BPS_DENOMINATOR - buybackSlippageBps)) / BPS_DENOMINATOR;
        usdt.forceApprove(address(router), amountIn);
        uint256[] memory amounts =
            router.swapExactTokensForTokens(amountIn, minOut, path, address(this), block.timestamp);
        uint256 received = amounts[amounts.length - 1];
        dswp.burn(received);
        emit BuybackBurned(amountIn, received);
    }
}
