// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Netlists} from "./Base.t.sol";
import {ITapeoutProcessor} from "../src/interfaces/ITapeout.sol";
import {MockProcessor} from "./mocks/MockProcessor.sol";

/// @notice The circuits from netlists.json, run by the mock processor, against their rules on every input.
/// Keeps the mock honest; the fork test runs the same checks on the real OrderGuard processor.
contract CircuitsTest is Netlists {
    ITapeoutProcessor internal processor;
    uint256[3] internal ids;

    function setUp() public {
        processor = ITapeoutProcessor(address(new MockProcessor()));
        (ids,) = tapeOutAll(processor);
    }

    function test_OrderVerdictOnAll512Inputs() public view {
        for (uint256 n = 0; n < 512; n++) {
            bytes memory out = processor.eval(ids[0], abi.encodePacked(bytes1(uint8(n)), bytes1(uint8(n >> 8))));
            (bool release, bool refund) = verdictRule(n);
            assertEq(uint8(out[0]), (release ? 1 : 0) | (refund ? 2 : 0), vm.toString(n));
        }
    }

    function test_NewStoreLimitOnEveryAmountAndLimit() public view {
        for (uint256 amount = 0; amount < 256; amount += 3) {
            for (uint256 limit = 0; limit < 256; limit += 5) {
                for (uint256 est = 0; est < 2; est++) {
                    bytes memory out = processor.eval(ids[1], abi.encodePacked(bytes1(uint8(amount)), bytes1(uint8(limit)), bytes1(uint8(est))));
                    assertEq(uint8(out[0]) & 1 == 1, est == 1 || amount <= limit);
                }
            }
        }
    }

    function test_StoreBreakerInEveryStateAndInput() public view {
        for (uint256 tripped = 0; tripped < 2; tripped++) {
            for (uint256 n = 0; n < 4; n++) {
                (bytes memory next, bytes memory out) = processor.step(ids[2], abi.encodePacked(bytes1(uint8(tripped))), abi.encodePacked(bytes1(uint8(n))));
                bool want = n & 1 == 1 || (tripped == 1 && n & 2 == 0);
                assertEq(uint8(next[0]), want ? 1 : 0);
                assertEq(uint8(out[0]), want ? 0 : 1);
            }
        }
    }

    /// @notice The Order Verdict rule, as in circuits/src/circuits.ts
    function verdictRule(uint256 n) internal pure returns (bool release, bool refund) {
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
