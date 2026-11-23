// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SotechyOrderReceipts} from "../src/SotechyOrderReceipts.sol";

contract SotechyOrderReceiptsTest is Test {
    SotechyOrderReceipts internal receipts;
    address internal owner = makeAddr("owner");
    address internal issuer = makeAddr("escrow");
    address internal buyer = makeAddr("buyer");

    function setUp() public {
        receipts = new SotechyOrderReceipts(owner);
        vm.prank(owner);
        receipts.setIssuer(issuer, true);
    }

    function test_IssuedToTheBuyerWithTheOrderAsItsId() public {
        vm.prank(issuer);
        receipts.issue(1024, buyer, 7);
        assertEq(receipts.ownerOf(1024), buyer);
        assertEq(receipts.balanceOf(buyer), 1);
        assertEq(receipts.totalSupply(), 1);
        SotechyOrderReceipts.Receipt memory r = receipts.receipt(1024);
        assertEq(r.storeId, 7);
        assertEq(uint8(r.status), uint8(SotechyOrderReceipts.Status.Held));
    }

    function test_OnlyTheEscrowIssuesAndMovesReceipts() public {
        vm.expectRevert(SotechyOrderReceipts.NotIssuer.selector);
        receipts.issue(1, buyer, 7);
        vm.prank(issuer);
        receipts.issue(1, buyer, 7);
        vm.expectRevert(SotechyOrderReceipts.NotIssuer.selector);
        receipts.setStatus(1, SotechyOrderReceipts.Status.Delivered);
    }

    function test_OneReceiptPerOrder() public {
        vm.startPrank(issuer);
        receipts.issue(1, buyer, 7);
        vm.expectRevert(abi.encodeWithSelector(SotechyOrderReceipts.ReceiptExists.selector, 1));
        receipts.issue(1, buyer, 7);
        vm.stopPrank();
    }

    function test_ItCantBeTransferredOrApproved() public {
        vm.prank(issuer);
        receipts.issue(1, buyer, 7);
        vm.startPrank(buyer);
        vm.expectRevert(SotechyOrderReceipts.Soulbound.selector);
        receipts.transferFrom(buyer, address(this), 1);
        vm.expectRevert(SotechyOrderReceipts.Soulbound.selector);
        receipts.safeTransferFrom(buyer, address(this), 1);
        vm.expectRevert(SotechyOrderReceipts.Soulbound.selector);
        receipts.approve(address(this), 1);
        vm.expectRevert(SotechyOrderReceipts.Soulbound.selector);
        receipts.setApprovalForAll(address(this), true);
        vm.stopPrank();
    }

    function test_ThePictureChangesWithTheStatus() public {
        vm.startPrank(issuer);
        receipts.issue(1, buyer, 7);
        string memory held = receipts.tokenURI(1);
        vm.expectEmit(address(receipts));
        emit SotechyOrderReceipts.MetadataUpdate(1);
        receipts.setStatus(1, SotechyOrderReceipts.Status.Delivered);
        vm.stopPrank();
        string memory delivered = receipts.tokenURI(1);
        assertTrue(keccak256(bytes(held)) != keccak256(bytes(delivered)));
        assertEq(_prefix(delivered, 29), "data:application/json;base64,");
    }

    function test_UnknownReceiptsRevert() public {
        vm.expectRevert(abi.encodeWithSelector(SotechyOrderReceipts.UnknownReceipt.selector, 9));
        receipts.ownerOf(9);
        vm.expectRevert(abi.encodeWithSelector(SotechyOrderReceipts.UnknownReceipt.selector, 9));
        receipts.tokenURI(9);
    }

    function test_ItSaysWhichStandardsItSpeaks() public view {
        assertTrue(receipts.supportsInterface(0x80ac58cd)); // ERC-721
        assertTrue(receipts.supportsInterface(0x5b5e139f)); // ERC-721 metadata
        assertTrue(receipts.supportsInterface(0x49064906)); // ERC-4906
        assertFalse(receipts.supportsInterface(0xd9b67a26));
    }

    function test_OwnershipMovesInTwoSteps() public {
        address next = makeAddr("next owner");
        vm.prank(owner);
        receipts.transferOwnership(next);
        assertEq(receipts.owner(), owner);
        vm.prank(next);
        receipts.acceptOwnership();
        assertEq(receipts.owner(), next);
    }

    function _prefix(string memory s, uint256 n) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        bytes memory out = new bytes(n);
        for (uint256 i = 0; i < n; i++) out[i] = b[i];
        return string(out);
    }
}
