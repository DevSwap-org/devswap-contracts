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

/// @title DevSwapEscrow
/// @notice USDT escrow for the DevSwap P2P services marketplace on BSC.
/// @dev On successful release the escrowed USDT splits 97% developer / 1.5% fee / 1.5% buyback.
///      The buyback portion is only *accumulated* in `releaseFunds`; the actual swap-and-burn runs
///      in the separate `executeBuybackBurn` so a failing market can never block a developer's pay.
///      Security: Checks-Effects-Interactions on every fund move + ReentrancyGuard + SafeERC20 +
///      Ownable2Step + Pausable. Assumes `usdt` is a non-fee-on-transfer token (canonical BSC USDT).
contract DevSwapEscrow is ReentrancyGuard, Pausable, Ownable2Step {
    using SafeERC20 for IERC20;

    // --------------------------------------------------------------------- types
    enum Status {
        None, // 0 — never created
        Open, // 1 — funded, awaiting a developer
        Accepted, // 2 — developer accepted, working
        Submitted, // 3 — delivery submitted, awaiting client approval
        Released, // 4 — terminal: developer paid
        Cancelled, // 5 — terminal: client refunded
        Disputed // 6 — frozen, awaiting admin resolution
    }

    struct Task {
        address client; // funder / buyer
        uint64 acceptedAt; // timestamp the developer accepted (drives submit-timeout)
        Status status;
        address developer; // accepted service provider
        uint256 amount; // USDT locked
        string metadataHash; // IPFS hash of the task spec
        string deliveryHash; // IPFS/GitHub proof of delivery
    }

    // --------------------------------------------------------------------- constants
    uint256 public constant FEE_BPS = 150; // 1.5% owner fee
    uint256 public constant BUYBACK_BPS = 150; // 1.5% buyback-and-burn
    uint256 public constant BPS_DENOMINATOR = 10_000;
    uint256 public constant MIN_SUBMIT_TIMEOUT = 1 days;
    uint256 public constant MAX_SUBMIT_TIMEOUT = 60 days;
    uint256 public constant MAX_SLIPPAGE_BPS = 1_000; // 10% — ceiling for the inline auto-buyback guard

    // --------------------------------------------------------------------- storage
    IERC20 public immutable usdt; // settlement token (BSC USDT, 18 decimals)
    IERC20Burnable public immutable dswp; // platform token bought back and burned
    IPancakeRouter02 public immutable router; // PancakeSwap V2 router

    address public feeRecipient; // receives the 1.5% owner fee
    address public keeper; // may trigger executeBuybackBurn (alongside owner)
    uint256 public submitTimeout; // window after accept for the developer to submit
    uint256 public buybackReserve; // USDT accumulated for deferred (bulk) buyback-and-burn
    uint256 public nextTaskId; // monotonic task id counter
    bool public autoBuybackEnabled; // if true, releaseFunds burns the 1.5% inline (Option C)
    uint256 public buybackSlippageBps; // slippage floor for the inline auto-buyback (default 3%)

    mapping(uint256 => Task) private _tasks;

    // --------------------------------------------------------------------- events
    event TaskCreated(uint256 indexed taskId, address indexed client, uint256 amount, string metadataHash);
    event TaskAccepted(uint256 indexed taskId, address indexed developer);
    event TaskSubmitted(uint256 indexed taskId, string deliveryHash);
    event FundsReleased(
        uint256 indexed taskId, address indexed developer, uint256 developerNet, uint256 fee, uint256 buyback
    );
    event TaskCancelled(uint256 indexed taskId, address indexed client, uint256 amount);
    event DisputeRaised(uint256 indexed taskId, address indexed by);
    event DisputeResolved(uint256 indexed taskId, bool paidDeveloper);
    event BuybackBurned(uint256 usdtSpent, uint256 dswpBurned);
    event BuybackDeferred(uint256 indexed taskId, uint256 usdtAmount); // inline swap failed/off -> accrued to reserve
    event AutoBuybackToggled(bool enabled);
    event BuybackSlippageUpdated(uint256 bps);
    event FeeRecipientUpdated(address indexed newRecipient);
    event KeeperUpdated(address indexed newKeeper);
    event SubmitTimeoutUpdated(uint256 newTimeout);

    // --------------------------------------------------------------------- errors
    error ZeroAddress();
    error ZeroAmount();
    error InvalidTaskStatus();
    error NotClient();
    error NotDeveloper();
    error NotParty();
    error NotAuthorized();
    error ClientCannotAcceptOwnTask();
    error CannotCancel();
    error NothingToBuyback();
    error InvalidTimeout();
    error InvalidSlippage();
    error OnlySelf();

    // --------------------------------------------------------------------- constructor
    constructor(address _usdt, address _dswp, address _router, address _feeRecipient, address initialOwner)
        Ownable(initialOwner)
    {
        // initialOwner == address(0) is already rejected by Ownable's constructor.
        if (_usdt == address(0) || _dswp == address(0) || _router == address(0) || _feeRecipient == address(0)) {
            revert ZeroAddress();
        }
        usdt = IERC20(_usdt);
        dswp = IERC20Burnable(_dswp);
        router = IPancakeRouter02(_router);
        feeRecipient = _feeRecipient;
        submitTimeout = 14 days;
        autoBuybackEnabled = true;
        buybackSlippageBps = 300; // 3% default slippage floor for inline auto-buyback
    }

    // --------------------------------------------------------------------- lifecycle
    /// @notice Create and fund a task, pulling `amount` USDT from the caller (requires prior approve).
    /// @param amount USDT to escrow (must be > 0).
    /// @param metadataHash IPFS hash describing the task.
    /// @return taskId The new task's id.
    function createTask(uint256 amount, string calldata metadataHash)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 taskId)
    {
        if (amount == 0) revert ZeroAmount();
        taskId = nextTaskId++;
        Task storage t = _tasks[taskId];
        t.client = msg.sender;
        t.amount = amount;
        t.status = Status.Open;
        t.metadataHash = metadataHash;
        emit TaskCreated(taskId, msg.sender, amount, metadataHash);
        usdt.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Accept an open task as its developer. The client may not accept their own task.
    function acceptTask(uint256 taskId) external whenNotPaused {
        Task storage t = _tasks[taskId];
        if (t.status != Status.Open) revert InvalidTaskStatus();
        if (msg.sender == t.client) revert ClientCannotAcceptOwnTask();
        t.developer = msg.sender;
        t.acceptedAt = uint64(block.timestamp);
        t.status = Status.Accepted;
        emit TaskAccepted(taskId, msg.sender);
    }

    /// @notice Submit proof of delivery for an accepted task. Developer only.
    function submitTask(uint256 taskId, string calldata deliveryHash) external whenNotPaused {
        Task storage t = _tasks[taskId];
        if (t.status != Status.Accepted) revert InvalidTaskStatus();
        if (msg.sender != t.developer) revert NotDeveloper();
        t.deliveryHash = deliveryHash;
        t.status = Status.Submitted;
        emit TaskSubmitted(taskId, deliveryHash);
    }

    /// @notice Client approves a submitted task, releasing funds (Option C: inline buyback-burn).
    /// @dev CEI: status set before any transfer. _payout pays dev+fee, then attempts an inline
    ///      try/catch buyback-burn of the 1.5% (deferring to reserve on failure).
    function releaseFunds(uint256 taskId) external whenNotPaused nonReentrant {
        Task storage t = _tasks[taskId];
        if (msg.sender != t.client) revert NotClient();
        if (t.status != Status.Submitted) revert InvalidTaskStatus();
        t.status = Status.Released;
        _payout(taskId, t.amount, t.developer);
    }

    /// @notice Refund the client when a task was never accepted, or accepted but not submitted in time.
    /// @dev Intentionally NOT gated by `whenNotPaused`: clients must always be able to reclaim funds.
    function cancelTask(uint256 taskId) external nonReentrant {
        Task storage t = _tasks[taskId];
        if (msg.sender != t.client) revert NotClient();
        bool isOpen = t.status == Status.Open;
        bool timedOut = t.status == Status.Accepted && block.timestamp > uint256(t.acceptedAt) + submitTimeout;
        if (!isOpen && !timedOut) revert CannotCancel();
        t.status = Status.Cancelled;
        uint256 amount = t.amount;
        emit TaskCancelled(taskId, t.client, amount);
        usdt.safeTransfer(t.client, amount);
    }

    /// @notice Either party freezes an in-progress or submitted task for admin arbitration.
    function raiseDispute(uint256 taskId) external whenNotPaused {
        Task storage t = _tasks[taskId];
        if (msg.sender != t.client && msg.sender != t.developer) revert NotParty();
        if (t.status != Status.Accepted && t.status != Status.Submitted) revert InvalidTaskStatus();
        t.status = Status.Disputed;
        emit DisputeRaised(taskId, msg.sender);
    }

    /// @notice Owner resolves a dispute: pay the developer (with the normal split) or refund the client.
    /// @dev Phase-1 simple arbitration; ownership becomes a multisig+timelock before mainnet.
    function resolveDispute(uint256 taskId, bool payDeveloper) external onlyOwner nonReentrant {
        Task storage t = _tasks[taskId];
        if (t.status != Status.Disputed) revert InvalidTaskStatus();
        if (payDeveloper) {
            t.status = Status.Released;
            _payout(taskId, t.amount, t.developer);
        } else {
            t.status = Status.Cancelled;
            uint256 amount = t.amount;
            emit TaskCancelled(taskId, t.client, amount);
            usdt.safeTransfer(t.client, amount);
        }
        emit DisputeResolved(taskId, payDeveloper);
    }

    // --------------------------------------------------------------------- buyback
    /// @notice Swap the accumulated `buybackReserve` USDT for $DSWP and burn it. Owner or keeper.
    /// @dev Batched + slippage-guarded (amountOutMin, deadline) to reduce MEV. CEI: reserve is zeroed
    ///      before the external swap; if the swap reverts the whole call reverts and reserve is restored.
    /// @param minDswpOut Minimum acceptable $DSWP out (slippage guard).
    /// @param deadline Unix timestamp after which the swap reverts.
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

    // --------------------------------------------------------------------- admin
    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setKeeper(address newKeeper) external onlyOwner {
        keeper = newKeeper; // address(0) disables keeper, leaving owner-only buyback
        emit KeeperUpdated(newKeeper);
    }

    function setSubmitTimeout(uint256 newTimeout) external onlyOwner {
        if (newTimeout < MIN_SUBMIT_TIMEOUT || newTimeout > MAX_SUBMIT_TIMEOUT) revert InvalidTimeout();
        submitTimeout = newTimeout;
        emit SubmitTimeoutUpdated(newTimeout);
    }

    /// @notice Toggle inline auto-buyback. When off, the 1.5% accrues to buybackReserve for bulk burn.
    function setAutoBuybackEnabled(bool enabled) external onlyOwner {
        autoBuybackEnabled = enabled;
        emit AutoBuybackToggled(enabled);
    }

    /// @notice Set the slippage floor (bps) for the inline auto-buyback. Capped at MAX_SLIPPAGE_BPS.
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
    function getTask(uint256 taskId) external view returns (Task memory) {
        return _tasks[taskId];
    }

    // --------------------------------------------------------------------- internal
    /// @dev Shared payout: 97% developer + 1.5% fee paid out FIRST (payment safety), then the 1.5%
    ///      buyback is burned inline if `autoBuybackEnabled` — wrapped in a self-call try/catch so a
    ///      failed/illiquid swap can never block the developer's pay; on failure (or if disabled) the
    ///      1.5% accrues to `buybackReserve` for a later bulk `executeBuybackBurn`.
    ///      developerNet is the remainder so the three parts always sum to `amount`.
    function _payout(uint256 taskId, uint256 amount, address developer) private {
        uint256 fee = (amount * FEE_BPS) / BPS_DENOMINATOR;
        uint256 buyback = (amount * BUYBACK_BPS) / BPS_DENOMINATOR;
        uint256 developerNet = amount - fee - buyback;
        emit FundsReleased(taskId, developer, developerNet, fee, buyback);

        // Interactions: pay the humans first; their funds never depend on the market.
        usdt.safeTransfer(developer, developerNet);
        usdt.safeTransfer(feeRecipient, fee);

        if (buyback == 0) return;
        if (autoBuybackEnabled) {
            // self-call wraps the whole quote→swap→burn sequence in one try/catch
            try this.autoBuybackAndBurn(buyback) {
            // success: $DSWP bought and burned inline (event emitted in _swapAndBurn)
            }
            catch {
                buybackReserve += buyback; // any failure -> defer to bulk burn; dev already paid
                emit BuybackDeferred(taskId, buyback);
            }
        } else {
            buybackReserve += buyback;
            emit BuybackDeferred(taskId, buyback);
        }
    }

    /// @notice Inline-buyback hook for the try/catch in `_payout`. Callable only by the contract
    ///         itself. Not `nonReentrant` by design: it runs inside the caller's guarded scope, and
    ///         any genuine reentry into a guarded function reverts and is absorbed by that try/catch.
    function autoBuybackAndBurn(uint256 amountIn) external {
        if (msg.sender != address(this)) revert OnlySelf();
        _swapAndBurn(amountIn);
    }

    /// @dev Buys $DSWP with `amountIn` USDT on PancakeSwap and burns it. minOut is derived on-chain
    ///      from getAmountsOut and `buybackSlippageBps`; reverts bubble to the caller's try/catch.
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
