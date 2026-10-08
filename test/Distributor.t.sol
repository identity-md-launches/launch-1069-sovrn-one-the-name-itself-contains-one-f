// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {SystemBase} from "./SystemBase.sol";
import {OGDistributor} from "../src/OGDistributor.sol";
import {OGAuction} from "../src/OGAuction.sol";
import {OG} from "../src/OG.sol";
import {Guard} from "../src/Interfaces.sol";
import {MockSpepe} from "./mocks/MockSpepe.sol";

contract Receiver {
    OGDistributor public dist;
    OGAuction public auction;
    MockSpepe public nft;
    bool public reject;
    bool public reentryFailed;
    uint256 public id;

    constructor(OGDistributor d, MockSpepe n) {
        dist = d;
        auction = d.auction();
        nft = n;
        d.token().approve(address(d), type(uint256).max);
        d.token().approve(address(auction), type(uint256).max);
        n.setApprovalForAll(address(d), true);
    }

    function activate(uint256 id_) external {
        id = id_;
        dist.activate(id_, 1);
    }

    function exit() external {
        dist.exit(id);
    }

    function setReject(bool b) external {
        reject = b;
    }

    function buy(uint256 id_) external {
        id = id_;
        auction.buy(id_, type(uint256).max, address(this), block.timestamp);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        (bool ok,) =
            address(auction).call(abi.encodeCall(auction.buy, (id, type(uint256).max, address(this), block.timestamp)));
        reentryFailed = !ok;
        return this.onERC721Received.selector;
    }

    receive() external payable {
        if (reject) revert();
        (bool ok,) = address(dist).call(abi.encodeCall(dist.exit, (id)));
        reentryFailed = !ok;
    }
}

