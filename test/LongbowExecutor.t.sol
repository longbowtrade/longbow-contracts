// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {LongbowExecutor} from "../src/LongbowExecutor.sol";
import {MockERC20} from "../src/mocks/MockERC20.sol";
import {MockAggregatorV3} from "../src/mocks/MockAggregatorV3.sol";
import {MockV2Router} from "../src/mocks/MockV2Router.sol";

contract LongbowExecutorTest is Test {
    LongbowExecutor executor;
    MockV2Router router;
    MockERC20 usdg; // 6 decimals, like the real USDG
    MockERC20 tsla; // 18 decimals stock token
    MockAggregatorV3 feed; // TSLA/USD, 8 decimals
    MockAggregatorV3 seqFeed; // sequencer uptime, 0 = up

    address user = makeAddr("user");
    address keeper = makeAddr("keeper");

    // mirror executor constants — reading them via external calls inside a
    // vm.prank'd expression would consume the prank
    uint8 constant ORDER_LIMIT = 0;
    uint8 constant ORDER_DCA = 1;
    uint8 constant DIR_BELOW = 0;
    uint8 constant DIR_ABOVE = 1;

    uint256 constant POOL_TSLA = 1_000e18;
    uint256 constant POOL_USDG = 268_000e6; // ≈268 USDG per TSLA

    function setUp() public {
        usdg = new MockERC20("Global Dollar", "USDG", 6);
        tsla = new MockERC20("Tesla Stock Token", "mTSLA", 18);
        router = new MockV2Router();
        feed = new MockAggregatorV3(8, 268e8);
        seqFeed = new MockAggregatorV3(8, 0); // up

        // let the sequencer grace period pass, then refresh the price feed
        vm.warp(block.timestamp + 2 hours);
        feed.setAnswer(268e8);

        executor = new LongbowExecutor(address(router), address(seqFeed), 1 hours);

        // seed the mock pool
        usdg.mint(address(this), POOL_USDG);
        tsla.mint(address(this), POOL_TSLA);
        usdg.approve(address(router), type(uint256).max);
        tsla.approve(address(router), type(uint256).max);
        router.seedLiquidity(address(tsla), address(usdg), POOL_TSLA, POOL_USDG);

        // fund user with USDG + blanket approval to the executor
        usdg.mint(user, 100_000e6);
        tsla.mint(user, 100e18);
        vm.startPrank(user);
        usdg.approve(address(executor), type(uint256).max);
        tsla.approve(address(executor), type(uint256).max);
        vm.stopPrank();
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _placeLimitBuy(uint256 amountUsdg, int256 trigger, uint256 minOut)
        internal
        returns (uint256 id)
    {
        vm.prank(user);
        id = executor.placeOrder(
            address(usdg),
            address(tsla),
            address(feed),
            amountUsdg,
            minOut,
            trigger,
            DIR_BELOW,
            ORDER_LIMIT,
            0,
            1,
            0
        );
    }

    // ─── LIMIT orders ────────────────────────────────────────────────────

    function test_limitBuy_executesWhenPriceCrossesBelow() public {
        uint256 id = _placeLimitBuy(1_000e6, 260e8, 0);

        // above trigger → not executable
        (bool ok, string memory reason) = executor.canExecute(id);
        assertFalse(ok);
        assertEq(reason, "price above trigger");
        vm.prank(keeper);
        vm.expectRevert();
        executor.executeOrder(id, _path(address(usdg), address(tsla)));

        // price dips through the trigger → executable by anyone
        feed.setAnswer(259e8);
        uint256 before = tsla.balanceOf(user);
        vm.prank(keeper);
        uint256 out = executor.executeOrder(id, _path(address(usdg), address(tsla)));

        assertGt(out, 0);
        assertEq(tsla.balanceOf(user), before + out);
        (,,,,,,,,,,,,, bool active) = executor.orders(id);
        assertFalse(active); // limit is one-shot
    }

    function test_limitSell_triggerAbove() public {
        vm.prank(user);
        uint256 id = executor.placeOrder(
            address(tsla),
            address(usdg),
            address(feed),
            1e18,
            0,
            280e8,
            DIR_ABOVE,
            ORDER_LIMIT,
            0,
            1,
            0
        );

        (bool ok,) = executor.canExecute(id);
        assertFalse(ok);

        feed.setAnswer(281e8);
        uint256 before = usdg.balanceOf(user);
        vm.prank(keeper);
        uint256 out = executor.executeOrder(id, _path(address(tsla), address(usdg)));
        assertEq(usdg.balanceOf(user), before + out);
    }

    function test_minAmountOut_slippageGuard() public {
        // expected fill for 1000 USDG
        uint256[] memory quote =
            router.getAmountsOut(1_000e6, _path(address(usdg), address(tsla)));
        uint256 expected = quote[1];

        // demand more than the pool can give → swap must revert, order stays live
        uint256 id = _placeLimitBuy(1_000e6, 270e8, expected + 1);
        vm.prank(keeper);
        vm.expectRevert();
        executor.executeOrder(id, _path(address(usdg), address(tsla)));

        // exact quote passes
        uint256 id2 = _placeLimitBuy(1_000e6, 270e8, expected);
        vm.prank(keeper);
        uint256 out = executor.executeOrder(id2, _path(address(usdg), address(tsla)));
        assertGe(out, expected);
    }

    // ─── DCA orders ──────────────────────────────────────────────────────

    function test_dca_multiRun_thenDeactivates() public {
        vm.prank(user);
        uint256 id = executor.placeOrder(
            address(usdg),
            address(tsla),
            address(0), // pure time-based DCA
            500e6,
            0,
            0,
            0,
            ORDER_DCA,
            1 days,
            3,
            0
        );

        address[] memory path = _path(address(usdg), address(tsla));

        // run 1 — eligible immediately
        vm.prank(keeper);
        executor.executeOrder(id, path);

        // run 2 too early
        vm.prank(keeper);
        vm.expectRevert();
        executor.executeOrder(id, path);

        vm.warp(block.timestamp + 1 days);
        feed.setAnswer(268e8); // keep oracle fresh for realism
        vm.prank(keeper);
        executor.executeOrder(id, path);

        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper);
        executor.executeOrder(id, path);

        (,,,,,,,,,, uint32 remaining,,, bool active) = executor.orders(id);
        assertEq(remaining, 0);
        assertFalse(active);

        // run 4 impossible
        vm.warp(block.timestamp + 1 days);
        vm.prank(keeper);
        vm.expectRevert();
        executor.executeOrder(id, path);

        assertGt(tsla.balanceOf(user), 100e18); // received stock 3 times
    }

    // ─── Guards ──────────────────────────────────────────────────────────

    function test_expiredOrder_notExecutable() public {
        vm.prank(user);
        uint256 id = executor.placeOrder(
            address(usdg),
            address(tsla),
            address(feed),
            1_000e6,
            0,
            270e8,
            DIR_BELOW,
            ORDER_LIMIT,
            0,
            1,
            uint64(block.timestamp + 1 days)
        );

        vm.warp(block.timestamp + 2 days);
        feed.setAnswer(250e8); // condition would otherwise hold
        (bool ok, string memory reason) = executor.canExecute(id);
        assertFalse(ok);
        assertEq(reason, "expired");
        vm.prank(keeper);
        vm.expectRevert();
        executor.executeOrder(id, _path(address(usdg), address(tsla)));
    }

    function test_oraclePaused_blocksExecution() public {
        uint256 id = _placeLimitBuy(1_000e6, 270e8, 0);
        tsla.setOraclePaused(true); // corporate action in progress

        (bool ok, string memory reason) = executor.canExecute(id);
        assertFalse(ok);
        assertEq(reason, "oracle paused");
        vm.prank(keeper);
        vm.expectRevert();
        executor.executeOrder(id, _path(address(usdg), address(tsla)));

        // resumes normally once unpaused
        tsla.setOraclePaused(false);
        vm.prank(keeper);
        executor.executeOrder(id, _path(address(usdg), address(tsla)));
    }

    function test_stalePrice_blocksExecution() public {
        uint256 id = _placeLimitBuy(1_000e6, 270e8, 0);
        vm.warp(block.timestamp + 3 hours); // feed last updated >1h ago

        (bool ok, string memory reason) = executor.canExecute(id);
        assertFalse(ok);
        assertEq(reason, "stale price");
    }

    function test_sequencerDown_blocksExecution() public {
        uint256 id = _placeLimitBuy(1_000e6, 270e8, 0);
        seqFeed.setAnswer(1); // down

        (bool ok, string memory reason) = executor.canExecute(id);
        assertFalse(ok);
        assertEq(reason, "sequencer down");
    }

    // ─── Cancel & validation ─────────────────────────────────────────────

    function test_cancel_onlyOwner() public {
        uint256 id = _placeLimitBuy(1_000e6, 270e8, 0);

        vm.prank(keeper);
        vm.expectRevert(LongbowExecutor.NotOwner.selector);
        executor.cancelOrder(id);

        vm.prank(user);
        executor.cancelOrder(id);

        feed.setAnswer(250e8);
        vm.prank(keeper);
        vm.expectRevert();
        executor.executeOrder(id, _path(address(usdg), address(tsla)));
    }

    function test_placeOrder_validation() public {
        vm.startPrank(user);

        vm.expectRevert();
        executor.placeOrder(
            address(usdg), address(usdg), address(feed), 1e6, 0, 1e8, 0, 0, 0, 1, 0
        );

        vm.expectRevert();
        executor.placeOrder(
            address(usdg), address(tsla), address(feed), 0, 0, 1e8, 0, 0, 0, 1, 0
        );

        // limit without feed
        vm.expectRevert();
        executor.placeOrder(address(usdg), address(tsla), address(0), 1e6, 0, 1e8, 0, 0, 0, 1, 0);

        // dca without interval
        vm.expectRevert();
        executor.placeOrder(address(usdg), address(tsla), address(0), 1e6, 0, 0, 0, 1, 0, 3, 0);

        vm.stopPrank();
    }

    function test_badPath_rejected() public {
        uint256 id = _placeLimitBuy(1_000e6, 270e8, 0);
        feed.setAnswer(250e8);

        address[] memory wrong = _path(address(tsla), address(usdg)); // reversed
        vm.prank(keeper);
        vm.expectRevert();
        executor.executeOrder(id, wrong);
    }
}
