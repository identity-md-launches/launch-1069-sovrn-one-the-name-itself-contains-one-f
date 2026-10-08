// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {OG} from "../src/OG.sol";
import {OGHook} from "../src/OGHook.sol";
import {OGDistributor} from "../src/OGDistributor.sol";
import {OGAuction} from "../src/OGAuction.sol";
import {ISpepe} from "../src/Interfaces.sol";
import {MockSpepe} from "./mocks/MockSpepe.sol";
import {PoolRouter} from "./PoolRouter.sol";

abstract contract SystemBase is Test {
    PoolManager internal manager;
    OG internal token;
    OGHook internal hook;
    OGDistributor internal dist;
    OGAuction internal auction;
    MockSpepe internal nft;
    PoolRouter internal router;
    PoolKey internal key;
    address internal constant ALICE = address(0xA11CE);
    address internal constant BOB = address(0xB0B);
    uint160 internal constant START_PRICE = 79228162514264337593543950336000;
    uint160 internal constant LAUNCH_PRICE = 792281625142643375935439503360000;

    function _system(bool seed, bool mockNft) internal {
        _systemAtPrice(seed, mockNft, START_PRICE, 1e22);
    }

    function _systemAtPrice(bool seed, bool mockNft, uint160 initialPrice, int256 liquidity) internal {
        vm.deal(address(this), 10000 ether);
        vm.deal(ALICE, 100 ether);
        vm.deal(BOB, 100 ether);
        manager = new PoolManager(address(this));
        // Counterfactual CREATE addresses can be prefunded on a fork; this fixture needs an empty manager.
        vm.deal(address(manager), 0);
        token = new OG();
        address at = address(uint160(0x20cc));
        deployCodeTo("OGHook.sol:OGHook", abi.encode(IPoolManager(address(manager)), token, address(this)), at);
        hook = OGHook(payable(at));
        dist = hook.distributor();
        auction = dist.auction();
        if (mockNft) {
            MockSpepe template = new MockSpepe();
            // The mock uses separate storage slots, and cloning initializes its metadata.
            vm.cloneAccount(address(template), hook.COLLECTION());
            nft = MockSpepe(hook.COLLECTION());
        }
        key = PoolKey(Currency.wrap(address(0)), Currency.wrap(address(token)), 12500, 60, IHooks(at));
        manager.initialize(key, initialPrice);
        router = new PoolRouter(manager);
        token.approve(address(router), type(uint256).max);
        token.approve(address(dist), type(uint256).max);
        token.approve(address(auction), type(uint256).max);
        token.transfer(ALICE, 10_000_000 ether);
        token.transfer(BOB, 10_000_000 ether);
        vm.startPrank(ALICE);
        token.approve(address(dist), type(uint256).max);
        token.approve(address(router), type(uint256).max);
        token.approve(address(auction), type(uint256).max);
        vm.stopPrank();
        vm.startPrank(BOB);
        token.approve(address(dist), type(uint256).max);
        token.approve(address(auction), type(uint256).max);
        vm.stopPrank();
        if (seed) {
            router.liquidity{value: 100 ether}(key, ModifyLiquidityParams(-887220, 887220, liquidity, bytes32(0)));
        }
    }

    function _mint(address owner, uint256 id) internal {
        nft.mint(owner, id);
        vm.prank(owner);
        nft.setApprovalForAll(address(dist), true);
    }

    function _activate(address owner, uint256 id, uint8 l) internal {
        vm.prank(owner);
        dist.activate(id, l);
    }

    function _fees(uint256 normal, uint256 surplus) internal {
        vm.deal(address(hook), normal + surplus);
        vm.prank(address(hook));
        dist.receiveFees{value: normal + surplus}(normal, surplus);
    }

    function _trade(bool buy, int256 amount, uint160 limit) internal returns (BalanceDelta) {
        return router.trade{value: buy ? 100 ether : 0}(key, SwapParams(buy, amount, limit));
    }

    function _trade(bool buy, int256 amount) internal returns (BalanceDelta) {
        return _trade(buy, amount, buy ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1);
    }
    receive() external payable {}
}
