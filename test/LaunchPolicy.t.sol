// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SystemBase} from "./SystemBase.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Rehearsals at policy 34's actual opening price, alongside the legacy unit fixtures.
contract LaunchPolicyTest is SystemBase {
    using StateLibrary for IPoolManager;

    function test_policyPriceSupportsFourModesAndETHActivation() public {
        _systemAtPrice(true, true, LAUNCH_PRICE, 1e21);
        (uint160 price,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(price, LAUNCH_PRICE);
        _mint(ALICE, 1);
        _mint(BOB, 2);
        _activate(BOB, 2, 1);

        // Everyone can buy immediately. Exactly half of this gross input is the launch fee.
        uint256 teamBefore = hook.TEAM().balance;
        BalanceDelta first = _trade(true, -0.01 ether);
        assertEq(first.amount0(), -0.01 ether);
        assertGt(first.amount1(), 0);
        assertEq(hook.TEAM().balance - teamBefore, 0.0001 ether);
        assertEq(dist.pending(2), 0.00025 ether);
        assertEq(dist.backlogLeft(), 0.00465 ether);

        vm.warp(hook.openedAt() + 1 hours);
        _normalFee(true, -0.001 ether);
        _normalFee(true, 10_000 ether);
        _normalFee(false, -10_000 ether);
        _normalFee(false, 0.001 ether);

        uint256 aliceBefore = ALICE.balance;
        uint256 burnedBefore = token.totalBurned();
        teamBefore = hook.TEAM().balance;
        uint256 pendingBefore = dist.pending(2);
        vm.prank(ALICE);
        dist.activateWithETH{value: 0.01 ether}(1, 1, LAUNCH_PRICE / 2, block.timestamp);
        uint256 spent = aliceBefore - ALICE.balance;
        assertGt(spent, 0);
        assertLt(spent, 0.01 ether);
        assertEq(token.totalBurned() - burnedBefore, 50_000 ether);
        assertEq(hook.TEAM().balance - teamBefore, spent / 100);
        assertEq(dist.pending(2) - pendingBefore, spent * 350 / 10_000 - spent / 100);
        assertEq(dist.pending(1), 0);
        assertEq(dist.totalWeight(), 2);
    }

    function test_policyPriceTokensOnlyLaunchClaimsAndExit() public {
        _systemAtPrice(false, true, LAUNCH_PRICE, 0);
        // Entirely OG at opening; these are test ranges, not a policy liquidity allocation.
        router.liquidity(key, ModifyLiquidityParams(166200, 184200, 1e21, bytes32(0)));
        assertEq(address(manager).balance, 0);
        _mint(ALICE, 1);
        _activate(ALICE, 1, 1);
        BalanceDelta first = _trade(true, -0.01 ether);
        assertEq(first.amount0(), -0.01 ether);
        assertGt(first.amount1(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0.005 ether);
        assertEq(hook.claimTeam(), 0.0001 ether);
        assertEq(hook.claimRewards(), 0.00025 ether);
        assertEq(hook.claimSurplus(), 0.00465 ether);
        assertEq(dist.pending(1), 0.00025 ether);
        assertEq(dist.backlogLeft(), 0.00465 ether);
        vm.warp(block.timestamp + 24 hours);
        uint256 payout = dist.pending(1);
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        dist.exit(1);
        assertEq(ALICE.balance - before, payout);
        assertEq(dist.unfundedFees(), 0);
        assertEq(manager.balanceOf(address(hook), 0), 0);
        assertEq(dist.totalWeight(), 0);
        assertEq(nft.ownerOf(1), address(auction));
        assertEq(address(dist).balance, dist.backlogLeft());
    }

    function _normalFee(bool buy, int256 amount) private {
        uint256 teamBefore = hook.TEAM().balance;
        uint256 rewardsBefore = address(dist).balance;
        BalanceDelta delta = _trade(buy, amount);
        uint256 team = hook.TEAM().balance - teamBefore;
        uint256 rewards = address(dist).balance - rewardsBefore;
        uint256 gross = buy ? uint256(-int256(delta.amount0())) : uint256(int256(delta.amount0())) + team + rewards;
        assertEq(team, gross / 100);
        assertEq(rewards, gross * 350 / 10_000 - team);
        if (buy && amount < 0) assertEq(delta.amount0(), amount);
        if (buy && amount > 0) assertEq(delta.amount1(), amount);
        if (!buy && amount < 0) assertEq(delta.amount1(), amount);
        if (!buy && amount > 0) assertEq(delta.amount0(), amount);
        assertEq(address(hook).balance, 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }
}
