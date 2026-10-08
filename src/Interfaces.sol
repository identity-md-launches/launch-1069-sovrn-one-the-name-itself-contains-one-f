// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {PoolKey} from "v4-core/src/types/PoolKey.sol";

interface ISpepe {
    function ownerOf(uint256 id) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 id) external;
    function transferFrom(address from, address to, uint256 id) external;
    function totalMinted() external view returns (uint256);
}

interface IOGPool {
    function poolKey() external view returns (PoolKey memory);
    function redeemFees() external;
}

abstract contract Guard {
    uint256 private entered;
    error Reentrancy();
    modifier nonReentrant() {
        if (entered != 0) revert Reentrancy();
        entered = 1;
        _;
        entered = 0;
    }
    error ETHSendFailed();

    function _sendETH(address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert ETHSendFailed();
    }
}
