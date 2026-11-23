// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {SotechyEscrow, IERC20, ISotechyTokens} from "../src/SotechyEscrow.sol";
import {SotechyOrderReceipts} from "../src/SotechyOrderReceipts.sol";
import {ITapeoutBeacon, ITapeoutProcessor} from "../src/interfaces/ITapeout.sol";
import {MockBeacon, MockProcessor} from "./mocks/MockProcessor.sol";
import {MockUSDT} from "./mocks/MockUSDT.sol";

/// @notice The vendored SotechyTokens, as the tests use it (it's pinned to solc 0.8.24, so it's deployed from its build)
interface ITokens {
    function setOperator(address operator, bool allowed) external;
    function registerToken(uint256 id, string calldata ticker) external;
    function setLimits(uint256 maxMintPerOp, uint256 maxMintPerDay) external;
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @notice Reads the circuits' bytes from circuits/netlists.json, so tests use exactly what gets taped out
abstract contract Netlists is Test {
    struct Netlist {
        bytes bytes_;
        uint32 nIn;
        uint32 nOut;
    }

    function netlist(uint256 i) internal view returns (Netlist memory n) {
        string memory json = vm.readFile("../circuits/netlists.json");
        string memory at = string.concat(".circuits[", vm.toString(i), "]");
        n.bytes_ = vm.parseJsonBytes(json, string.concat(at, ".netlist"));
        n.nIn = uint32(vm.parseJsonUint(json, string.concat(at, ".nIn")));
        n.nOut = uint32(vm.parseJsonUint(json, string.concat(at, ".nOut")));
    }

    /// @notice Tapes out the three circuits (Order Verdict, New-Store Limit, Store Breaker) on a processor
    function tapeOutAll(ITapeoutProcessor p) internal returns (uint256[3] memory ids, bytes32[3] memory hashes) {
        uint256 fee = p.TAPEOUT_FEE();
        for (uint256 i = 0; i < 3; i++) {
            Netlist memory n = netlist(i);
            ids[i] = p.tapeout{value: fee}(n.bytes_, n.nIn, n.nOut);
            hashes[i] = keccak256(n.bytes_);
        }
    }
}

/// @notice Everything wired as on mainnet, with a mock processor and a mock USDT
abstract contract Base is Netlists {
    address internal owner = makeAddr("owner");
    address internal operator = makeAddr("operator");
    address internal buyer = makeAddr("buyer");
    address internal store = makeAddr("store");
    address internal treasury = makeAddr("treasury");
    address internal stranger = makeAddr("stranger");

    uint32 internal constant STORE_ID = 7;
    uint32 internal constant STORE_TOKEN = 7;
    uint96 internal constant USDT = 1e6;

    MockUSDT internal usdt;
    MockProcessor internal processor;
    MockBeacon internal beacon;
    SotechyOrderReceipts internal receipts;
    ITokens internal tokens;
    SotechyEscrow internal escrow;

    function setUp() public virtual {
        usdt = new MockUSDT();
        processor = new MockProcessor();
        beacon = new MockBeacon(makeAddr("circuit implementation"));
        (uint256[3] memory ids, bytes32[3] memory hashes) = tapeOutAll(ITapeoutProcessor(address(processor)));

        receipts = new SotechyOrderReceipts(owner);
        tokens = ITokens(deployCode("SotechyTokens.sol:SotechyTokens", abi.encode(owner, operator, 10_000_000, 100_000_000, "")));
        escrow = new SotechyEscrow(owner, operator, IERC20(address(usdt)), ITapeoutProcessor(address(processor)), ITapeoutBeacon(address(beacon)));

        vm.startPrank(owner);
        receipts.setIssuer(address(escrow), true);
        tokens.setOperator(address(escrow), true);
        escrow.setReceipts(receipts);
        escrow.setRewards(ISotechyTokens(address(tokens)));
        escrow.setFee(500, treasury); // 5%
        escrow.setCircuits(ids[0], ids[1], ids[2], hashes);
        vm.stopPrank();

        vm.startPrank(operator);
        tokens.registerToken(STORE_TOKEN, "STORE");
        escrow.setStore(STORE_ID, true, false, 10); // verified, new, limit $100
        vm.stopPrank();

        usdt.mint(buyer, 10_000 * USDT);
        vm.prank(buyer);
        usdt.approve(address(escrow), type(uint256).max);
    }

    /// @notice Sotechy opens the order's terms and the buyer pays
    function openAndPay(uint256 orderId, uint96 amount, uint96 earn) internal {
        vm.prank(operator);
        escrow.open(orderId, store, STORE_ID, amount, uint40(block.timestamp + 1 hours), uint40(block.timestamp + 3 days), STORE_TOKEN, earn);
        vm.prank(buyer);
        escrow.pay(orderId);
    }

    function stage(uint256 orderId) internal view returns (SotechyEscrow.Stage) {
        return escrow.order(orderId).stage;
    }

    function status(uint256 orderId) internal view returns (SotechyOrderReceipts.Status) {
        return receipts.receipt(orderId).status;
    }
}
