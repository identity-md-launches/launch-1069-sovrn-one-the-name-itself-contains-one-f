// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {SystemBase} from "./SystemBase.sol";
import {OGDistributor} from "../src/OGDistributor.sol";
import {OGAuction} from "../src/OGAuction.sol";
import {MockSpepe} from "./mocks/MockSpepe.sol";

contract RewardHandler is Test {
    OGDistributor public d;
    OGAuction public a;
    MockSpepe public n;
    uint256 public totalFees;
    uint256 public totalPaid;

    constructor(OGDistributor dist, MockSpepe nft) {
        d = dist;
        a = dist.auction();
        n = nft;
        dist.token().approve(address(dist), type(uint256).max);
        dist.token().approve(address(a), type(uint256).max);
        nft.setApprovalForAll(address(dist), true);
    }

    function activate(uint256 raw, uint8 rawLevel) external {
        uint256 id = raw % 8 + 1;
        uint8 old = d.level(id);
        if (n.ownerOf(id) != address(this) || old == 3) return;
        uint8 l = uint8(bound(rawLevel, uint256(old) + 1, 3));
        if (d.token().balanceOf(address(this)) < d.activationCost(id, l)) return;
        d.activate(id, l);
    }

    function fees(uint96 raw, bool surplus) external {
        uint256 amount = bound(raw, 1, 1 ether);
        vm.deal(d.hook(), d.hook().balance + amount);
        totalFees += amount;
        vm.prank(d.hook());
        d.receiveFees{value: amount}(surplus ? 0 : amount, surplus ? amount : 0);
    }

    function advance(uint32 raw) external {
        vm.warp(block.timestamp + bound(raw, 0, 2 days));
        d.checkpoint();
    }

    function exit(uint256 raw) external {
        uint256 id = raw % 8 + 1;
        if (n.ownerOf(id) != address(this) || d.level(id) == 0 || block.timestamp < d.lastActivation(id) + 24 hours) {
            return;
        }
        totalPaid += d.pending(id);
        d.exit(id);
    }

    function buy(uint256 raw) external {
        uint256 id = raw % 8 + 1;
        uint256 price = a.price(id);
        if (price == 0 || price > d.token().balanceOf(address(this))) return;
        a.buy(id, price, address(this), block.timestamp);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
    receive() external payable {}
}

contract AccountingInvariantTest is SystemBase {
    RewardHandler private handler;

    function setUp() public {
        _system(false, true);
        handler = new RewardHandler(dist, nft);
        token.transfer(address(handler), 100_000_000 ether);
        for (uint256 i = 1; i <= 8; ++i) {
            nft.mint(address(handler), i);
        }
        bytes4[] memory selectors = new bytes4[](5);
        selectors[0] = handler.activate.selector;
        selectors[1] = handler.fees.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.exit.selector;
        selectors[4] = handler.buy.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
        // The handler owns all fixture NFTs; its caller has no role in the properties.
        // Pinning the caller avoids thousands of irrelevant fork account RPC lookups.
        targetSender(address(handler));
    }

    function invariant_weightAndLevelCountsConserved() public view {
        uint256 sum;
        uint256[4] memory counts;
        for (uint256 i = 1; i <= 8; ++i) {
            sum += dist.weight(i);
            ++counts[dist.level(i)];
            if (auction.price(i) > 0) {
                assertEq(dist.level(i), 0);
                assertEq(nft.ownerOf(i), address(auction));
                assertEq(dist.pending(i), 0);
            }
        }
        assertEq(sum, dist.totalWeight());
        for (uint8 l = 1; l <= 3; ++l) {
            assertEq(counts[l], dist.activePerLevel(l));
        }
    }

    function invariant_ETHSolvencyAndConservation() public view {
        uint256 owed = dist.backlogLeft();
        for (uint256 i = 1; i <= 8; ++i) {
            owed += dist.pending(i);
        }
        assertLe(owed, address(dist).balance + dist.unfundedFees());
        assertEq(address(dist).balance + handler.totalPaid(), handler.totalFees());
    }

    function invariant_burnAccountingAndSupply() public view {
        assertEq(token.totalBurned(), token.balanceOf(token.DEAD()));
        assertEq(token.totalSupply(), 1_000_000_000 ether);
    }
}
