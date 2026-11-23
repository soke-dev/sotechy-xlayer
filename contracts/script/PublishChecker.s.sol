// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Script, console} from "forge-std/Script.sol";
import {ITapeoutProcessor} from "../src/interfaces/ITapeout.sol";
import {XLayer} from "./XLayer.sol";

interface IContainerOpener {
    function FEE() external view returns (uint256);
    function accountOf(address circuits, uint256 tokenId) external view returns (address);
    function isOpened(address circuits, uint256 tokenId) external view returns (bool);
    function open(address circuits, uint256 tokenId) external payable returns (address);
}

interface ISiteRegistry {
    function putFile(address container, string calldata path, string calldata contentType, bytes32 sha256Hash, bytes calldata data) external;
    function appendChunk(address container, string calldata path, uint256 expectIndex, bytes calldata data) external;
    function setFallback(address container, string calldata path) external;
    function fallbackPath(address container) external view returns (string memory);
}

interface IDomainBinding {
    function monthlyFee() external view returns (uint256);
    function isLive(string calldata name, address container) external view returns (bool);
    function bind(string calldata name, address container, uint256 months) external payable;
}

interface IProcessorFactory {
    function cpuAt(uint256 i) external view returns (address);
}

/// @notice Publishes checker/index.html to DeWEB on X Layer, in the container of one of our circuits (the Order
/// Verdict by default), with the escrow's address filled in, and activates its name <id>.2.272.tape.
///
///   ESCROW=0x…  [CIRCUIT_ID=…]  forge script script/PublishChecker.s.sol --rpc-url xlayer --account sotechy-deployer --broadcast
///
/// The broadcaster must own the circuit (whoever ran TapeOut.s.sol). Opening a container costs TapeOut's
/// one-time fee (0.08 OKB); storing the page costs gas only.
contract PublishChecker is Script {
    IContainerOpener internal constant OPENER = IContainerOpener(0x536adD8F30f03b69f6fbF29d425A816A0dC50106);
    ISiteRegistry internal constant SITES = ISiteRegistry(0xd6EFb7adCc9c83dC4924Ad56f6a8E4e969b9ADB6);
    IDomainBinding internal constant BINDING = IDomainBinding(0x68809Fd2fb343aA57D0aeB7f33Defe477c9666f9);
    IProcessorFactory internal constant FACTORY = IProcessorFactory(0x1f09DAeFA827f02CBb40967cc91b259763760761);
    /// @notice OrderGuard is processor #272 on X Layer, which is area 2 in TapeKit's names
    uint256 internal constant ORDERGUARD_NUMBER = 272;
    uint256 internal constant CHUNK = 24_000;
    uint256 internal constant MONTHS = 120;
    string internal constant PATH = "index.html";

    function run() external returns (address container, string memory name) {
        require(block.chainid == XLayer.CHAIN_ID, "not X Layer mainnet");
        require(FACTORY.cpuAt(ORDERGUARD_NUMBER) == XLayer.ORDERGUARD, "OrderGuard's number changed");
        address escrow = vm.envAddress("ESCROW");
        uint256 circuit = vm.envOr("CIRCUIT_ID", uint256(0));
        if (circuit == 0) {
            (bool ok, bytes memory ret) = escrow.staticcall(abi.encodeWithSignature("verdictCircuit()"));
            require(ok, "ESCROW isn't the Sotechy escrow");
            circuit = abi.decode(ret, (uint256));
        }
        require(ITapeoutProcessor(XLayer.ORDERGUARD).ownerOf(circuit) == msg.sender, "the broadcaster doesn't own this circuit");

        // The page, with the escrow's address filled in
        string memory html = vm.readFile("../checker/index.html");
        html = vm.replace(html, 'escrow: "",', string.concat('escrow: "', vm.toString(escrow), '",'));
        bytes memory page = bytes(html);
        bytes32 hash = sha256(page);

        name = string.concat(vm.toString(circuit), ".2.", vm.toString(ORDERGUARD_NUMBER), ".tape");
        container = OPENER.accountOf(XLayer.ORDERGUARD, circuit);
        bool opened = OPENER.isOpened(XLayer.ORDERGUARD, circuit);
        console.log("container", container, opened ? "(open)" : "(opening costs 0.08 OKB)");
        console.log("page bytes", page.length);

        vm.startBroadcast();
        if (!opened) OPENER.open{value: OPENER.FEE()}(XLayer.ORDERGUARD, circuit);
        uint256 chunks = (page.length + CHUNK - 1) / CHUNK;
        SITES.putFile(container, PATH, "text/html; charset=utf-8", hash, _slice(page, 0));
        for (uint256 i = 1; i < chunks; i++) SITES.appendChunk(container, PATH, i, _slice(page, i));
        if (keccak256(bytes(SITES.fallbackPath(container))) != keccak256(bytes(PATH))) SITES.setFallback(container, PATH);
        if (!BINDING.isLive(name, container)) BINDING.bind{value: BINDING.monthlyFee() * MONTHS}(name, container, MONTHS);
        vm.stopBroadcast();

        console.log("name", name);
        console.log(string.concat("https://", vm.toString(circuit), "-2-", vm.toString(ORDERGUARD_NUMBER), ".tapekit.org/"));
    }

    function _slice(bytes memory b, uint256 i) internal pure returns (bytes memory out) {
        uint256 start = i * CHUNK;
        uint256 end = start + CHUNK > b.length ? b.length : start + CHUNK;
        out = new bytes(end - start);
        for (uint256 k = 0; k < out.length; k++) out[k] = b[start + k];
    }
}
