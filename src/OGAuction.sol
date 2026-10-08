// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {OG} from "./OG.sol";
import {ISpepe, Guard} from "./Interfaces.sol";
import {wadExp, wadLn} from "solmate/src/utils/SignedWadMath.sol";

/// @notice Permissionless, perpetual Dutch sales of exited NFTs. No withdrawals or administrative roles.
contract OGAuction is Guard {
    OG public immutable token;
    ISpepe public immutable collection;
    address public immutable distributor;
    uint256 public constant FLOOR = 50_000 ether;
    uint256 public constant MIN_START = 500_000 ether;
    uint256 public constant DURATION = 36 hours;

    struct Auction {
        uint256 startPrice;
        uint256 startedAt;
        bool listed;
    }

    struct Listing {
        uint256 tokenId;
        uint256 startPrice;
        uint256 startedAt;
        uint256 price;
    }
    mapping(uint256 => Auction) public auctions;
    mapping(uint256 => uint256) public lastSalePrice;
    uint256[] private ids;
    mapping(uint256 => uint256) private index;
    event AuctionListed(uint256 indexed tokenId, uint256 startPrice, uint256 startedAt);
    event AuctionSold(uint256 indexed tokenId, address indexed buyer, address indexed recipient, uint256 burned);
    error Unauthorized();
    error InvalidAuction();
    error SlippageOrExpired();

    constructor(OG token_, ISpepe collection_, address distributor_) {
        token = token_;
        collection = collection_;
        distributor = distributor_;
    }

    function list(uint256 id) external {
        if (msg.sender != distributor) revert Unauthorized();
        if (auctions[id].listed) revert InvalidAuction();
        uint256 start = lastSalePrice[id] * 10;
        if (start < MIN_START) start = MIN_START;
        auctions[id] = Auction(start, block.timestamp, true);
        index[id] = ids.length;
        ids.push(id);
        emit AuctionListed(id, start, block.timestamp);
    }

    /// @dev P(t) = start * exp(ln(floor/start) * t / 36h), clamped at the floor.
    function price(uint256 id) public view returns (uint256) {
        Auction memory a = auctions[id];
        if (!a.listed) return 0;
        uint256 elapsed = block.timestamp - a.startedAt;
        if (elapsed >= DURATION) return FLOOR;
        if (elapsed == 0) return a.startPrice;
        int256 logarithm = wadLn(int256(FLOOR * 1e18 / a.startPrice));
        uint256 result = a.startPrice * uint256(wadExp(logarithm * int256(elapsed) / int256(DURATION))) / 1e18;
        return result < FLOOR ? FLOOR : result;
    }

    function buy(uint256 id, uint256 maxPrice, address recipient, uint256 deadline) external nonReentrant {
        if (!auctions[id].listed || recipient == address(0) || recipient == address(this)) revert InvalidAuction();
        uint256 cost = price(id);
        if (block.timestamp > deadline || cost > maxPrice) revert SlippageOrExpired();
        delete auctions[id];
        lastSalePrice[id] = cost;
        uint256 i = index[id];
        uint256 last = ids[ids.length - 1];
        ids[i] = last;
        index[last] = i;
        ids.pop();
        delete index[id];
        require(token.transferFrom(msg.sender, token.DEAD(), cost));
        collection.safeTransferFrom(address(this), recipient, id);
        emit AuctionSold(id, msg.sender, recipient, cost);
    }

    function auctionCount() external view returns (uint256) {
        return ids.length;
    }

    /// @notice Pages use swap-and-pop ordering; pin a block when traversing multiple pages.
    function currentAuctions(uint256 offset, uint256 limit) external view returns (Listing[] memory result) {
        if (limit > 100) limit = 100;
        uint256 count = offset >= ids.length ? 0 : ids.length - offset;
        if (count > limit) count = limit;
        result = new Listing[](count);
        for (uint256 j; j < count; ++j) {
            uint256 id = ids[offset + j];
            Auction memory a = auctions[id];
            result[j] = Listing(id, a.startPrice, a.startedAt, price(id));
        }
    }

    function onERC721Received(address operator, address, uint256 id, bytes calldata) external view returns (bytes4) {
        if (msg.sender != address(collection) || operator != distributor || !auctions[id].listed) {
            revert Unauthorized();
        }
        return this.onERC721Received.selector;
    }
}
