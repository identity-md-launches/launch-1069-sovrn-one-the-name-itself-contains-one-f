// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemBase} from "./SystemBase.sol";
import {ISpepe} from "../src/Interfaces.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

interface ILiveSpepe is ISpepe {
    function mintOpen() external view returns (bool);
    function MAX_SUPPLY() external view returns (uint256);
    function symbol() external view returns (string memory);
    function approve(address operator, uint256 id) external;
}

/// @notice Explicit fork suite: forge test --match-contract MainnetForkTest --fork-url URL --fork-block-number BLOCK.
///         Offline default runs skip honestly; no environment variables or RPC dependence in default tests.
contract MainnetForkTest is SystemBase {
    ILiveSpepe private live;

    function setUp() public {
        if (block.chainid != 1 || address(0x999ce0CE8C5f7661e0c74a568FfE27CEB9177bDB).code.length == 0) {
            vm.skip(true);
            return;
        }
        _systemAtPrice(true, false, LAUNCH_PRICE, 1e21);
        live = ILiveSpepe(hook.COLLECTION());
    }

    function test_liveCollectionAndCompleteRewardAuctionLifecycle() public {
        assertEq(live.symbol(), "SPEPE");
        assertTrue(live.mintOpen());
        assertGt(live.totalMinted(), 0);
        assertLt(live.totalMinted(), live.MAX_SUPPLY());
        (bool ok,) = address(live).staticcall(abi.encodeWithSignature("totalSupply()"));
        assertFalse(ok);
        uint256 id = 1;
        address owner = live.ownerOf(id);
        token.transfer(owner, 500_000 ether);
        vm.deal(owner, 100 ether);
        vm.startPrank(owner);
        token.approve(address(dist), 400_000 ether);
        dist.activate(id, 3);
        live.approve(address(dist), id);
        vm.stopPrank();
        vm.warp(hook.openedAt() + 1 hours);
        _trade(true, -0.1 ether);
        _trade(true, 10_000 ether);
        _trade(false, -10_000 ether);
        _trade(false, 0.01 ether);
        assertGt(dist.pending(id), 0);
        vm.warp(block.timestamp + 24 hours);
        uint256 payout = dist.pending(id);
        uint256 before = owner.balance;
        vm.prank(owner);
        dist.exit(id);
        assertEq(owner.balance - before, payout);
        assertEq(live.ownerOf(id), address(auction));
        vm.warp(block.timestamp + 36 hours);
        vm.prank(BOB);
        auction.buy(id, 50_000 ether, BOB, block.timestamp);
        assertEq(live.ownerOf(id), BOB);
        assertEq(dist.level(id), 0);
        assertEq(dist.pending(id), 0);
    }
}
