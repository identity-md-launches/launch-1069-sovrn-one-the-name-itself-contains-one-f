// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {SystemBase} from "./SystemBase.sol";
import {MockSpepe} from "./mocks/MockSpepe.sol";
import {PoolRouter} from "./PoolRouter.sol";
import {OG} from "src/OG.sol";
import {OGHook} from "src/OGHook.sol";
import {OGDistributor} from "src/OGDistributor.sol";
import {OGAuction} from "src/OGAuction.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract InvariantRejectETH {
    receive() external payable {
        revert("reject");
    }
}

contract LifecycleHandler is Test {
    OGHook public immutable h;
    OGDistributor public immutable d;
    OGAuction public immutable a;
    OG public immutable t;
    MockSpepe public immutable n;
    PoolRouter public immutable r;
    address private immutable rejectingCode;
    address[3] public actors;
    uint256 public allocated;
    uint256 public teamFees;
    uint256 public paid;
    uint256 public burned;
    uint256 public swaps;
    uint256 public activations;
    uint256 public exits;
    uint256 public sales;
    uint256 public transfers;
    uint256 public donations;
    bytes32 private constant FEE_EVENT = keccak256("FeeSplit(address,bool,uint256,uint256,uint256,uint256,bool)");

    constructor(OGHook hook_, MockSpepe nft_, PoolRouter router_) {
        h = hook_;
        d = h.distributor();
        a = d.auction();
        t = h.token();
        n = nft_;
        r = router_;
        rejectingCode = address(new InvariantRejectETH());
        for (uint256 i; i < 3; ++i) {
            actors[i] = makeAddr(string.concat("lifecycle actor ", vm.toString(i)));
            vm.deal(actors[i], 100 ether);
            vm.startPrank(actors[i]);
            t.approve(address(d), type(uint256).max);
            t.approve(address(a), type(uint256).max);
            t.approve(address(r), type(uint256).max);
            n.setApprovalForAll(address(d), true);
            vm.stopPrank();
        }
    }

    modifier observe() {
        uint256 oldAcc = d.accPerWeight();
        vm.recordLogs();
        _;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(h) || logs[i].topics[0] != FEE_EVENT) continue;
            (, uint256 normal, uint256 team, uint256 surplus,) =
                abi.decode(logs[i].data, (uint256, uint256, uint256, uint256, bool));
            allocated += normal + surplus;
            teamFees += team;
            ++swaps;
        }
        assertGe(d.accPerWeight(), oldAcc, "accumulator cannot decrease");
    }

    function activate(uint256 rawId, uint8 rawLevel, bool withETH) public observe {
        uint256 id = rawId % 9 + 1;
        address owner = n.ownerOf(id);
        uint8 old = d.level(id);
        if (owner == address(a) || old == 3) return;
        uint8 next = uint8(bound(rawLevel, old + 1, 3));
        uint256 cost = d.activationCost(id, next);
        if (cost > t.balanceOf(owner)) return;
        uint256 oldPending = d.pending(id);
        vm.prank(owner);
        if (withETH) d.activateWithETH{value: 1 ether}(id, next, TickMath.MIN_SQRT_PRICE + 1, block.timestamp);
        else d.activate(id, next);
        burned += cost;
        ++activations;
        assertGe(d.pending(id), oldPending, "upgrade loses previously earned ETH");
        if (old == 0) assertEq(d.pending(id), 0, "activation cannot earn its own swap's fee");
    }

    function swap(uint96 raw, bool buy, bool exactInput, uint8 actorSeed) public observe {
        address actor = actors[actorSeed % 3];
        uint256 nativeAmount = bound(raw, 1, 0.0001 ether);
        int256 amount = int256(buy == exactInput ? nativeAmount : nativeAmount * 100_000_000);
        if (exactInput) amount = -amount;
        PoolKey memory pool = h.poolKey();
        vm.prank(actor);
        r.trade{value: buy ? 1 ether : 0}(
            pool, SwapParams(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1)
        );
    }

    function advance(uint32 seconds_) public observe {
        vm.warp(block.timestamp + bound(seconds_, 0, 35 days));
        d.checkpoint();
        uint256 acc = d.accPerWeight();
        uint256 backlog = d.backlogLeft();
        d.checkpoint();
        assertEq(d.accPerWeight(), acc, "checkpoint idempotence");
        assertEq(d.backlogLeft(), backlog);
    }

    function transferNFT(uint256 rawId, uint8 toSeed) public observe {
        uint256 id = rawId % 9 + 1;
        address owner = n.ownerOf(id);
        if (owner == address(a)) return;
        uint256 pending = d.pending(id);
        uint8 level = d.level(id);
        uint256 lock = d.lastActivation(id);
        vm.prank(owner);
        n.transferFrom(owner, actors[toSeed % 3], id);
        assertEq(d.pending(id), pending);
        assertEq(d.level(id), level);
        assertEq(d.lastActivation(id), lock);
        ++transfers;
    }

    function exit(uint256 rawId) public observe {
        uint256 id = rawId % 9 + 1;
        if (d.level(id) == 0 || block.timestamp < d.lastActivation(id) + 24 hours) return;
        address owner = n.ownerOf(id);
        uint256 before = owner.balance;
        uint256 expected = d.pending(id);
        vm.prank(owner);
        d.exit(id);
        assertEq(owner.balance - before, expected, "exit pays the entire preview");
        paid += owner.balance - before;
        ++exits;
    }

    function buy(uint256 rawId, uint8 payerSeed, uint8 recipientSeed) public observe {
        uint256 id = rawId % 9 + 1;
        uint256 cost = a.price(id);
        address payer = actors[payerSeed % 3];
        address recipient = actors[recipientSeed % 3];
        if (cost == 0 || cost > t.balanceOf(payer)) return;
        vm.prank(payer);
        a.buy(id, cost, recipient, block.timestamp);
        burned += cost;
        ++sales;
        assertEq(n.ownerOf(id), recipient);
        assertEq(d.level(id), 0);
        assertEq(d.pending(id), 0);
        assertEq(a.lastSalePrice(id), cost);
    }

    function redeem() public observe {
        h.redeemFees();
    }

    function teamReceiver(bool reject) public observe {
        vm.etch(h.TEAM(), reject ? rejectingCode.code : bytes(""));
        h.payTeam();
    }

    function moveOG(uint96 raw, uint8 fromSeed, uint8 toSeed, bool burn) public observe {
        address from = actors[fromSeed % 3];
        uint256 amount = bound(raw, 0, t.balanceOf(from) / 100);
        address to = burn ? t.DEAD() : actors[toSeed % 3];
        vm.prank(from);
        t.transfer(to, amount);
        if (burn) burned += amount;
    }

    function donate(uint96 raw) public observe {
        uint256 amount = bound(raw, 0, 1 ether);
        // Equivalent to forced ETH: it must not become claimable or affect reward weights.
        vm.deal(address(d), address(d).balance + amount);
        donations += amount;
    }
}