contract DistributorTest is SystemBase {
    function setUp() public {
        _system(false, true);
        _mint(ALICE, 1);
        _mint(BOB, 2);
    }

    function test_weightedAccrualAndUpgradePreservesPending() public {
        _activate(ALICE, 1, 1);
        _activate(BOB, 2, 2);
        _fees(3 ether, 0);
        assertEq(dist.pending(1), 1 ether);
        assertEq(dist.pending(2), 2 ether);
        uint256 before = token.totalBurned();
        _activate(ALICE, 1, 3);
        assertEq(token.totalBurned() - before, 350_000 ether);
        assertEq(dist.pending(1), 1 ether);
        assertEq(dist.totalWeight(), 6);
        assertEq(dist.activePerLevel(1), 0);
        assertEq(dist.activePerLevel(2), 1);
        assertEq(dist.activePerLevel(3), 1);
        _fees(6 ether, 0);
        assertEq(dist.pending(1), 5 ether);
        assertEq(dist.pending(2), 4 ether);
    }

    function test_costsAndUnauthorizedOrInvalidActions() public {
        assertEq(dist.activationCost(1, 1), 50_000 ether);
        assertEq(dist.activationCost(1, 2), 150_000 ether);
        assertEq(dist.activationCost(1, 3), 400_000 ether);
        vm.prank(BOB);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.activate(1, 1);
        vm.prank(ALICE);
        vm.expectRevert(OGDistributor.InvalidLevel.selector);
        dist.activate(1, 4);
        _activate(ALICE, 1, 1);
        vm.prank(ALICE);
        vm.expectRevert(OGDistributor.InvalidLevel.selector);
        dist.activate(1, 1);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.receiveFees{value: 1}(1, 0);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.receiveFeeClaims(1, 0);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.fundFeeClaims{value: 1}();
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.unlockCallback("");
    }

    function test_noRetroactiveRewardsIncludingNewlyMintedNFT() public {
        _activate(ALICE, 1, 1);
        _fees(2 ether, 0);
        _mint(BOB, 9999);
        _activate(BOB, 9999, 3);
        assertEq(dist.pending(9999), 0);
        _fees(5 ether, 0);
        assertEq(dist.pending(9999), 4 ether);
        assertEq(dist.pending(1), 3 ether);
    }

    function test_backlogWaitsAndStreamsWithoutWindfall() public {
        _fees(30 ether, 0);
        assertEq(dist.backlogLeft(), 30 ether);
        assertEq(dist.streamEnd(), 0);
        vm.warp(block.timestamp + 40 days);
        _activate(ALICE, 1, 1);
        assertEq(dist.pending(1), 0);
        uint256 started = block.timestamp;
        assertEq(dist.streamEnd(), started + 30 days);
        vm.warp(started + 15 days);
        assertEq(dist.pending(1), 15 ether);
        assertEq(dist.backlogLeft(), 15 ether);
        _activate(BOB, 2, 1);
        assertEq(dist.pending(2), 0);
        vm.warp(started + 30 days);
        assertEq(dist.pending(1), 22.5 ether);
        assertEq(dist.pending(2), 7.5 ether);
        assertEq(dist.backlogLeft(), 0);
    }

    function test_streamPausesWithZeroWeightAndRestarts() public {
        _fees(30 ether, 0);
        _activate(ALICE, 1, 1);
        vm.warp(block.timestamp + 10 days);
        uint256 before = ALICE.balance;
        vm.prank(ALICE);
        dist.exit(1);
        assertEq(ALICE.balance - before, 10 ether);
        assertEq(dist.backlogLeft(), 20 ether);
        assertEq(dist.streamEnd(), 0);
        vm.warp(block.timestamp + 100 days);
        assertEq(dist.backlogLeft(), 20 ether);
        _activate(BOB, 2, 1);
        assertEq(dist.pending(2), 0);
        vm.warp(block.timestamp + 15 days);
        assertEq(dist.pending(2), 10 ether);
    }

    function test_surplusStreamsEvenWithActiveWeight() public {
        _activate(ALICE, 1, 1);
        _fees(1 ether, 30 ether);
        assertEq(dist.pending(1), 1 ether);
        vm.warp(block.timestamp + 15 days);
        assertEq(dist.pending(1), 16 ether);
        _fees(0, 15 ether);
        assertEq(dist.backlogLeft(), 30 ether);
        assertEq(dist.streamEnd(), block.timestamp + 30 days);
        vm.warp(block.timestamp + 30 days);
        assertEq(dist.pending(1), 46 ether);
    }

    function test_transferCarriesLevelPendingAndLock() public {
        _activate(ALICE, 1, 2);
        _fees(2 ether, 0);
        uint256 when = dist.lastActivation(1);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, 1);
        assertEq(dist.level(1), 2);
        assertEq(dist.pending(1), 2 ether);
        assertEq(dist.lastActivation(1), when);
        vm.prank(ALICE);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.exit(1);
        vm.prank(BOB);
        vm.expectRevert(OGDistributor.Locked.selector);
        dist.exit(1);
        vm.warp(when + 24 hours);
        uint256 before = BOB.balance;
        vm.prank(BOB);
        dist.exit(1);
        assertEq(BOB.balance - before, 2 ether);
        assertEq(dist.level(1), 0);
        assertEq(dist.pending(1), 0);
        assertEq(dist.totalWeight(), 0);
        assertEq(nft.ownerOf(1), address(auction));
        assertEq(auction.price(1), 500_000 ether);
    }

    function test_upgradeResetsLockAndExitNeedsNFTApproval() public {
        _activate(ALICE, 1, 1);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        _activate(ALICE, 1, 2);
        vm.prank(ALICE);
        vm.expectRevert(OGDistributor.Locked.selector);
        dist.exit(1);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(ALICE);
        nft.setApprovalForAll(address(dist), false);
        vm.prank(ALICE);
        vm.expectRevert();
        dist.exit(1);
        assertEq(dist.level(1), 2);
        assertEq(dist.totalWeight(), 2);
    }

    function test_exitETHReentryAndFailedPayoutRollBack() public {
        Receiver r = new Receiver(dist, nft);
        token.transfer(address(r), 100_000 ether);
        nft.mint(address(r), 3);
        r.activate(3);
        _fees(2 ether, 0);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        r.setReject(true);
        vm.expectRevert(Guard.ETHSendFailed.selector);
        r.exit();
        assertEq(nft.ownerOf(3), address(r));
        assertEq(dist.pending(3), 2 ether);
        assertEq(dist.totalWeight(), 1);
        assertEq(auction.auctionCount(), 0);
        r.setReject(false);
        r.exit();
        assertTrue(r.reentryFailed());
        assertEq(address(r).balance, 2 ether);
        assertEq(dist.pending(3), 0);
    }

    function test_claimAccountingAtSwapTimeNotRedemption() public {
        _activate(ALICE, 1, 1);
        vm.prank(address(hook));
        dist.receiveFeeClaims(2 ether, 0);
        _activate(BOB, 2, 1);
        assertEq(dist.pending(1), 2 ether);
        assertEq(dist.pending(2), 0);
        assertEq(dist.unfundedFees(), 2 ether);
        vm.deal(address(hook), 2 ether);
        vm.prank(address(hook));
        dist.fundFeeClaims{value: 2 ether}();
        assertEq(dist.pending(1), 2 ether);
        assertEq(dist.pending(2), 0);
        assertEq(dist.unfundedFees(), 0);
    }

    function testFuzz_roundingConservesETH(uint96 raw) public {
        uint256 amount = bound(uint256(raw), 1, 100 ether);
        _activate(ALICE, 1, 1);
        _activate(BOB, 2, 3);
        _fees(amount, 0);
        _activate(ALICE, 1, 2);
        _fees(amount, 0);
        _activate(ALICE, 1, 3);
        _fees(amount, 0);
        uint256 pendingSum = dist.pending(1) + dist.pending(2);
        assertLe(pendingSum, 3 * amount);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        uint256 balance = address(dist).balance;
        vm.prank(ALICE);
        dist.exit(1);
        vm.prank(BOB);
        dist.exit(2);
        assertEq(address(dist).balance, balance - pendingSum);
        assertEq(dist.totalWeight(), 0);
    }
}

