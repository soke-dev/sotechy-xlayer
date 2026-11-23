// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {SotechyEscrow, IERC20, ISotechyTokens} from "../src/SotechyEscrow.sol";
import {SotechyOrderReceipts} from "../src/SotechyOrderReceipts.sol";
import {ITapeoutBeacon, ITapeoutProcessor} from "../src/interfaces/ITapeout.sol";
import {XLayer} from "./XLayer.sol";

interface ITokensAdmin {
    function setOperator(address operator, bool allowed) external;
    function transferOwnership(address to) external;
}

/// @notice Deploys the receipts, the escrow and (unless TOKENS is given) Sotechy's store-token contract on X Layer,
/// and wires them to the circuits taped out by TapeOut.s.sol.
///
///   OPERATOR=0x…  VERDICT_ID=…  LIMIT_ID=…  BREAKER_ID=…  [OWNER=0x…] [TREASURY=0x…] [FEE_BPS=…] [TOKENS=0x…] \
///   forge script script/Deploy.s.sol --rpc-url xlayer --account sotechy-deployer --broadcast
///
/// OPERATOR is the low-power key Sotechy's API uses. The broadcaster sets everything up, then hands ownership
/// to OWNER (who accepts it with acceptOwnership on each contract), if OWNER is someone else.
contract Deploy is Script {
    function run() external returns (SotechyEscrow escrow, SotechyOrderReceipts receipts, address tokens) {
        require(block.chainid == XLayer.CHAIN_ID, "not X Layer mainnet");
        address operator = vm.envAddress("OPERATOR");
        address owner = vm.envOr("OWNER", msg.sender);
        address treasury = vm.envOr("TREASURY", owner);
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(0)));
        tokens = vm.envOr("TOKENS", address(0));
        uint256[3] memory ids = [vm.envUint("VERDICT_ID"), vm.envUint("LIMIT_ID"), vm.envUint("BREAKER_ID")];

        // The exact bytes in netlists.json must be what's on chain
        string memory json = vm.readFile("../circuits/netlists.json");
        bytes32[3] memory hashes;
        for (uint256 i = 0; i < 3; i++) {
            hashes[i] = keccak256(vm.parseJsonBytes(json, string.concat(".circuits[", vm.toString(i), "].netlist")));
        }

        vm.startBroadcast();
        bool newTokens = tokens == address(0);
        if (newTokens) {
            // Sotechy's store-token contract, unchanged from Sotechy-App: max 50M a mint, 1B a day
            tokens = deployCode("SotechyTokens.sol:SotechyTokens", abi.encode(msg.sender, operator, 50_000_000, 1_000_000_000, ""));
        }
        receipts = new SotechyOrderReceipts(msg.sender);
        escrow = new SotechyEscrow(
            msg.sender, operator, IERC20(XLayer.USDT0), ITapeoutProcessor(XLayer.ORDERGUARD), ITapeoutBeacon(XLayer.TAPEOUT_BEACON)
        );

        receipts.setIssuer(address(escrow), true);
        escrow.setReceipts(receipts);
        escrow.setRewards(ISotechyTokens(tokens));
        escrow.setFee(feeBps, treasury);
        escrow.setCircuits(ids[0], ids[1], ids[2], hashes);
        // An existing token contract's owner adds the escrow as an operator themselves
        if (newTokens) ITokensAdmin(tokens).setOperator(address(escrow), true);

        if (owner != msg.sender) {
            escrow.transferOwnership(owner);
            receipts.transferOwnership(owner);
            if (newTokens) ITokensAdmin(tokens).transferOwnership(owner);
        }
        vm.stopBroadcast();

        console.log("SotechyEscrow", address(escrow));
        console.log("SotechyOrderReceipts", address(receipts));
        console.log("SotechyTokens", tokens);
        if (!newTokens) console.log("Now, as SotechyTokens' owner: setOperator(escrow, true)");
        if (owner != msg.sender) console.log("Now, as OWNER: acceptOwnership() on each contract");
    }
}
