// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemBase} from "./SystemBase.sol";
import {OGHook} from "../src/OGHook.sol";
import {OG} from "../src/OG.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

contract RejectETH {
    receive() external payable {
        revert();
    }
}

contract HookTest is SystemBase {
    function setUp() public {
        _system(true, true);
        vm.warp(hook.openedAt() + 1 hours);
    }

    function _checkFee(bool buy, int256 amount, uint160 limit) internal {
        uint256 teamBefore = hook.TEAM().balance;
        uint256 rewardsBefore = address(dist).balance;
        BalanceDelta d = _trade(buy, amount, limit);
        uint256 team = hook.TEAM().balance - teamBefore;
        uint256 rewards = address(dist).balance - rewardsBefore;
        uint256 gross = buy ? uint256(-int256(d.amount0())) : uint256(int256(d.amount0())) + team + rewards;
        assertEq(team, gross / 100);
        assertEq(rewards, gross * 350 / 10000 - team);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
        assertGt(team, 0);
        assertGt(rewards, 0);
        if (buy && amount < 0) assertLe(gross, uint256(-amount));
        if (!buy && amount > 0) assertLe(uint256(int256(d.amount0())), uint256(amount));
    }

    function test_feeAllFourModes() public {
        _checkFee(true, -0.1 ether, 4295128740);
        _checkFee(true, 10_000 ether, 4295128740);
        _checkFee(false, -10_000 ether, 1461446703485210103287273052203988822378723970341);
        _checkFee(false, 0.05 ether, 1461446703485210103287273052203988822378723970341);
    }

    function test_partialBuyExactInput() public {
        _checkFee(true, -5 ether, START_PRICE * 99 / 100);
    }

    function test_partialBuyExactOutput() public {
        _checkFee(true, 5_000_000 ether, START_PRICE * 99 / 100);
    }

    function test_partialSellExactInput() public {
        _checkFee(false, -5_000_000 ether, START_PRICE * 101 / 100);
    }

    function test_partialSellExactOutput() public {
        _checkFee(false, 5 ether, START_PRICE * 101 / 100);
    }

    function test_exactModesRespectAmount() public {
        assertEq(_trade(true, -0.1 ether).amount0(), -0.1 ether);
        assertEq(_trade(true, 20_000 ether).amount1(), 20_000 ether);
        assertEq(_trade(false, -20_000 ether).amount1(), -20_000 ether);
        assertEq(_trade(false, 0.1 ether).amount0(), 0.1 ether);
    }

    function test_decayAndSurplus() public {
        uint256 opened = hook.openedAt();
        vm.warp(opened);
        assertEq(hook.launchFeeNow(), 0.5e18);
        assertEq(hook.decayMinutesLeft(), 60);
        _mint(ALICE, 1);
        _activate(ALICE, 1, 1);
        uint256 beforeTeam = hook.TEAM().balance;
        _trade(true, -1 ether);
        assertEq(hook.TEAM().balance - beforeTeam, 0.01 ether);
        assertEq(dist.pending(1), 0.025 ether);
        assertEq(dist.backlogLeft(), 0.465 ether);
        vm.warp(opened + 30 minutes);
        assertEq(hook.launchFeeNow(), 0.2675e18);
        assertEq(hook.decayMinutesLeft(), 30);
        vm.warp(opened + 1 hours);
        assertEq(hook.launchFeeNow(), 0.035e18);
        assertEq(hook.decayMinutesLeft(), 0);
        vm.warp(opened + 100 days);
        assertEq(hook.launchFeeNow(), 0.035e18);
    }

    function test_sellsHaveNoLaunchSurplus() public {
        _trade(true, -0.1 ether);
        vm.warp(hook.openedAt());
        _checkFee(false, -10_000 ether, 1461446703485210103287273052203988822378723970341);
    }

    function test_permissionsAndUnauthorizedCallbacks() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        vm.expectRevert(OGHook.Unauthorized.selector);
        hook.beforeInitialize(address(this), key, START_PRICE);
        vm.expectRevert(OGHook.Unauthorized.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1 ether, START_PRICE / 2), "");
        vm.expectRevert(OGHook.Unauthorized.selector);
        hook.afterSwap(address(this), key, SwapParams(true, -1 ether, START_PRICE / 2), BalanceDelta.wrap(0), "");
        vm.expectRevert(OGHook.Unauthorized.selector);
        hook.unlockCallback("");
        vm.expectRevert(OGHook.Unauthorized.selector);
        hook.quoteNative(key, SwapParams(true, -1 ether, START_PRICE / 2));
    }

    function test_wrongPoolRejected() public {
        PoolKey memory other = key;
        other.fee = 3000;
        vm.expectRevert();
        manager.initialize(other, START_PRICE);
        other = key;
        other.tickSpacing = 10;
        vm.expectRevert();
        manager.initialize(other, START_PRICE);
    }

    function test_rejectingTeamDoesNotBlockSwap() public {
        RejectETH bad = new RejectETH();
        vm.etch(hook.TEAM(), address(bad).code);
        _trade(true, -1 ether);
        assertEq(hook.teamCredit(), 0.01 ether);
        assertEq(address(hook).balance, 0.01 ether);
        vm.etch(hook.TEAM(), hex"");
        uint256 before = hook.TEAM().balance;
        hook.payTeam();
        assertEq(hook.teamCredit(), 0);
        assertEq(hook.TEAM().balance - before, 0.01 ether);
    }

    function testFuzz_feeBuyAndSell(uint96 raw, bool buy, bool exactInput) public {
        uint256 amount = bound(uint256(raw), 1e12, 1e17);
        int256 specified = int256(buy == exactInput ? amount : amount * 1_000_000);
        if (exactInput) specified = -specified;
        _checkFee(buy, specified, buy ? 4295128740 : 1461446703485210103287273052203988822378723970341);
    }
}

contract FreshManagerTest is SystemBase {
    function test_claimRewardsPrecedeLaterActivationAndExitRedeems() public {
        _system(false, true);
        router.liquidity(key, ModifyLiquidityParams(120000, 138120, 1e22, bytes32(0)));
        _mint(ALICE, 1);
        _mint(BOB, 2);
        _activate(ALICE, 1, 1);
        vm.warp(hook.openedAt() + 1 hours);
        _trade(true, -0.1 ether);
        assertEq(dist.unfundedFees(), 0.0025 ether);
        assertEq(dist.pending(1), 0.0025 ether);
        _activate(BOB, 2, 3);
        assertEq(dist.pending(2), 0);
        vm.warp(dist.lastActivation(1) + 24 hours);
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        dist.exit(1);
        assertEq(ALICE.balance - before, 0.0025 ether);
        assertEq(dist.unfundedFees(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(dist.pending(2), 0);
    }

    function test_firstBuyWithTokensOnlyMintsAndRedeemsClaims() public {
        _system(false, true);
        // At the upper edge all position assets are token1 (OG).
        router.liquidity(key, ModifyLiquidityParams(120000, 138120, 1e22, bytes32(0)));
        assertEq(address(manager).balance, 0);
        vm.warp(hook.openedAt() + 1 hours);
        BalanceDelta d = _trade(true, -0.1 ether);
        assertEq(d.amount0(), -0.1 ether);
        assertGt(d.amount1(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0.0035 ether);
        assertEq(hook.claimRewards(), 0.0025 ether);
        assertEq(hook.claimTeam(), 0.001 ether);
        hook.redeemFees();
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(hook.claimRewards(), 0);
        assertEq(dist.backlogLeft(), 0.0025 ether);
        assertEq(address(hook).balance, 0);
        hook.redeemFees();
    }
}
