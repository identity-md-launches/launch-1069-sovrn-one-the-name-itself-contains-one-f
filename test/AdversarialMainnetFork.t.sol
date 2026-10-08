// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FeeAssertions} from "./AdversarialFees.t.sol";
import {ISpepe} from "src/Interfaces.sol";
import {OGDistributor} from "src/OGDistributor.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

interface IAdversarialLiveSpepe is ISpepe {
    function mintOpen() external view returns (bool);
    function MAX_SUPPLY() external view returns (uint256);
    function symbol() external view returns (string memory);
    function approve(address operator, uint256 id) external;
}

/// @notice Run with --fork-url URL --fork-block-number 26147125. No RPC is required by the default suite.
contract AdversarialMainnetForkTest is FeeAssertions {
    IAdversarialLiveSpepe private live;

    function setUp() public {
        address collection = 0x999ce0CE8C5f7661e0c74a568FfE27CEB9177bDB;
        if (block.chainid != 1 || collection.code.length == 0) {
            vm.skip(true);
            return;
        }
        _systemAtPrice(true, false, LAUNCH_PRICE, 1e21);
        live = IAdversarialLiveSpepe(collection);
    }

    function test_liveMintStatusAndFourModeSettlementAtOpeningAndAfterDecay() public {
        assertEq(live.symbol(), "SPEPE");
        assertTrue(live.mintOpen());
        assertGt(live.totalMinted(), 0);
        assertLt(live.totalMinted(), live.MAX_SUPPLY());
        (bool ok,) = address(live).staticcall(abi.encodeWithSignature("totalSupply()"));
        assertFalse(ok);
        for (uint256 phase; phase < 2; ++phase) {
            if (phase != 0) vm.warp(hook.openedAt() + 1 hours);
            _assertSettledFee(true, -0.001 ether, TickMath.MIN_SQRT_PRICE + 1);
            _assertSettledFee(true, 1000 ether, TickMath.MIN_SQRT_PRICE + 1);
            _assertSettledFee(false, -1000 ether, TickMath.MAX_SQRT_PRICE - 1);
            _assertSettledFee(false, 0.00001 ether, TickMath.MAX_SQRT_PRICE - 1);
        }
    }

    function test_realNFTTransferPreservesRewardsAndNewOwnerCanExit() public {
        uint256 id = 1;
        address oldOwner = live.ownerOf(id);
        token.transfer(oldOwner, 400_000 ether);
        vm.startPrank(oldOwner);
        token.approve(address(dist), 400_000 ether);
        dist.activate(id, 3);
        vm.stopPrank();
        vm.warp(hook.openedAt() + 1 hours);
        _trade(true, -0.001 ether);
        uint256 pending = dist.pending(id);
        uint256 activatedAt = dist.lastActivation(id);
        assertGt(pending, 0);
        vm.prank(oldOwner);
        live.transferFrom(oldOwner, BOB, id);
        assertEq(dist.pending(id), pending);
        assertEq(dist.level(id), 3);
        assertEq(dist.lastActivation(id), activatedAt);
        vm.prank(oldOwner);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.exit(id);
        vm.prank(BOB);
        vm.expectRevert(OGDistributor.Locked.selector);
        dist.exit(id);
        vm.prank(BOB);
        live.approve(address(dist), id);
        vm.warp(activatedAt + 24 hours);
        uint256 before = BOB.balance;
        vm.prank(BOB);
        dist.exit(id);
        assertEq(BOB.balance - before, pending);
        assertEq(live.ownerOf(id), address(auction));
        vm.prank(ALICE);
        auction.buy(id, 500_000 ether, ALICE, vm.getBlockTimestamp());
        assertEq(live.ownerOf(id), ALICE);
        assertEq(dist.pending(id), 0);
        assertEq(dist.level(id), 0);
        assertEq(token.totalBurned(), 900_000 ether);
    }
}
