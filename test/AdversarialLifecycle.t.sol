// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {stdError} from "forge-std/Test.sol";
import {SystemBase} from "./SystemBase.sol";
import {MockSpepe} from "./mocks/MockSpepe.sol";
import {OGDistributor} from "src/OGDistributor.sol";
import {OGAuction} from "src/OGAuction.sol";
import {Guard} from "src/Interfaces.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

contract CallbackProbe {
    address public target;
    bytes public payload;
    bool public rejectETH;
    bool public rejectNFT;
    bool public attempted;
    bool public succeeded;
    bytes public reason;

    constructor(OGDistributor d, MockSpepe n) {
        d.token().approve(address(d), type(uint256).max);
        d.token().approve(address(d.auction()), type(uint256).max);
        n.setApprovalForAll(address(d), true);
    }

    function configure(address target_, bytes calldata payload_, bool eth_, bool nft_) external {
        target = target_;
        payload = payload_;
        rejectETH = eth_;
        rejectNFT = nft_;
        attempted = false;
        succeeded = false;
        delete reason;
    }

    function _attempt() private {
        if (target == address(0)) return;
        attempted = true;
        (succeeded, reason) = target.call(payload);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!rejectNFT, "NFT rejected");
        _attempt();
        return this.onERC721Received.selector;
    }

    receive() external payable {
        require(!rejectETH, "ETH rejected");
        _attempt();
    }
}

