// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SystemBase} from "./SystemBase.sol";
import {OGAuction} from "src/OGAuction.sol";

contract AuctionPropertiesTest is SystemBase {
    function setUp() public {
        _system(false, true);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_exponentialCurveHasGeometricMidpoint(uint32 raw) public {
        _mint(ALICE, 1);
        _activate(ALICE, 1, 1);
        vm.warp(dist.lastActivation(1) + 24 hours);
        vm.prank(ALICE);
        dist.exit(1);
        uint256 start = vm.getBlockTimestamp();
        uint256 t = bound(raw, 1, 18 hours);
        uint256 p0 = auction.price(1);
        vm.warp(start + t);
        uint256 p1 = auction.price(1);
        vm.warp(start + 2 * t);
        uint256 p2 = auction.price(1);
        // An exponential curve satisfies P(t)^2 = P(0) * P(2t). A linear decay does not.
        assertApproxEqRel(p1 * p1, p0 * p2, 1e6);
        assertGe(p2, 50_000 ether);
        assertLt(p1, p0);
        vm.warp(start + 36 hours - 1);
        assertGt(auction.price(1), 50_000 ether);
        vm.warp(start + 36 hours);
        assertEq(auction.price(1), 50_000 ether);
    }

    function test_paginationCapEmptyPagesAndMiddleRemoval() public {
        for (uint256 id = 1; id <= 101; ++id) {
            _mint(ALICE, id);
            _activate(ALICE, id, 1);
        }
        vm.warp(vm.getBlockTimestamp() + 24 hours);
        for (uint256 id = 1; id <= 101; ++id) {
            vm.prank(ALICE);
            dist.exit(id);
        }
        OGAuction.Listing[] memory first = auction.currentAuctions(0, type(uint256).max);
        OGAuction.Listing[] memory second = auction.currentAuctions(100, 100);
        assertEq(first.length, 100);
        assertEq(second.length, 1);
        assertEq(second[0].tokenId, 101);
        assertEq(auction.currentAuctions(0, 0).length, 0);
        assertEq(auction.currentAuctions(type(uint256).max, type(uint256).max).length, 0);
        vm.prank(BOB);
        auction.buy(50, 500_000 ether, BOB, block.timestamp);
        first = auction.currentAuctions(0, 100);
        assertEq(first.length, 100);
        bool[102] memory seen;
        for (uint256 i; i < first.length; ++i) {
            uint256 id = first[i].tokenId;
            assertTrue(id >= 1 && id <= 101 && id != 50);
            assertFalse(seen[id], "duplicate listing after swap-and-pop");
            seen[id] = true;
            assertEq(first[i].price, auction.price(id));
            assertEq(nft.ownerOf(id), address(auction));
        }
        assertTrue(seen[101], "last entry must survive middle removal");
        assertEq(auction.auctionCount(), 100);
        assertEq(auction.lastSalePrice(50), 500_000 ether);
    }
}