/// @notice Covers all three value holders with real swaps, claims, transfers and auction cycles.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 96
/// forge-config: default.invariant.fail-on-revert = true
contract LifecycleInvariantTest is SystemBase {
    LifecycleHandler private handler;
    uint256 private initialTeam;

    function setUp() public {
        _systemAtPrice(false, true, LAUNCH_PRICE, 0);
        router.liquidity(key, ModifyLiquidityParams(166200, 184200, 1e21, bytes32(0)));
        initialTeam = hook.TEAM().balance;
        handler = new LifecycleHandler(hook, nft, router);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actors(i), 200_000_000 ether);
        }
        for (uint256 id = 1; id <= 9; ++id) {
            nft.mint(handler.actors((id - 1) % 3), id);
        }
        handler.activate(0, 1, false);
        handler.activate(1, 2, false);
        handler.activate(2, 3, false);
        // Every campaign begins with real deferred fees; claims invariants cannot pass vacuously.
        handler.swap(0.0001 ether, true, true, 0);
        assertGt(hook.claimRewards(), 0);
        // Deep liquidity keeps every bounded random action executable after the claim-producing launch.
        router.liquidity{value: 10 ether}(key, ModifyLiquidityParams(-887220, 887220, 1e22, bytes32(0)));
        bytes4[] memory selectors = new bytes4[](10);
        selectors[0] = handler.activate.selector;
        selectors[1] = handler.swap.selector;
        selectors[2] = handler.advance.selector;
        selectors[3] = handler.transferNFT.selector;
        selectors[4] = handler.exit.selector;
        selectors[5] = handler.buy.selector;
        selectors[6] = handler.redeem.selector;
        selectors[7] = handler.teamReceiver.selector;
        selectors[8] = handler.moveOG.selector;
        selectors[9] = handler.donate.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector(address(handler), selectors));
        targetSender(address(handler));
    }

    function invariant_valueConservationAndClaimBacking() public view {
        uint256 liabilities = dist.backlogLeft();
        for (uint256 id = 1; id <= 9; ++id) {
            liabilities += dist.pending(id);
        }
        assertLe(liabilities, address(dist).balance + dist.unfundedFees());
        assertEq(
            address(dist).balance + dist.unfundedFees() + handler.paid(), handler.allocated() + handler.donations()
        );
        assertEq(dist.unfundedFees(), hook.claimRewards() + hook.claimSurplus());
        assertEq(manager.balanceOf(address(hook), 0), dist.unfundedFees() + hook.claimTeam());
        assertEq(address(hook).balance, hook.teamCredit());
        assertEq(hook.TEAM().balance - initialTeam + hook.teamCredit() + hook.claimTeam(), handler.teamFees());
        assertEq(address(auction).balance, 0);
        assertEq(address(router).balance, 0);
    }

    function invariant_weightCountsAndAuctionCustody() public view {
        uint256 weight;
        uint256[4] memory levels;
        uint256 listed;
        OGAuction.Listing[] memory page = auction.currentAuctions(0, 100);
        for (uint256 id = 1; id <= 9; ++id) {
            uint8 l = dist.level(id);
            ++levels[l];
            weight += l == 0 ? 0 : l == 1 ? 1 : l == 2 ? 2 : 4;
            if (auction.price(id) != 0) {
                ++listed;
                assertEq(nft.ownerOf(id), address(auction));
                assertEq(l, 0);
                assertEq(dist.pending(id), 0);
                assertGe(auction.price(id), 50_000 ether);
                uint256 occurrences;
                for (uint256 j; j < page.length; ++j) {
                    if (page[j].tokenId == id) ++occurrences;
                }
                assertEq(occurrences, 1, "pagination lost or duplicated a listing");
            }
        }
        assertEq(dist.totalWeight(), weight);
        for (uint8 l = 1; l <= 3; ++l) {
            assertEq(dist.activePerLevel(l), levels[l]);
        }
        assertEq(auction.auctionCount(), listed);
        assertEq(page.length, listed);
    }

    function invariant_OGSupplyAndEveryBurnConserved() public view {
        uint256 balances = token.balanceOf(address(this)) + token.balanceOf(ALICE) + token.balanceOf(BOB)
            + token.balanceOf(address(manager)) + token.balanceOf(token.DEAD());
        for (uint256 i; i < 3; ++i) {
            balances += token.balanceOf(handler.actors(i));
        }
        assertEq(balances, 1_000_000_000 ether);
        assertEq(token.totalSupply(), 1_000_000_000 ether);
        assertEq(token.totalBurned(), handler.burned());
        assertEq(token.balanceOf(token.DEAD()), handler.burned());
        assertEq(token.balanceOf(address(dist)), 0);
        assertEq(token.balanceOf(address(auction)), 0);
        assertEq(token.balanceOf(address(hook)), 0);
    }

    function afterInvariant() public {
        // Liveness: all remaining active owners can actually collect after the lock, not just preview.
        handler.advance(31 days);
        handler.redeem();
        for (uint256 id; id < 9; ++id) {
            handler.exit(id);
        }
        assertEq(dist.totalWeight(), 0);
        invariant_valueConservationAndClaimBacking();
        invariant_weightCountsAndAuctionCustody();
        invariant_OGSupplyAndEveryBurnConserved();
    }

    function test_handlerReachesTransferExitSaleAndReactivation() public {
        handler.transferNFT(0, 1);
        handler.advance(2 days);
        handler.exit(0);
        handler.buy(0, 2, 0);
        handler.activate(0, 2, true);
        handler.teamReceiver(true);
        handler.swap(1e12, true, false, 2);
        handler.redeem();
        assertGt(hook.teamCredit(), 0);
        handler.teamReceiver(false);
        assertEq(hook.teamCredit(), 0);
        assertEq(handler.transfers(), 1);
        assertEq(handler.exits(), 1);
        assertEq(handler.sales(), 1);
        afterInvariant();
    }
}
