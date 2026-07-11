// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./interfaces/IERC20.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";

/// @title LongbowExecutor
/// @notice Non-custodial limit-order + DCA executor for tokenized stocks on
///         Robinhood Chain, settling through the Uniswap V2 Router02.
///
///         Users approve this contract for `tokenIn` and place an order.
///         Funds stay in the user's wallet until the moment of execution —
///         the contract only pulls `amountIn` inside `executeOrder`, swaps,
///         and sends the proceeds straight back to the owner.
///
///         `executeOrder` is permissionless: anyone (normally the Longbow
///         keeper) may call it, but it only succeeds when the on-chain
///         trigger conditions verifiably hold. Safety rails: Chainlink
///         staleness check, ERC-8056 `oraclePaused()` check on both legs,
///         L2 sequencer uptime check, and `minAmountOut` slippage guard.
contract LongbowExecutor {
    // ─── Types ────────────────────────────────────────────────────────────

    uint8 public constant ORDER_LIMIT = 0;
    uint8 public constant ORDER_DCA = 1;
    uint8 public constant DIR_BELOW = 0; // trigger when price <= triggerPrice
    uint8 public constant DIR_ABOVE = 1; // trigger when price >= triggerPrice

    struct Order {
        address owner;
        address tokenIn;
        address tokenOut;
        address priceFeed; // Chainlink feed used for LIMIT triggers (8 dec)
        uint256 amountIn; // amount pulled per execution
        uint256 minAmountOut; // slippage guard per execution
        int256 triggerPrice; // 0 = no price condition
        uint64 interval; // DCA: seconds between runs
        uint64 nextExecAt; // DCA: earliest next execution timestamp
        uint64 expiry; // 0 = never expires
        uint32 remainingRuns; // LIMIT: always 1
        uint8 orderType; // ORDER_LIMIT | ORDER_DCA
        uint8 triggerDir; // DIR_BELOW | DIR_ABOVE
        bool active;
    }

    // ─── State ────────────────────────────────────────────────────────────

    IUniswapV2Router02 public immutable router;
    /// @dev Arbitrum-style sequencer uptime feed; address(0) disables the check.
    AggregatorV3Interface public immutable sequencerUptimeFeed;
    /// @dev Reject Chainlink answers older than this (stock feeds run 24/5).
    uint256 public immutable maxPriceAge;
    uint256 public constant SEQUENCER_GRACE_PERIOD = 1 hours;

    uint256 public nextOrderId;
    mapping(uint256 => Order) public orders;

    uint256 private _lock = 1;

    // ─── Events / errors ──────────────────────────────────────────────────

    event OrderPlaced(
        uint256 indexed id,
        address indexed owner,
        address tokenIn,
        address tokenOut,
        uint8 orderType,
        uint256 amountIn
    );
    event OrderExecuted(
        uint256 indexed id,
        address indexed keeper,
        uint256 amountIn,
        uint256 amountOut,
        uint32 remainingRuns
    );
    event OrderCancelled(uint256 indexed id);

    error InvalidOrder(string reason);
    error NotOwner();
    error NotExecutable(string reason);
    error Reentrancy();

    modifier nonReentrant() {
        if (_lock != 1) revert Reentrancy();
        _lock = 2;
        _;
        _lock = 1;
    }

    constructor(address _router, address _sequencerUptimeFeed, uint256 _maxPriceAge) {
        require(_router != address(0), "router=0");
        router = IUniswapV2Router02(_router);
        sequencerUptimeFeed = AggregatorV3Interface(_sequencerUptimeFeed);
        maxPriceAge = _maxPriceAge == 0 ? 1 hours : _maxPriceAge;
    }

    // ─── User actions ─────────────────────────────────────────────────────

    /// @notice Place a LIMIT or DCA order. Caller must approve this contract
    ///         for tokenIn (amountIn × runs for DCA).
    function placeOrder(
        address tokenIn,
        address tokenOut,
        address priceFeed,
        uint256 amountIn,
        uint256 minAmountOut,
        int256 triggerPrice,
        uint8 triggerDir,
        uint8 orderType,
        uint64 interval,
        uint32 runs,
        uint64 expiry
    ) external returns (uint256 id) {
        if (tokenIn == address(0) || tokenOut == address(0) || tokenIn == tokenOut) {
            revert InvalidOrder("bad token pair");
        }
        if (amountIn == 0) revert InvalidOrder("amountIn=0");
        if (orderType > ORDER_DCA) revert InvalidOrder("bad orderType");
        if (triggerDir > DIR_ABOVE) revert InvalidOrder("bad triggerDir");
        if (expiry != 0 && expiry <= block.timestamp) revert InvalidOrder("expiry in past");

        uint64 nextExecAt = 0;
        if (orderType == ORDER_LIMIT) {
            if (priceFeed == address(0)) revert InvalidOrder("limit needs feed");
            if (triggerPrice <= 0) revert InvalidOrder("limit needs trigger");
            runs = 1;
        } else {
            if (interval == 0) revert InvalidOrder("dca needs interval");
            if (runs == 0) revert InvalidOrder("dca needs runs");
            nextExecAt = uint64(block.timestamp); // first run eligible now
        }

        id = nextOrderId++;
        orders[id] = Order({
            owner: msg.sender,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            priceFeed: priceFeed,
            amountIn: amountIn,
            minAmountOut: minAmountOut,
            triggerPrice: triggerPrice,
            interval: interval,
            nextExecAt: nextExecAt,
            expiry: expiry,
            remainingRuns: runs,
            orderType: orderType,
            triggerDir: triggerDir,
            active: true
        });

        emit OrderPlaced(id, msg.sender, tokenIn, tokenOut, orderType, amountIn);
    }

    function cancelOrder(uint256 id) external {
        Order storage o = orders[id];
        if (o.owner != msg.sender) revert NotOwner();
        if (!o.active) revert InvalidOrder("not active");
        o.active = false;
        emit OrderCancelled(id);
    }

    // ─── Execution ────────────────────────────────────────────────────────

    /// @notice View helper for keepers: whether `executeOrder` would pass its
    ///         condition checks right now (swap itself can still revert on
    ///         slippage/allowance).
    function canExecute(uint256 id) external view returns (bool ok, string memory reason) {
        Order storage o = orders[id];
        return _checkConditions(o);
    }

    /// @notice Execute an order. Permissionless — conditions are enforced
    ///         on-chain. `path` must route tokenIn → tokenOut (direct or via
    ///         WETH); proceeds go straight to the order owner.
    function executeOrder(uint256 id, address[] calldata path)
        external
        nonReentrant
        returns (uint256 amountOut)
    {
        Order storage o = orders[id];

        (bool ok, string memory reason) = _checkConditions(o);
        if (!ok) revert NotExecutable(reason);
        if (path.length < 2 || path[0] != o.tokenIn || path[path.length - 1] != o.tokenOut) {
            revert NotExecutable("bad path");
        }

        // effects before interactions
        if (o.orderType == ORDER_DCA) {
            o.remainingRuns -= 1;
            o.nextExecAt += o.interval;
            if (o.remainingRuns == 0) o.active = false;
        } else {
            o.remainingRuns = 0;
            o.active = false;
        }

        // pull exactly one execution's worth, swap, deliver to owner
        require(IERC20(o.tokenIn).transferFrom(o.owner, address(this), o.amountIn), "pull failed");
        require(IERC20(o.tokenIn).approve(address(router), o.amountIn), "approve failed");

        uint256[] memory amounts = router.swapExactTokensForTokens(
            o.amountIn,
            o.minAmountOut, // router reverts if output below this
            path,
            o.owner,
            block.timestamp + 300
        );
        amountOut = amounts[amounts.length - 1];

        emit OrderExecuted(id, msg.sender, o.amountIn, amountOut, o.remainingRuns);
    }

    // ─── Internal checks ──────────────────────────────────────────────────

    function _checkConditions(Order storage o)
        internal
        view
        returns (bool, string memory)
    {
        if (!o.active) return (false, "inactive");
        if (o.expiry != 0 && block.timestamp > o.expiry) return (false, "expired");

        if (!_sequencerUp()) return (false, "sequencer down");

        if (o.orderType == ORDER_DCA) {
            if (block.timestamp < o.nextExecAt) return (false, "too early");
        }

        if (o.triggerPrice > 0 && o.priceFeed != address(0)) {
            (bool fresh, int256 price) = _freshPrice(o.priceFeed);
            if (!fresh) return (false, "stale price");
            if (o.triggerDir == DIR_BELOW && price > o.triggerPrice) {
                return (false, "price above trigger");
            }
            if (o.triggerDir == DIR_ABOVE && price < o.triggerPrice) {
                return (false, "price below trigger");
            }
        }

        if (_oraclePaused(o.tokenIn) || _oraclePaused(o.tokenOut)) {
            return (false, "oracle paused");
        }

        return (true, "");
    }

    function _freshPrice(address feed) internal view returns (bool fresh, int256 price) {
        (, int256 answer,, uint256 updatedAt,) = AggregatorV3Interface(feed).latestRoundData();
        if (answer <= 0) return (false, 0);
        if (block.timestamp - updatedAt > maxPriceAge) return (false, 0);
        return (true, answer);
    }

    /// @dev Chainlink L2 sequencer uptime convention: answer 0 = up, 1 = down.
    ///      A fresh restart must also outlive the grace period.
    function _sequencerUp() internal view returns (bool) {
        if (address(sequencerUptimeFeed) == address(0)) return true;
        (, int256 answer, uint256 startedAt,,) = sequencerUptimeFeed.latestRoundData();
        if (answer != 0) return false;
        if (block.timestamp - startedAt < SEQUENCER_GRACE_PERIOD) return false;
        return true;
    }

    /// @dev ERC-8056 tokens expose oraclePaused(); plain ERC-20s (USDG, WETH)
    ///      don't — treat a failed staticcall as "not paused".
    function _oraclePaused(address token) internal view returns (bool) {
        (bool success, bytes memory data) =
            token.staticcall(abi.encodeWithSignature("oraclePaused()"));
        if (!success || data.length < 32) return false;
        return abi.decode(data, (bool));
    }
}