contract AdversarialLifecycleTest is SystemBase {
    using StateLibrary for IPoolManager;
    event Activated(uint256 indexed tokenId, address indexed owner, uint8 level, uint256 burned);
    event Upgraded(uint256 indexed tokenId, address indexed owner, uint8 oldLevel, uint8 newLevel, uint256 burned);
    event Exited(uint256 indexed tokenId, address indexed owner, uint256 ethPaid);
    event AuctionListed(uint256 indexed tokenId, uint256 startPrice, uint256 startedAt);
    event AuctionSold(uint256 indexed tokenId, address indexed buyer, address indexed recipient, uint256 burned);

    function setUp() public {
        _systemAtPrice(true, true, LAUNCH_PRICE, 1e21);
        _mint(ALICE, 1);
        _mint(BOB, 2);
        vm.warp(hook.openedAt() + 1 hours);
    }

    function test_approvedOperatorCannotActivateUpgradeOrExit() public {
        vm.prank(ALICE);
        nft.setApprovalForAll(BOB, true);
        vm.prank(BOB);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.activate(1, 1);
        _activate(ALICE, 1, 1);
        vm.prank(BOB);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.activate(1, 2);
        vm.prank(BOB);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.activateWithETH{value: 1 ether}(1, 2, LAUNCH_PRICE / 2, block.timestamp);
        vm.warp(dist.lastActivation(1) + 24 hours);
        vm.prank(BOB);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.exit(1);
        assertEq(dist.level(1), 1);
        assertEq(token.totalBurned(), 50_000 ether);
    }

    function test_eventsIncludeUpgradeDifferenceExitAndGiftedSale() public {
        vm.expectEmit(true, true, false, true, address(dist));
        emit Activated(1, ALICE, 1, 50_000 ether);
        _activate(ALICE, 1, 1);
        _fees(2 ether, 0);
        vm.expectEmit(true, true, false, true, address(dist));
        emit Upgraded(1, ALICE, 1, 3, 350_000 ether);
        _activate(ALICE, 1, 3);
        vm.warp(dist.lastActivation(1) + 24 hours);
        uint256 now_ = vm.getBlockTimestamp();
        vm.expectEmit(true, false, false, true, address(auction));
        emit AuctionListed(1, 500_000 ether, now_);
        vm.expectEmit(true, true, false, true, address(dist));
        emit Exited(1, ALICE, 2 ether);
        vm.prank(ALICE);
        dist.exit(1);
        vm.expectEmit(true, true, true, true, address(auction));
        emit AuctionSold(1, BOB, ALICE, 500_000 ether);
        uint256 before = token.balanceOf(BOB);
        vm.prank(BOB);
        auction.buy(1, 500_000 ether, ALICE, now_);
        assertEq(nft.ownerOf(1), ALICE);
        assertEq(before - token.balanceOf(BOB), 500_000 ether);
        assertEq(dist.level(1), 0);
        assertEq(dist.pending(1), 0);
    }

    function test_insufficientBurnAllowanceRollsBackUpgradeAndStream() public {
        _activate(ALICE, 1, 1);
        _fees(3 ether, 30 ether);
        vm.warp(vm.getBlockTimestamp() + 15 days);
        uint256 pending = dist.pending(1);
        uint256 debt = dist.debtScaled(1);
        uint256 acc = dist.accPerWeight();
        uint256 start = dist.lastActivation(1);
        uint256 burned = token.totalBurned();
        vm.prank(ALICE);
        token.approve(address(dist), 100_000 ether - 1);
        vm.prank(ALICE);
        vm.expectRevert(stdError.arithmeticError);
        dist.activate(1, 2);
        assertEq(dist.pending(1), pending);
        assertEq(dist.debtScaled(1), debt);
        assertEq(dist.accPerWeight(), acc);
        assertEq(dist.lastActivation(1), start);
        assertEq(token.totalBurned(), burned);
        assertEq(dist.activePerLevel(1), 1);
        assertEq(dist.activePerLevel(2), 0);
        vm.prank(ALICE);
        token.approve(address(dist), 100_000 ether);
        _activate(ALICE, 1, 2);
        assertEq(dist.pending(1), pending);
        assertEq(token.allowance(ALICE, address(dist)), 0);
    }

    function test_invalidLevelBoundariesAndNonexistentNFT() public {
        uint8[3] memory invalid = [uint8(0), 4, 255];
        for (uint256 i; i < invalid.length; ++i) {
            vm.prank(ALICE);
            vm.expectRevert(OGDistributor.InvalidLevel.selector);
            dist.activate(1, invalid[i]);
        }
        vm.prank(ALICE);
        vm.expectRevert("NOT_MINTED");
        dist.activate(999, 1);
        _activate(ALICE, 1, 3);
        for (uint8 l; l <= 3; ++l) {
            vm.prank(ALICE);
            vm.expectRevert(OGDistributor.InvalidLevel.selector);
            dist.activate(1, l);
        }
    }

    function test_transferUpgradeLockExactBoundaryAndZeroRewardExit() public {
        _activate(ALICE, 1, 1);
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        vm.prank(ALICE);
        nft.transferFrom(ALICE, BOB, 1);
        vm.prank(ALICE);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.activate(1, 2);
        _activate(BOB, 1, 2);
        uint256 unlock = dist.lastActivation(1) + 24 hours;
        vm.warp(unlock - 1);
        vm.prank(BOB);
        vm.expectRevert(OGDistributor.Locked.selector);
        dist.exit(1);
        vm.warp(unlock);
        uint256 before = BOB.balance;
        vm.prank(BOB);
        dist.exit(1);
        assertEq(BOB.balance, before);
        assertEq(dist.totalWeight(), 0);
        assertEq(dist.lastActivation(1), 0);
        assertEq(dist.debtScaled(1), 0);
        assertEq(dist.creditScaled(1), 0);
        assertEq(nft.ownerOf(1), address(auction));
    }

    function test_fundingRejectsWrongAmountsAndCannotChangeEntitlement() public {
        _activate(ALICE, 1, 1);
        vm.deal(address(hook), 10 ether);
        vm.startPrank(address(hook));
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.receiveFees{value: 2 ether}(1 ether, 0);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.fundFeeClaims{value: 1}();
        dist.receiveFeeClaims(3 ether, 2 ether);
        vm.expectRevert(OGDistributor.Unauthorized.selector);
        dist.fundFeeClaims{value: 5 ether + 1}();
        dist.fundFeeClaims{value: 2 ether}();
        assertEq(dist.unfundedFees(), 3 ether);
        assertEq(dist.pending(1), 3 ether);
        assertEq(dist.backlogLeft(), 2 ether);
        dist.fundFeeClaims{value: 3 ether}();
        vm.stopPrank();
        assertEq(dist.unfundedFees(), 0);
        assertEq(address(dist).balance, 5 ether);
        assertEq(dist.pending(1), 3 ether);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_threeRewardEpochsPreserveFractionsAcrossUpgrades(uint96 x, uint96 y, uint96 z) public {
        uint256 first = bound(x, 1, 100 ether);
        uint256 second = bound(y, 1, 100 ether);
        uint256 third = bound(z, 1, 100 ether);
        _activate(ALICE, 1, 1);
        _activate(BOB, 2, 2);
        _fees(first, 0); // Alice : Bob = 1 : 2
        _activate(ALICE, 1, 3);
        _fees(second, 0); // 4 : 2
        _activate(BOB, 2, 3);
        _fees(third, 0); // 4 : 4
        // Independent rational oracle for all three epochs, rounded only once per NFT.
        uint256 aliceDue = (8 * first + 16 * second + 12 * third) / 24;
        uint256 bobDue = (16 * first + 8 * second + 12 * third) / 24;
        assertApproxEqAbs(dist.pending(1), aliceDue, 1);
        assertApproxEqAbs(dist.pending(2), bobDue, 1);
        assertLe(dist.pending(1) + dist.pending(2), first + second + third);
        assertEq(token.totalBurned(), 800_000 ether);
        vm.warp(dist.lastActivation(2) + 24 hours);
        uint256 aliceBefore = ALICE.balance;
        uint256 bobBefore = BOB.balance;
        vm.prank(ALICE);
        dist.exit(1);
        vm.prank(BOB);
        dist.exit(2);
        assertApproxEqAbs(ALICE.balance - aliceBefore, aliceDue, 1);
        assertApproxEqAbs(BOB.balance - bobBefore, bobDue, 1);
        assertLe(address(dist).balance, 3, "only bounded rounding dust remains");
    }

    function _probe() private returns (CallbackProbe p) {
        p = new CallbackProbe(dist, nft);
        token.transfer(address(p), 3_000_000 ether);
        vm.deal(address(p), 10 ether);
        nft.mint(address(p), 3);
        nft.mint(address(p), 4);
    }

    function test_exitCannotReenterAnotherEligibleNFT() public {
        CallbackProbe p = _probe();
        _activate(address(p), 3, 1);
        _activate(address(p), 4, 1);
        _fees(2 ether, 0);
        vm.warp(dist.lastActivation(4) + 24 hours);
        p.configure(address(dist), abi.encodeCall(dist.exit, (4)), false, false);
        vm.prank(address(p));
        dist.exit(3);
        assertTrue(p.attempted());
        assertFalse(p.succeeded());
        assertEq(p.reason(), abi.encodeWithSelector(Guard.Reentrancy.selector));
        assertEq(dist.pending(4), 1 ether);
        assertEq(nft.ownerOf(4), address(p));
        assertEq(auction.auctionCount(), 1);
        assertEq(dist.totalWeight(), 1);
    }

    function test_ETHActivationRefundRejectRollsBackPoolFeeBurnAndWeight() public {
        CallbackProbe p = _probe();
        p.configure(address(0), "", true, false);
        uint256 managerBefore = address(manager).balance;
        uint256 teamBefore = hook.TEAM().balance;
        uint256 ownerBefore = address(p).balance;
        (uint160 priceBefore,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        vm.prank(address(p));
        vm.expectRevert(Guard.ETHSendFailed.selector);
        dist.activateWithETH{value: 0.01 ether}(3, 1, LAUNCH_PRICE / 2, block.timestamp);
        (uint160 priceAfter,,,) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(priceAfter, priceBefore);
        assertEq(address(manager).balance, managerBefore);
        assertEq(hook.TEAM().balance, teamBefore);
        assertEq(address(p).balance, ownerBefore);
        assertEq(token.totalBurned(), 0);
        assertEq(dist.totalWeight(), 0);
        assertEq(dist.backlogLeft(), 0);
        p.configure(address(dist), abi.encodeCall(dist.activate, (4, 1)), false, false);
        vm.prank(address(p));
        dist.activateWithETH{value: 0.01 ether}(3, 1, LAUNCH_PRICE / 2, block.timestamp);
        assertTrue(p.attempted());
        assertEq(p.reason(), abi.encodeWithSelector(Guard.Reentrancy.selector));
        assertFalse(p.succeeded());
        assertEq(dist.level(3), 1);
        assertEq(dist.level(4), 0);
        assertEq(token.totalBurned(), 50_000 ether);
    }

    function test_auctionReceiverRejectRollsBackBurnAllowanceAndListing() public {
        _activate(ALICE, 1, 1);
        vm.warp(dist.lastActivation(1) + 24 hours);
        vm.prank(ALICE);
        dist.exit(1);
        CallbackProbe p = _probe();
        p.configure(address(0), "", false, true);
        vm.prank(BOB);
        token.approve(address(auction), 500_000 ether);
        uint256 burned = token.totalBurned();
        uint256 before = token.balanceOf(BOB);
        vm.prank(BOB);
        vm.expectRevert("NFT rejected");
        auction.buy(1, 500_000 ether, address(p), block.timestamp);
        assertEq(token.totalBurned(), burned);
        assertEq(token.balanceOf(BOB), before);
        assertEq(token.allowance(BOB, address(auction)), 500_000 ether);
        assertEq(auction.lastSalePrice(1), 0);
        assertEq(auction.price(1), 500_000 ether);
        assertEq(auction.currentAuctions(0, 100)[0].tokenId, 1);
        assertEq(nft.ownerOf(1), address(auction));
        p.configure(address(0), "", false, false);
        vm.prank(BOB);
        auction.buy(1, 500_000 ether, address(p), block.timestamp);
        assertEq(token.totalBurned() - burned, 500_000 ether);
        assertEq(nft.ownerOf(1), address(p));
    }

    function test_auctionReentryCannotBuyDifferentLiveListing() public {
        _activate(ALICE, 1, 1);
        _activate(BOB, 2, 1);
        vm.warp(dist.lastActivation(2) + 24 hours);
        vm.prank(ALICE);
        dist.exit(1);
        vm.prank(BOB);
        dist.exit(2);
        CallbackProbe p = _probe();
        p.configure(
            address(auction), abi.encodeCall(auction.buy, (2, 500_000 ether, address(p), block.timestamp)), false, false
        );
        vm.prank(address(p));
        auction.buy(1, 500_000 ether, address(p), block.timestamp);
        assertTrue(p.attempted());
        assertFalse(p.succeeded());
        assertEq(p.reason(), abi.encodeWithSelector(Guard.Reentrancy.selector));
        assertEq(nft.ownerOf(2), address(auction));
        assertEq(auction.auctionCount(), 1);
        assertEq(auction.currentAuctions(0, 10)[0].tokenId, 2);
    }

    function test_auctionBadRecipientsAndUnderfundedBuyerLeaveListing() public {
        _activate(ALICE, 1, 1);
        vm.warp(dist.lastActivation(1) + 24 hours);
        vm.prank(ALICE);
        dist.exit(1);
        vm.expectRevert(OGAuction.InvalidAuction.selector);
        auction.buy(1, 500_000 ether, address(0), block.timestamp);
        vm.expectRevert(OGAuction.InvalidAuction.selector);
        auction.buy(1, 500_000 ether, address(auction), block.timestamp);
        vm.prank(BOB);
        token.approve(address(auction), 500_000 ether - 1);
        vm.prank(BOB);
        vm.expectRevert(stdError.arithmeticError);
        auction.buy(1, 500_000 ether, BOB, block.timestamp);
        assertEq(auction.auctionCount(), 1);
        assertEq(auction.lastSalePrice(1), 0);
        assertEq(token.totalBurned(), 50_000 ether);
    }
}