contract AuctionTest is SystemBase {
    function setUp() public {
        _system(false, true);
        _mint(ALICE, 1);
        _activate(ALICE, 1, 1);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(ALICE);
        dist.exit(1);
    }

    function test_exponentialDecayFloorBurnAndResaleStart() public {
        assertEq(auction.price(1), 500_000 ether);
        uint256 start = block.timestamp;
        vm.warp(start + 18 hours);
        assertApproxEqAbs(auction.price(1), 158113883008418966599944, 1e9);
        vm.warp(start + 36 hours);
        assertEq(auction.price(1), 50_000 ether);
        vm.warp(start + 365 days);
        assertEq(auction.price(1), 50_000 ether);
        uint256 before = token.totalBurned();
        vm.prank(BOB);
        auction.buy(1, 50_000 ether, BOB, block.timestamp);
        assertEq(token.totalBurned() - before, 50_000 ether);
        assertEq(auction.lastSalePrice(1), 50_000 ether);
        assertEq(auction.auctionCount(), 0);
        assertEq(nft.ownerOf(1), BOB);
        assertEq(dist.level(1), 0);
        assertEq(dist.pending(1), 0);
        _activate(BOB, 1, 1);
        vm.prank(BOB);
        nft.setApprovalForAll(address(dist), true);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(BOB);
        dist.exit(1);
        assertEq(auction.price(1), 500_000 ether);
        vm.prank(BOB);
        auction.buy(1, 500_000 ether, BOB, block.timestamp);
        _activate(BOB, 1, 1);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(BOB);
        dist.exit(1);
        assertEq(auction.price(1), 5_000_000 ether);
    }

    function test_auctionFailuresAndReceiverReentry() public {
        vm.expectRevert(OGAuction.Unauthorized.selector);
        auction.list(99);
        vm.expectRevert(OGAuction.SlippageOrExpired.selector);
        auction.buy(1, 1, address(this), block.timestamp);
        vm.expectRevert(OGAuction.SlippageOrExpired.selector);
        auction.buy(1, type(uint256).max, address(this), block.timestamp - 1);
        vm.expectRevert(OGAuction.InvalidAuction.selector);
        auction.buy(2, type(uint256).max, address(this), block.timestamp);
        Receiver r = new Receiver(dist, nft);
        token.transfer(address(r), 500_000 ether);
        r.buy(1);
        assertTrue(r.reentryFailed());
        assertEq(nft.ownerOf(1), address(r));
        vm.expectRevert(OGAuction.InvalidAuction.selector);
        auction.buy(1, type(uint256).max, address(this), block.timestamp);
    }

    function test_boundedAuctionViewsAndUnexpectedNFTRejected() public {
        OGAuction.Listing[] memory page = auction.currentAuctions(0, 1000);
        assertEq(page.length, 1);
        assertEq(page[0].tokenId, 1);
        assertEq(page[0].price, auction.price(1));
        assertEq(auction.currentAuctions(10, 3).length, 0);
        _mint(ALICE, 2);
        vm.prank(ALICE);
        vm.expectRevert();
        nft.safeTransferFrom(ALICE, address(auction), 2);
    }

    function testFuzz_monotonicPrice(uint32 a, uint32 b) public {
        uint256 first = bound(a, 0, 100 days);
        uint256 second = bound(b, first, 100 days);
        uint256 start = block.timestamp;
        vm.warp(start + first);
        uint256 p1 = auction.price(1);
        vm.warp(start + second);
        uint256 p2 = auction.price(1);
        assertLe(p2, p1);
        assertGe(p2, 50_000 ether);
        assertLe(p1, 500_000 ether);
    }
}
