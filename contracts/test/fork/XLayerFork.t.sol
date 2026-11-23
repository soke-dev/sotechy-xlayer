// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Netlists} from "../Base.t.sol";
import {SotechyEscrow, IERC20} from "../../src/SotechyEscrow.sol";
import {SotechyOrderReceipts} from "../../src/SotechyOrderReceipts.sol";
import {ITapeoutBeacon, ITapeoutProcessor, ITapeoutTransistors} from "../../src/interfaces/ITapeout.sol";
import {MockUSDT} from "../mocks/MockUSDT.sol";

/// @notice Tapes out our circuits on the real OrderGuard processor, on a fork of X Layer mainnet, and checks
/// the chain's own evaluator against the rules, then runs the escrow on it. Nothing is spent for real.
/// Run: FORK=true forge test --match-path "test/fork/*"
contract XLayerForkTest is Netlists {
    ITapeoutProcessor internal constant ORDERGUARD = ITapeoutProcessor(0x57F319CF056F72F48cF1dbb670F2A3DB007Aa355);
    ITapeoutBeacon internal constant BEACON = ITapeoutBeacon(0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C);

    address internal designer = makeAddr("designer");
    uint256[3] internal ids;
    bytes32[3] internal hashes;

    function setUp() public {
        if (!vm.envOr("FORK", false)) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork("xlayer");
        vm.deal(designer, 1 ether);
        vm.deal(address(this), 1 ether);

        // Buy exactly the transistors the three circuits burn, as the TapeOut script does
        ITapeoutTransistors t = ITapeoutTransistors(ORDERGUARD.transistors());
        string memory json = vm.readFile("../circuits/netlists.json");
        uint256 nand;
        uint256 latch;
        for (uint256 i = 0; i < 3; i++) {
            nand += vm.parseJsonUint(json, string.concat(".circuits[", vm.toString(i), "].nand"));
            latch += vm.parseJsonUint(json, string.concat(".circuits[", vm.toString(i), "].latch"));
        }
        uint256 price = t.mintPrice();
        uint256 pfee = t.protocolFee();
        vm.startPrank(designer);
        t.mint{value: price * nand + pfee}(0, nand);
        t.mint{value: price * latch + pfee}(1, latch);
        (ids, hashes) = tapeOutAll(ORDERGUARD);
        vm.stopPrank();
    }

    function test_TheCircuitsAreStoredExactlyAsBuilt() public view {
        uint32[3] memory nIn = [uint32(9), 17, 2];
        uint32[3] memory nState = [uint32(0), 0, 1];
        for (uint256 i = 0; i < 3; i++) {
            (uint32 a, uint32 b, uint32 s,) = ORDERGUARD.circuitInfo(ids[i]);
            assertEq(a, nIn[i]);
            assertEq(b, i == 0 ? 2 : 1);
            assertEq(s, nState[i]);
            assertEq(keccak256(ORDERGUARD.netlist(ids[i])), hashes[i]);
            assertEq(ORDERGUARD.ownerOf(ids[i]), designer, "the circuit NFT belongs to whoever taped it out");
        }
    }

    function test_OrderVerdictOnTheRealProcessor() public view {
        for (uint256 n = 0; n < 512; n++) {
            bytes memory out = ORDERGUARD.eval(ids[0], abi.encodePacked(bytes1(uint8(n)), bytes1(uint8(n >> 8))));
            (bool release, bool refund) = _verdictRule(n);
            assertEq(uint8(out[0]), (release ? 1 : 0) | (refund ? 2 : 0), vm.toString(n));
        }
    }

    function test_NewStoreLimitOnTheRealProcessor() public view {
        uint8[8] memory edges = [0, 1, 9, 10, 11, 127, 254, 255];
        for (uint256 i = 0; i < 8; i++) {
            for (uint256 j = 0; j < 8; j++) {
                for (uint256 est = 0; est < 2; est++) {
                    bytes memory out = ORDERGUARD.eval(ids[1], abi.encodePacked(bytes1(edges[i]), bytes1(edges[j]), bytes1(uint8(est))));
                    assertEq(uint8(out[0]) & 1 == 1, est == 1 || edges[i] <= edges[j]);
                }
            }
        }
    }

    function test_StoreBreakerOnTheRealProcessor() public view {
        for (uint256 tripped = 0; tripped < 2; tripped++) {
            for (uint256 n = 0; n < 4; n++) {
                (bytes memory next, bytes memory out) = ORDERGUARD.step(ids[2], abi.encodePacked(bytes1(uint8(tripped))), abi.encodePacked(bytes1(uint8(n))));
                bool want = n & 1 == 1 || (tripped == 1 && n & 2 == 0);
                assertEq(uint8(next[0]), want ? 1 : 0);
                assertEq(uint8(out[0]), want ? 0 : 1);
            }
        }
    }

    function test_TheEscrowWorksOnTheRealProcessor() public {
        address owner = makeAddr("owner");
        address operator = makeAddr("operator");
        address buyer = makeAddr("buyer");
        address store = makeAddr("store");
        MockUSDT usdt = new MockUSDT();
        SotechyOrderReceipts receipts = new SotechyOrderReceipts(owner);
        SotechyEscrow escrow = new SotechyEscrow(owner, operator, IERC20(address(usdt)), ORDERGUARD, BEACON);
        assertEq(escrow.processorImplementation(), BEACON.implementation());

        vm.startPrank(owner);
        receipts.setIssuer(address(escrow), true);
        escrow.setReceipts(receipts);
        escrow.setCircuits(ids[0], ids[1], ids[2], hashes);
        vm.stopPrank();
        vm.prank(operator);
        escrow.setStore(1, true, false, 10);

        usdt.mint(buyer, 1_000e6);
        vm.prank(buyer);
        usdt.approve(address(escrow), type(uint256).max);

        // Delivered: released to the store
        vm.prank(operator);
        escrow.open(1, store, 1, 50e6, uint40(block.timestamp + 1 hours), uint40(block.timestamp + 3 days), 0, 0);
        vm.startPrank(buyer);
        escrow.pay(1);
        escrow.confirmDelivered(1);
        vm.stopPrank();
        assertEq(usdt.balanceOf(store), 50e6);
        assertEq(uint8(receipts.receipt(1).status), uint8(SotechyOrderReceipts.Status.Delivered));

        // A dispute trips the breaker, through the real LATCH, and holds the store's next order
        vm.prank(operator);
        escrow.open(2, store, 1, 20e6, uint40(block.timestamp + 1 hours), uint40(block.timestamp + 3 days), 0, 0);
        vm.prank(operator);
        escrow.open(3, store, 1, 20e6, uint40(block.timestamp + 1 hours), uint40(block.timestamp + 3 days), 0, 0);
        vm.startPrank(buyer);
        escrow.pay(2);
        escrow.pay(3);
        escrow.openDispute(2);
        escrow.confirmDelivered(3);
        vm.stopPrank();
        assertTrue(escrow.breakerTripped(1));
        assertEq(uint8(escrow.order(3).stage), uint8(SotechyEscrow.Stage.Paid));
        vm.prank(operator);
        escrow.clearBreaker(1);
        escrow.settle(3);
        assertEq(uint8(escrow.order(3).stage), uint8(SotechyEscrow.Stage.Released));

        // Not shipped in time: refunded
        vm.warp(block.timestamp + 4 days);
        vm.prank(operator);
        escrow.resolveDispute(2, true);
        assertEq(uint8(escrow.order(2).stage), uint8(SotechyEscrow.Stage.Refunded));
    }

    function _verdictRule(uint256 n) internal pure returns (bool release, bool refund) {
        bool paid = n & 1 != 0;
        bool verified = n & 2 != 0;
        bool shipped = n & 4 != 0;
        bool delivered = n & 8 != 0;
        bool windowOver = n & 16 != 0;
        bool deadline = n & 32 != 0;
        bool dispute = n & 64 != 0;
        bool buyerWon = n & 128 != 0;
        bool cancelled = n & 256 != 0;
        release = paid && verified && !dispute && !buyerWon && !cancelled && (delivered || (shipped && windowOver));
        refund = paid && !dispute && (cancelled || buyerWon || (!shipped && !delivered && deadline));
    }
}
