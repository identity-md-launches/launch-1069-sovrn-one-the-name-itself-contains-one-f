// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ERC721} from "solmate/src/tokens/ERC721.sol";

// Test-only storage namespace: avoid aliasing SPEPE's live mapping slots when this
// fixture is placed at its fixed address on a fork. cloneAccount cannot erase
// storage that the fork provider has not lazily loaded yet.
abstract contract MockStorageNamespace {
    uint256[100] private reserved;
}

contract MockSpepe is MockStorageNamespace, ERC721 {
    uint256 public totalMinted;
    constructor() ERC721("Swarm Pepe", "SPEPE") {}

    function mint(address to, uint256 id) external {
        ++totalMinted;
        _mint(to, id);
    }

    function tokenURI(uint256) public pure override returns (string memory) {
        return "";
    }
}
