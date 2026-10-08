// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {OG} from "./OG.sol";
import {OGAuction} from "./OGAuction.sol";
import {ISpepe, IOGPool, Guard} from "./Interfaces.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";

contract OGDistributor is Guard, IUnlockCallback {
    uint256 public constant SCALE = 1e27;
    uint256 public constant STREAM_DURATION = 30 days;
    uint256 public constant EXIT_LOCK = 24 hours;
    OG public immutable token;
    ISpepe public immutable collection;
    IPoolManager public immutable poolManager;
    address public immutable hook;
    OGAuction public immutable auction;
    uint256 public totalWeight;
    uint256 public accPerWeight;
    uint256 public unfundedFees;
    mapping(uint8 => uint256) public activePerLevel;
    mapping(uint256 => uint8) public level;
    mapping(uint256 => uint256) public lastActivation;
    // Scaled debt and credit preserve fractional wei across upgrades, preventing rounding insolvency.
    mapping(uint256 => uint256) public debtScaled;
    mapping(uint256 => uint256) public creditScaled;
    uint256 private backlog;
    uint256 public streamStart;
    uint256 public streamEnd;
    uint256 private streamTotal;
    uint256 private released;
    bool private buying;
    event Activated(uint256 indexed tokenId, address indexed owner, uint8 level, uint256 burned);
    event Upgraded(uint256 indexed tokenId, address indexed owner, uint8 oldLevel, uint8 newLevel, uint256 burned);
    event Exited(uint256 indexed tokenId, address indexed owner, uint256 ethPaid);
    event RewardsReceived(uint256 normal, uint256 surplus);
    event StreamScheduled(uint256 amount, uint256 start, uint256 end);
    error Unauthorized();
    error InvalidLevel();
    error Locked();
    error SlippageOrExpired();

    constructor(OG token_, ISpepe collection_, IPoolManager manager_, address hook_) {
        token = token_;
        collection = collection_;
        poolManager = manager_;
        hook = hook_;
        auction = new OGAuction(token_, collection_, address(this));
    }

    function weight(uint256 id) public view returns (uint256) {
        return levelWeight(level[id]);
    }

    function levelWeight(uint8 l) public pure returns (uint256) {
        return l == 0 ? 0 : uint256(1) << (l - 1);
    }

    function cumulativeCost(uint8 l) public pure returns (uint256) {
        if (l == 1) return 50_000 ether;
        if (l == 2) return 150_000 ether;
        if (l == 3) return 400_000 ether;
        if (l == 0) return 0;
        revert InvalidLevel();
    }

    function activationCost(uint256 id, uint8 newLevel) public view returns (uint256) {
        if (newLevel <= level[id] || newLevel > 3) revert InvalidLevel();
        return cumulativeCost(newLevel) - cumulativeCost(level[id]);
    }

    function _vested() private view returns (uint256) {
        if (totalWeight == 0 || streamEnd == 0) return 0;
        uint256 now_ = block.timestamp < streamEnd ? block.timestamp : streamEnd;
        return streamTotal * (now_ - streamStart) / STREAM_DURATION - released;
    }

    function pending(uint256 id) public view returns (uint256) {
        uint256 a = accPerWeight;
        if (totalWeight != 0) a += _vested() * SCALE / totalWeight;
        return (creditScaled[id] + weight(id) * a - debtScaled[id]) / SCALE;
    }

    function backlogLeft() public view returns (uint256) {
        return backlog - _vested();
    }

    function _checkpoint() private {
        uint256 amount = _vested();
        if (amount != 0) {
            released += amount;
            backlog -= amount;
            accPerWeight += amount * SCALE / totalWeight;
        }
    }

    function checkpoint() external {
        _checkpoint();
    }

    function _schedule() private {
        streamStart = block.timestamp;
        streamTotal = backlog;
        released = 0;
        streamEnd = backlog == 0 || totalWeight == 0 ? 0 : block.timestamp + STREAM_DURATION;
        emit StreamScheduled(backlog, streamStart, streamEnd);
    }

    /// @dev Intentionally callable during activateWithETH: the old weight earns that swap's fees.
    ///      Only the immutable hook can enter; this function performs no external calls.
    function receiveFees(uint256 normal, uint256 surplus) external payable {
        if (msg.sender != hook || msg.value != normal + surplus) revert Unauthorized();
        _accountFees(normal, surplus);
    }

    function receiveFeeClaims(uint256 normal, uint256 surplus) external {
        if (msg.sender != hook) revert Unauthorized();
        unfundedFees += normal + surplus;
        _accountFees(normal, surplus);
    }

    function fundFeeClaims() external payable {
        if (msg.sender != hook || msg.value > unfundedFees) revert Unauthorized();
        unfundedFees -= msg.value;
    }

    function _accountFees(uint256 normal, uint256 surplus) private {
        _checkpoint();
        if (totalWeight == 0) {
            backlog += normal + surplus;
        } else {
            accPerWeight += normal * SCALE / totalWeight;
            if (surplus != 0) {
                backlog += surplus;
                _schedule();
            }
        }
        emit RewardsReceived(normal, surplus);
    }

    function activate(uint256 id, uint8 newLevel) external nonReentrant {
        if (collection.ownerOf(id) != msg.sender) revert Unauthorized();
        uint256 cost = activationCost(id, newLevel);
        require(token.transferFrom(msg.sender, token.DEAD(), cost));
        _activate(id, newLevel, cost);
    }

    function activateWithETH(uint256 id, uint8 newLevel, uint160 sqrtPriceLimitX96, uint256 deadline)
        external
        payable
        nonReentrant
    {
        if (collection.ownerOf(id) != msg.sender) revert Unauthorized();
        if (block.timestamp > deadline) revert SlippageOrExpired();
        uint256 cost = activationCost(id, newLevel);
        buying = true;
        uint256 spent = abi.decode(poolManager.unlock(abi.encode(cost, msg.value, sqrtPriceLimitX96)), (uint256));
        buying = false;
        _activate(id, newLevel, cost);
        _sendETH(msg.sender, msg.value - spent);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager) || !buying) revert Unauthorized();
        (uint256 cost, uint256 budget, uint160 limit) = abi.decode(data, (uint256, uint256, uint160));
        PoolKey memory key = IOGPool(hook).poolKey();
        BalanceDelta delta = poolManager.swap(key, SwapParams(true, int256(cost), limit), "");
        uint256 spent = uint256(-int256(delta.amount0()));
        if (delta.amount1() != int256(cost) || spent > budget) revert SlippageOrExpired();
        poolManager.sync(key.currency0);
        poolManager.settle{value: spent}();
        poolManager.take(key.currency1, token.DEAD(), cost);
        return abi.encode(spent);
    }

    function _activate(uint256 id, uint8 newLevel, uint256 cost) private {
        _checkpoint();
        uint8 old = level[id];
        uint256 oldWeight = levelWeight(old);
        creditScaled[id] += oldWeight * accPerWeight - debtScaled[id];
        bool wasEmpty = totalWeight == 0;
        totalWeight = totalWeight - oldWeight + levelWeight(newLevel);
        if (old != 0) --activePerLevel[old];
        ++activePerLevel[newLevel];
        level[id] = newLevel;
        debtScaled[id] = levelWeight(newLevel) * accPerWeight;
        lastActivation[id] = block.timestamp;
        if (wasEmpty) _schedule();
        if (old == 0) emit Activated(id, msg.sender, newLevel, cost);
        else emit Upgraded(id, msg.sender, old, newLevel, cost);
    }

    function exit(uint256 id) external nonReentrant {
        if (collection.ownerOf(id) != msg.sender || level[id] == 0) revert Unauthorized();
        if (block.timestamp < lastActivation[id] + EXIT_LOCK) revert Locked();
        if (unfundedFees != 0) IOGPool(hook).redeemFees();
        _checkpoint();
        uint256 amount = pending(id);
        uint8 old = level[id];
        totalWeight -= levelWeight(old);
        --activePerLevel[old];
        delete level[id];
        delete debtScaled[id];
        delete creditScaled[id];
        delete lastActivation[id];
        if (totalWeight == 0) _schedule();
        auction.list(id);
        collection.safeTransferFrom(msg.sender, address(auction), id);
        _sendETH(msg.sender, amount);
        emit Exited(id, msg.sender, amount);
    }

    function totalBurned() external view returns (uint256) {
        return token.totalBurned();
    }
}
