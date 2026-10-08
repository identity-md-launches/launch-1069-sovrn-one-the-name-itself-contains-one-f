// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {OG} from "./OG.sol";
import {OGDistributor} from "./OGDistributor.sol";
import {ISpepe} from "./Interfaces.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";

/// @notice Immutable ETH-only hook. Every fee is based on the actual AMM ETH delta.
contract OGHook {
    uint256 public constant WAD = 1e18;
    uint256 public constant NORMAL_FEE = 0.035e18;
    uint256 public constant DECAY = 60 minutes;
    address public constant TEAM = 0x90738ABe9b04622Dc0b3d015a3964Cc7D1Fd1859;
    address public constant COLLECTION = 0x999ce0CE8C5f7661e0c74a568FfE27CEB9177bDB;
    IPoolManager public immutable poolManager;
    OG public immutable token;
    address public immutable factory;
    OGDistributor public immutable distributor;
    uint256 public openedAt;
    bool public initialized;
    int24 public tickSpacing;
    bool private busy;
    bool private redeeming;
    uint256 private quotedFee;
    int128 private quotedNative;
    uint256 public claimRewards;
    uint256 public claimSurplus;
    uint256 public claimTeam;
    uint256 public teamCredit;
    event PoolOpened(uint256 timestamp);
    event FeeSplit(
        address indexed router,
        bool indexed buy,
        uint256 grossETH,
        uint256 rewards,
        uint256 team,
        uint256 surplus,
        bool asClaim
    );
    event ClaimsRedeemed(uint256 amount);
    event TeamPaid(uint256 amount);
    error Unauthorized();
    error WrongPool();
    error Busy();
    error InvalidAmount();
    error QuoteResult(int128 nativeDelta);
    error QuoteMismatch();

    constructor(IPoolManager manager_, OG token_, address factory_) {
        if (address(manager_).code.length == 0 || address(token_).code.length == 0 || factory_ == address(0)) {
            revert Unauthorized();
        }
        poolManager = manager_;
        token = token_;
        factory = factory_;
        Hooks.validateHookPermissions(IHooks(address(this)), getHookPermissions());
        distributor = new OGDistributor(token_, ISpepe(COLLECTION), manager_, address(this));
    }
    modifier onlyManager() {
        if (msg.sender != address(poolManager)) revert Unauthorized();
        _;
    }
    modifier idle() {
        if (busy) revert Busy();
        busy = true;
        _;
        busy = false;
    }

    function getHookPermissions() public pure returns (Hooks.Permissions memory p) {
        p.beforeInitialize = true;
        p.beforeSwap = true;
        p.afterSwap = true;
        p.beforeSwapReturnDelta = true;
        p.afterSwapReturnDelta = true;
    }

    function poolKey() public view returns (PoolKey memory) {
        return
            PoolKey(
                Currency.wrap(address(0)), Currency.wrap(address(token)), 12_500, tickSpacing, IHooks(address(this))
            );
    }

    function _checkPool(PoolKey calldata key) private view {
        if (
            !initialized || Currency.unwrap(key.currency0) != address(0)
                || Currency.unwrap(key.currency1) != address(token) || key.fee != 12_500
                || key.tickSpacing != tickSpacing || address(key.hooks) != address(this)
        ) revert WrongPool();
    }

    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyManager returns (bytes4) {
        if (
            initialized || sender != factory || Currency.unwrap(key.currency0) != address(0)
                || Currency.unwrap(key.currency1) != address(token) || key.fee != 12_500 || key.tickSpacing <= 0
                || address(key.hooks) != address(this)
        ) revert WrongPool();
        initialized = true;
        tickSpacing = key.tickSpacing;
        openedAt = block.timestamp;
        emit PoolOpened(block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    /// @notice WAD rate; 0.5e18 at opening, 0.035e18 at 60 minutes. Sells always pay NORMAL_FEE.
    function launchFeeNow() public view returns (uint256) {
        if (!initialized) return 0.5e18;
        uint256 elapsed = block.timestamp - openedAt;
        return elapsed >= DECAY ? NORMAL_FEE : NORMAL_FEE + 0.465e18 * (DECAY - elapsed) / DECAY;
    }

    function decayMinutesLeft() external view returns (uint256) {
        if (!initialized) return 60;
        uint256 elapsed = block.timestamp - openedAt;
        return elapsed >= DECAY ? 0 : (DECAY - elapsed + 59) / 60;
    }

    /// @dev ETH specified: quote with a reverting self-call, then return only the actual ETH fee.
    ///      No speculative state survives the quote. This supports price-limit partial fills without
    ///      charging a fee on unused input or unmet output. All other modes need no quote.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        if (busy) revert Busy();
        if (
            params.amountSpecified == 0 || params.amountSpecified > type(int128).max
                || params.amountSpecified < -int256(type(int128).max)
        ) revert InvalidAmount();
        busy = true;
        uint256 fee;
        bool specifiedETH = params.zeroForOne == (params.amountSpecified < 0);
        if (specifiedETH) {
            uint256 rate = params.zeroForOne ? launchFeeNow() : NORMAL_FEE;
            SwapParams memory quoteParams = params;
            uint256 requested = uint256(params.amountSpecified < 0 ? -params.amountSpecified : params.amountSpecified);
            if (params.zeroForOne) {
                fee = requested * rate / WAD;
                quoteParams.amountSpecified = -int256(requested - fee);
            } else {
                uint256 gross = requested * WAD / (WAD - rate);
                if (gross > uint256(uint128(type(int128).max))) revert InvalidAmount();
                quoteParams.amountSpecified = int256(gross);
            }
            int128 nativeDelta = _quote(key, quoteParams);
            uint256 actual = _abs(nativeDelta);
            if (params.zeroForOne) {
                if (actual != uint256(-quoteParams.amountSpecified)) fee = actual * rate / (WAD - rate);
            } else {
                fee = actual * rate / WAD;
            }
            quotedNative = nativeDelta;
            quotedFee = fee;
        }
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(_int128(fee), 0), 0);
    }

    function _quote(PoolKey calldata key, SwapParams memory params) private returns (int128 value) {
        try this.quoteNative(key, params) {
            revert QuoteMismatch();
        } catch (bytes memory reason) {
            if (reason.length != 36 || bytes4(reason) != QuoteResult.selector) {
                assembly ("memory-safe") { revert(add(reason, 32), mload(reason)) }
            }
            assembly ("memory-safe") { value := mload(add(reason, 36)) }
        }
    }

    /// @dev Only this contract can quote. PoolManager skips callbacks for its own hook as sender.
    ///      Always reverts, rolling back the nested swap, its accounting, protocol fees and logs.
    function quoteNative(PoolKey calldata key, SwapParams calldata params) external {
        if (msg.sender != address(this) || !busy) revert Unauthorized();
        BalanceDelta result = poolManager.swap(key, params, "");
        revert QuoteResult(result.amount0());
    }

    function afterSwap(
        address sender,
        PoolKey calldata key,
        SwapParams calldata params,
        BalanceDelta delta,
        bytes calldata
    ) external onlyManager returns (bytes4, int128) {
        _checkPool(key);
        if (!busy) revert Unauthorized();
        bool specifiedETH = params.zeroForOne == (params.amountSpecified < 0);
        uint256 actual = _abs(delta.amount0());
        uint256 rate = params.zeroForOne ? launchFeeNow() : NORMAL_FEE;
        uint256 fee;
        if (specifiedETH) {
            if (delta.amount0() != quotedNative) revert QuoteMismatch();
            fee = quotedFee;
            delete quotedFee;
            delete quotedNative;
        } else {
            fee = params.zeroForOne ? actual * rate / (WAD - rate) : actual * rate / WAD;
        }
        uint256 gross = params.zeroForOne ? actual + fee : actual;
        uint256 team = gross / 100;
        uint256 baseFee = gross * NORMAL_FEE / WAD;
        uint256 normal = baseFee - team;
        uint256 surplus = fee - baseFee;
        bool asClaim = address(poolManager).balance < fee;
        if (fee != 0) {
            if (asClaim) {
                poolManager.mint(address(this), 0, fee);
                claimRewards += normal;
                claimSurplus += surplus;
                claimTeam += team;
                distributor.receiveFeeClaims(normal, surplus);
            } else {
                poolManager.take(key.currency0, address(this), fee);
                _distribute(normal, surplus, team);
            }
        }
        emit FeeSplit(sender, params.zeroForOne, gross, normal, team, surplus, asClaim);
        busy = false;
        return (IHooks.afterSwap.selector, specifiedETH ? int128(0) : _int128(fee));
    }

    function _abs(int128 value) private pure returns (uint256) {
        return uint256(value < 0 ? -int256(value) : int256(value));
    }

    function _int128(uint256 value) private pure returns (int128) {
        if (value > uint256(uint128(type(int128).max))) revert InvalidAmount();
        return int128(int256(value));
    }

    function _distribute(uint256 normal, uint256 surplus, uint256 team) private {
        if (normal + surplus != 0) distributor.receiveFees{value: normal + surplus}(normal, surplus);
        teamCredit += team;
        _payTeam();
    }

    function _payTeam() private {
        uint256 amount = teamCredit;
        if (amount == 0) return;
        teamCredit = 0;
        (bool ok,) = TEAM.call{value: amount}("");
        if (!ok) teamCredit = amount;
        else emit TeamPaid(amount);
    }

    /// @notice Anyone can retry payment; the destination can never change.
    function payTeam() external idle {
        _payTeam();
    }

    /// @notice Redeem fallback ERC-6909 ETH claims after the swap router has settled its input.
    function redeemFees() external idle {
        uint256 normal = claimRewards;
        uint256 surplus = claimSurplus;
        uint256 team = claimTeam;
        if (normal + surplus + team == 0) return;
        claimRewards = 0;
        claimSurplus = 0;
        claimTeam = 0;
        redeeming = true;
        poolManager.unlock(abi.encode(normal, surplus, team));
        redeeming = false;
    }

    function unlockCallback(bytes calldata data) external onlyManager returns (bytes memory) {
        if (!redeeming || !busy) revert Unauthorized();
        (uint256 normal, uint256 surplus, uint256 team) = abi.decode(data, (uint256, uint256, uint256));
        uint256 total = normal + surplus + team;
        poolManager.burn(address(this), 0, total);
        poolManager.take(Currency.wrap(address(0)), address(this), total);
        if (normal + surplus != 0) distributor.fundFeeClaims{value: normal + surplus}();
        teamCredit += team;
        _payTeam();
        emit ClaimsRedeemed(total);
        return "";
    }

    receive() external payable {
        if (msg.sender != address(poolManager)) revert Unauthorized();
    }
}
