// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemBase} from "./SystemBase.sol";
import {OGDistributor} from "../src/OGDistributor.sol";

contract ActivationETHTest is SystemBase {
    function setUp() public {
        _system(true, true);
        _mint(ALICE, 1);
        _mint(BOB, 2);
        vm.warp(hook.openedAt() + 1 hours);
    }

    function test_exactOGBoughtBurnedWithFeeAndRefund() public {
        _activate(BOB, 2, 1);
        uint256 before = ALICE.balance;
        uint256 burned = token.totalBurned();
        uint256 teamBefore = hook.TEAM().balance;
        vm.prank(ALICE);
        dist.activateWithETH{value: 1 ether}(1, 1, START_PRICE / 2, block.timestamp);
        uint256 spent = before - ALICE.balance;
        assertGt(spent, 0);
        assertLt(spent, 1 ether);
        assertEq(token.totalBurned() - burned, 50_000 ether);
        assertEq(hook.TEAM().balance - teamBefore, spent / 100);
        assertEq(dist.pending(1), 0);
        assertEq(dist.pending(2), spent * 350 / 10000 - spent / 100);
        assertEq(dist.level(1), 1);
        assertEq(token.balanceOf(address(dist)), 0);
        assertEq(address(dist).balance, dist.pending(2));
    }

    function test_slippageExpiryPartialFillAndInsufficientETHRevert() public {
        vm.startPrank(ALICE);
        vm.expectRevert(OGDistributor.SlippageOrExpired.selector);
        dist.activateWithETH{value: 1}(1, 1, START_PRICE / 2, block.timestamp);
        vm.expectRevert(OGDistributor.SlippageOrExpired.selector);
        dist.activateWithETH{value: 1 ether}(1, 1, START_PRICE / 2, block.timestamp - 1);
        vm.expectRevert(OGDistributor.SlippageOrExpired.selector);
        dist.activateWithETH{value: 1 ether}(1, 1, START_PRICE - 1, block.timestamp);
        vm.stopPrank();
        assertEq(dist.level(1), 0);
        assertEq(token.totalBurned(), 0);
    }
}
