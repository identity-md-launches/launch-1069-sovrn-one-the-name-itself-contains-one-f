// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC20} from "solmate/src/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    constructor(string memory n, string memory s, uint256 supply) ERC20(n, s, 18) {
        _mint(msg.sender, supply);
    }
}
