// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ITapeoutProcessor, ITapeoutTransistors} from "../src/interfaces/ITapeout.sol";
import {XLayer} from "./XLayer.sol";

/// @notice Buys the transistors the three circuits need and tapes them out on OrderGuard, from
/// circuits/netlists.json. The broadcaster becomes each circuit's owner (its NFT).
///
///   forge script script/TapeOut.s.sol --rpc-url xlayer --account sotechy-deployer --broadcast
///
/// Without --broadcast it only prints what it would spend.
contract TapeOut is Script {
    string[3] internal KEYS = ["order-verdict", "new-store-limit", "store-breaker"];

    function run() external returns (uint256[3] memory ids, bytes32[3] memory hashes) {
        require(block.chainid == XLayer.CHAIN_ID, "not X Layer mainnet");
        ITapeoutProcessor processor = ITapeoutProcessor(XLayer.ORDERGUARD);
        ITapeoutTransistors t = ITapeoutTransistors(processor.transistors());
        string memory json = vm.readFile("../circuits/netlists.json");

        uint256 nand;
        uint256 latch;
        for (uint256 i = 0; i < 3; i++) {
            string memory at = string.concat(".circuits[", vm.toString(i), "]");
            require(keccak256(bytes(vm.parseJsonString(json, string.concat(at, ".key")))) == keccak256(bytes(KEYS[i])), "netlists.json order");
            nand += vm.parseJsonUint(json, string.concat(at, ".nand"));
            latch += vm.parseJsonUint(json, string.concat(at, ".latch"));
        }

        // Only buy what the wallet doesn't hold already
        address me = msg.sender;
        uint256 needNand = nand > t.balanceOf(me, 0) ? nand - t.balanceOf(me, 0) : 0;
        uint256 needLatch = latch > t.balanceOf(me, 1) ? latch - t.balanceOf(me, 1) : 0;
        uint256 price = t.mintPrice();
        uint256 pfee = t.protocolFee();
        uint256 tapeFee = processor.TAPEOUT_FEE();
        uint256 total = (needNand > 0 ? price * needNand + pfee : 0) + (needLatch > 0 ? price * needLatch + pfee : 0) + tapeFee * 3;
        console.log("NAND / LATCH needed:", nand, latch);
        console.log("OKB to spend, excluding gas (wei):", total);
        require(me.balance > total, "not enough OKB");

        vm.startBroadcast();
        if (needNand > 0) t.mint{value: price * needNand + pfee}(0, needNand);
        if (needLatch > 0) t.mint{value: price * needLatch + pfee}(1, needLatch);
        for (uint256 i = 0; i < 3; i++) {
            string memory at = string.concat(".circuits[", vm.toString(i), "]");
            bytes memory nl = vm.parseJsonBytes(json, string.concat(at, ".netlist"));
            uint32 nIn = uint32(vm.parseJsonUint(json, string.concat(at, ".nIn")));
            uint32 nOut = uint32(vm.parseJsonUint(json, string.concat(at, ".nOut")));
            ids[i] = processor.tapeout{value: tapeFee}(nl, nIn, nOut);
            hashes[i] = keccak256(nl);
            console.log(string.concat(KEYS[i], ": circuit id"), ids[i]);
            console.logBytes32(hashes[i]);
        }
        vm.stopBroadcast();
    }
}
