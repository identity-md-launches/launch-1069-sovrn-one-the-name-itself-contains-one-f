// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {Test} from "forge-std/Test.sol";
import {OG} from "../src/OG.sol";

contract TokenTest is Test {
    function test_supplyPlainTransferAllowanceAndBurn() public {
        OG t = new OG();
        assertEq(t.name(), "OG");
        assertEq(t.symbol(), "OG");
        assertEq(t.decimals(), 18);
        assertEq(t.totalSupply(), 1e27);
        assertEq(t.balanceOf(address(this)), 1e27);
        t.transfer(address(123), 1 ether);
        assertEq(t.balanceOf(address(123)), 1 ether);
        assertEq(t.totalSupply(), 1e27);
        address dead = t.DEAD();
        t.approve(address(123), 2 ether);
        vm.prank(address(123));
        t.transferFrom(address(this), dead, 2 ether);
        assertEq(t.totalBurned(), 2 ether);
        assertEq(t.balanceOf(t.DEAD()), 2 ether);
        assertEq(t.allowance(address(this), address(123)), 0);
        vm.prank(address(123));
        vm.expectRevert();
        t.transferFrom(address(this), address(123), 1);
        vm.expectRevert(OG.ZeroAddress.selector);
        t.transfer(address(0), 1);
        (bool minted,) = address(t).call(abi.encodeWithSignature("mint(address,uint256)", address(this), 1 ether));
        assertFalse(minted);
    }

    function testFuzz_plainTransfers(uint256 amount) public {
        OG t = new OG();
        amount = bound(amount, 0, t.totalSupply());
        t.transfer(address(42), amount);
        assertEq(t.balanceOf(address(42)), amount);
        assertEq(t.balanceOf(address(this)), t.totalSupply() - amount);
    }
}
