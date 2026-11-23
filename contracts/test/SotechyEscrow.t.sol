// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Base} from "./Base.t.sol";
import {SotechyEscrow} from "../src/SotechyEscrow.sol";
import {SotechyOrderReceipts} from "../src/SotechyOrderReceipts.sol";

contract SotechyEscrowTest is Base {
    uint256 internal constant ORDER = 1024;

    // ------------------------------------------------------------------
    // Paying
    // ------------------------------------------------------------------

    function test_PayHoldsTheMoneyAndMintsTheReceipt() public {
        openAndPay(ORDER, 50 * USDT, 500);
        assertEq(usdt.balanceOf(address(escrow)), 50 * USDT);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Paid));
        assertEq(escrow.order(ORDER).buyer, buyer);
        assertEq(receipts.ownerOf(ORDER), buyer);
        assertEq(uint8(status(ORDER)), uint8(SotechyOrderReceipts.Status.Held));
    }

    function test_PayAfterThePaymentWindowFails() public {
        vm.prank(operator);
        escrow.open(ORDER, store, STORE_ID, 50 * USDT, uint40(block.timestamp + 1 hours), uint40(block.timestamp + 3 days), STORE_TOKEN, 0);
        vm.warp(block.timestamp + 2 hours);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SotechyEscrow.PaymentWindowClosed.selector, ORDER));
        escrow.pay(ORDER);
    }

    function test_AnOrderIsPaidOnce() public {
        openAndPay(ORDER, 50 * USDT, 0);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(SotechyEscrow.WrongStage.selector, ORDER, SotechyEscrow.Stage.Paid));
        escrow.pay(ORDER);
    }

    function test_OnlySotechyOpensOrders() public {
        vm.prank(stranger);
        vm.expectRevert(SotechyEscrow.NotOperator.selector);
        escrow.open(ORDER, stranger, STORE_ID, 50 * USDT, uint40(block.timestamp + 1 hours), uint40(block.timestamp + 3 days), 0, 0);
    }

    function test_UnpaidTermsCanBeWithdrawn() public {
        vm.startPrank(operator);
        escrow.open(ORDER, store, STORE_ID, 50 * USDT, uint40(block.timestamp + 1 hours), uint40(block.timestamp + 3 days), 0, 0);
        escrow.withdraw(ORDER);
        vm.stopPrank();
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.None));
    }

    // ------------------------------------------------------------------
    // Release
    // ------------------------------------------------------------------

    function test_DeliveredReleasesToTheStoreAndMintsTokens() public {
        openAndPay(ORDER, 50 * USDT, 500);
        vm.prank(store);
        escrow.markShipped(ORDER);
        assertEq(uint8(status(ORDER)), uint8(SotechyOrderReceipts.Status.Shipped));

        vm.prank(buyer);
        escrow.confirmDelivered(ORDER);

        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Released));
        assertEq(usdt.balanceOf(store), 47_500_000, "95% to the store");
        assertEq(usdt.balanceOf(treasury), 2_500_000, "5% fee");
        assertEq(usdt.balanceOf(address(escrow)), 0);
        assertEq(tokens.balanceOf(buyer, STORE_TOKEN), 500, "tokens earned on release");
        assertEq(uint8(status(ORDER)), uint8(SotechyOrderReceipts.Status.Delivered));
    }

    function test_NoComplaintInTimeAnyoneCanRelease() public {
        openAndPay(ORDER, 50 * USDT, 0);
        vm.prank(store);
        escrow.markShipped(ORDER);

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SotechyEscrow.NothingToDo.selector, ORDER));
        escrow.settle(ORDER);

        vm.warp(block.timestamp + 3 days);
        vm.prank(stranger);
        escrow.settle(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Released));
    }

    function test_SotechyRelaysDeliveryFromTheApp() public {
        openAndPay(ORDER, 50 * USDT, 0);
        vm.prank(operator);
        escrow.confirmDelivered(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Released));
    }

    // ------------------------------------------------------------------
    // Refund
    // ------------------------------------------------------------------

    function test_NotShippedInTimeRefundsTheBuyer() public {
        openAndPay(ORDER, 50 * USDT, 500);
        uint256 before = usdt.balanceOf(buyer);
        vm.warp(block.timestamp + 3 days + 1);
        vm.prank(stranger);
        escrow.settle(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Refunded));
        assertEq(usdt.balanceOf(buyer), before + 50 * USDT);
        assertEq(tokens.balanceOf(buyer, STORE_TOKEN), 0, "no tokens for a refunded order");
        assertEq(uint8(status(ORDER)), uint8(SotechyOrderReceipts.Status.Refunded));
    }

    function test_StoreCancelsAndTheBuyerIsRefunded() public {
        openAndPay(ORDER, 50 * USDT, 0);
        vm.prank(store);
        escrow.cancel(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Refunded));
        assertEq(usdt.balanceOf(buyer), 10_000 * USDT);
    }

    // ------------------------------------------------------------------
    // Disputes and the Store Breaker
    // ------------------------------------------------------------------

    function test_ADisputeHoldsTheMoneyAndTripsTheBreaker() public {
        openAndPay(ORDER, 50 * USDT, 0);
        vm.prank(buyer);
        escrow.openDispute(ORDER);
        assertTrue(escrow.breakerTripped(STORE_ID));
        assertEq(uint8(status(ORDER)), uint8(SotechyOrderReceipts.Status.OnHold));

        // Even delivered and past every window, nothing moves while the dispute is open
        vm.prank(operator);
        escrow.confirmDelivered(ORDER);
        vm.warp(block.timestamp + 10 days);
        vm.expectRevert(abi.encodeWithSelector(SotechyEscrow.NothingToDo.selector, ORDER));
        escrow.settle(ORDER);
    }

    function test_BuyerWinsTheDisputeAndIsRefunded() public {
        openAndPay(ORDER, 50 * USDT, 0);
        vm.prank(buyer);
        escrow.openDispute(ORDER);
        vm.prank(operator);
        escrow.resolveDispute(ORDER, true);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Refunded));
    }

    function test_StoreWinsButItsBreakerHoldsReleasesUntilCleared() public {
        openAndPay(ORDER, 50 * USDT, 0);
        vm.prank(store);
        escrow.markShipped(ORDER);
        vm.prank(buyer);
        escrow.openDispute(ORDER);
        vm.prank(operator);
        escrow.resolveDispute(ORDER, false);
        vm.warp(block.timestamp + 3 days);

        (bool release,, bool limitOk, bool breakerOk) = escrow.verdictOf(ORDER);
        assertFalse(release);
        assertTrue(limitOk);
        assertFalse(breakerOk, "the store's breaker is still tripped");

        vm.prank(operator);
        escrow.clearBreaker(STORE_ID);
        assertFalse(escrow.breakerTripped(STORE_ID));
        escrow.settle(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Released));
    }

    function test_TheBreakerPausesTheStoresOtherOrders() public {
        openAndPay(1, 20 * USDT, 0);
        openAndPay(2, 30 * USDT, 0);
        vm.prank(buyer);
        escrow.openDispute(1);

        vm.prank(buyer);
        escrow.confirmDelivered(2);
        assertEq(uint8(stage(2)), uint8(SotechyEscrow.Stage.Paid), "held while the store's breaker is tripped");

        vm.prank(operator);
        escrow.clearBreaker(STORE_ID);
        escrow.settle(2);
        assertEq(uint8(stage(2)), uint8(SotechyEscrow.Stage.Released));
    }

    function test_RefundsDontWaitForTheBreaker() public {
        openAndPay(1, 20 * USDT, 0);
        openAndPay(2, 30 * USDT, 0);
        vm.prank(buyer);
        escrow.openDispute(1);
        vm.prank(store);
        escrow.cancel(2);
        assertEq(uint8(stage(2)), uint8(SotechyEscrow.Stage.Refunded));
    }

    // ------------------------------------------------------------------
    // The New-Store Limit
    // ------------------------------------------------------------------

    function test_ANewStoresBigOrderWaitsForAReview() public {
        openAndPay(ORDER, 150 * USDT, 0); // above the store's $100 limit
        vm.prank(buyer);
        escrow.confirmDelivered(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Paid));
        (,, bool limitOk,) = escrow.verdictOf(ORDER);
        assertFalse(limitOk);

        vm.prank(operator);
        escrow.approveReview(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Released));
    }

    function test_AnOrderAtTheLimitIsReleased() public {
        openAndPay(ORDER, 100 * USDT, 0);
        vm.prank(buyer);
        escrow.confirmDelivered(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Released));
    }

    function test_AnEstablishedStoreHasNoLimit() public {
        vm.prank(operator);
        escrow.setStore(STORE_ID, true, true, 0);
        openAndPay(ORDER, 2_000 * USDT, 0);
        vm.prank(buyer);
        escrow.confirmDelivered(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Released));
    }

    function test_AnUnverifiedStoreIsntPaid() public {
        vm.prank(operator);
        escrow.setStore(STORE_ID, false, true, 0);
        openAndPay(ORDER, 50 * USDT, 0);
        vm.prank(buyer);
        escrow.confirmDelivered(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Paid));
    }

    // ------------------------------------------------------------------
    // Trust in the processor
    // ------------------------------------------------------------------

    function test_ATapeOutUpgradeStopsDecisionsUntilReviewed() public {
        openAndPay(ORDER, 50 * USDT, 0);
        beacon.upgradeTo(makeAddr("new implementation"));
        vm.prank(buyer);
        vm.expectRevert(SotechyEscrow.ProcessorChanged.selector);
        escrow.confirmDelivered(ORDER);

        vm.prank(owner);
        escrow.trustProcessor();
        vm.prank(buyer);
        escrow.confirmDelivered(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Released));
    }

    function test_CircuitsMustBeTheExactBytes() public {
        (uint256 v, uint256 l, uint256 b) = (escrow.verdictCircuit(), escrow.limitCircuit(), escrow.breakerCircuit());
        bytes32[3] memory wrong = [keccak256("not it"), keccak256(netlist(1).bytes_), keccak256(netlist(2).bytes_)];
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SotechyEscrow.CircuitMismatch.selector, v));
        escrow.setCircuits(v, l, b, wrong);
    }

    function test_CircuitsMustHaveTheRightShape() public {
        // The New-Store Limit circuit offered as the breaker: no memory, so it's refused
        (uint256 v, uint256 l) = (escrow.verdictCircuit(), escrow.limitCircuit());
        bytes32 limitHash = keccak256(netlist(1).bytes_);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SotechyEscrow.CircuitMismatch.selector, l));
        escrow.setCircuits(v, l, l, [keccak256(netlist(0).bytes_), limitHash, limitHash]);
    }

    // ------------------------------------------------------------------
    // Who can do what
    // ------------------------------------------------------------------

    function test_StrangersCantMoveAnOrder() public {
        openAndPay(ORDER, 50 * USDT, 0);
        vm.startPrank(stranger);
        vm.expectRevert(SotechyEscrow.NotAllowed.selector);
        escrow.markShipped(ORDER);
        vm.expectRevert(SotechyEscrow.NotAllowed.selector);
        escrow.confirmDelivered(ORDER);
        vm.expectRevert(SotechyEscrow.NotAllowed.selector);
        escrow.openDispute(ORDER);
        vm.expectRevert(SotechyEscrow.NotAllowed.selector);
        escrow.cancel(ORDER);
        vm.expectRevert(SotechyEscrow.NotOperator.selector);
        escrow.resolveDispute(ORDER, true);
        vm.expectRevert(SotechyEscrow.NotOperator.selector);
        escrow.approveReview(ORDER);
        vm.stopPrank();
    }

    function test_TheStoreCantConfirmItsOwnDelivery() public {
        openAndPay(ORDER, 50 * USDT, 0);
        vm.prank(store);
        vm.expectRevert(SotechyEscrow.NotAllowed.selector);
        escrow.confirmDelivered(ORDER);
    }

    function test_EmergencyRefundOnlyPaysTheBuyerAndOnlyWhenPaused() public {
        openAndPay(ORDER, 50 * USDT, 0);
        vm.prank(owner);
        vm.expectRevert(SotechyEscrow.NotAllowed.selector);
        escrow.emergencyRefund(ORDER);

        vm.startPrank(owner);
        escrow.setPaused(true);
        escrow.emergencyRefund(ORDER);
        vm.stopPrank();
        assertEq(usdt.balanceOf(buyer), 10_000 * USDT);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Refunded));
    }

    function test_PausingStopsNewPaymentsButNotSettling() public {
        openAndPay(ORDER, 50 * USDT, 0);
        vm.prank(owner);
        escrow.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(SotechyEscrow.IsPaused.selector);
        escrow.open(2, store, STORE_ID, 1 * USDT, uint40(block.timestamp + 1 hours), uint40(block.timestamp + 3 days), 0, 0);
        vm.prank(buyer);
        escrow.confirmDelivered(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Released));
    }

    function test_TheFeeIsCapped() public {
        vm.prank(owner);
        vm.expectRevert(SotechyEscrow.TooHigh.selector);
        escrow.setFee(1501, treasury);
    }

    function test_AFailedTokenMintNeverHoldsUpTheStoresMoney() public {
        vm.prank(owner);
        tokens.setLimits(1, 1); // the token contract will refuse this mint
        openAndPay(ORDER, 50 * USDT, 500);
        vm.prank(buyer);
        escrow.confirmDelivered(ORDER);
        assertEq(uint8(stage(ORDER)), uint8(SotechyEscrow.Stage.Released));
        assertEq(tokens.balanceOf(buyer, STORE_TOKEN), 0);
    }

    // ------------------------------------------------------------------
    // Money is never created or lost
    // ------------------------------------------------------------------

    function testFuzz_EveryPathPaysOutExactlyTheAmount(uint96 amount, uint8 path) public {
        amount = uint96(bound(amount, 1, 100 * USDT));
        openAndPay(ORDER, amount, 0);
        uint256 total = usdt.balanceOf(buyer) + usdt.balanceOf(store) + usdt.balanceOf(treasury) + usdt.balanceOf(address(escrow));
        path = path % 4;
        if (path == 0) {
            vm.prank(buyer);
            escrow.confirmDelivered(ORDER);
        } else if (path == 1) {
            vm.prank(store);
            escrow.cancel(ORDER);
        } else if (path == 2) {
            vm.warp(block.timestamp + 4 days);
            escrow.settle(ORDER);
        } else {
            vm.prank(buyer);
            escrow.openDispute(ORDER);
            vm.prank(operator);
            escrow.resolveDispute(ORDER, true);
        }
        assertEq(usdt.balanceOf(address(escrow)), 0, "nothing left behind");
        assertEq(usdt.balanceOf(buyer) + usdt.balanceOf(store) + usdt.balanceOf(treasury), total, "nothing created or lost");
    }
}
