// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A stand-in TapeOut processor for unit tests: stores netlists and evaluates NAND and LATCH records
/// exactly as TAP-02 §4 and §5 say (no REF, no fees). The fork tests run the same flows on the real processor.
contract MockProcessor {
    struct Circuit {
        bytes netlist;
        uint32 nIn;
        uint32 nOut;
        uint32 nState;
        uint32 gates;
        address author;
    }

    mapping(uint256 => Circuit) private _circuits;
    uint256 public nextId = 1;

    function TAPEOUT_FEE() external pure returns (uint256) {
        return 0;
    }

    function transistors() external pure returns (address) {
        return address(0);
    }

    function tapeout(bytes calldata nl, uint32 nIn, uint32 nOut) external payable returns (uint256 id) {
        (uint256 elements, uint256 latches) = _scan(nl);
        require(elements >= nOut && nOut > 0, "too few signals for outputs");
        id = nextId++;
        _circuits[id] = Circuit(nl, nIn, nOut, uint32(latches), uint32(elements), msg.sender);
    }

    function circuitInfo(uint256 id) external view returns (uint32, uint32, uint32, uint32) {
        Circuit storage c = _circuits[id];
        require(c.author != address(0), "no circuit");
        return (c.nIn, c.nOut, c.nState, c.gates);
    }

    function netlist(uint256 id) external view returns (bytes memory) {
        return _circuits[id].netlist;
    }

    function ownerOf(uint256 id) external view returns (address) {
        return _circuits[id].author;
    }

    function eval(uint256 id, bytes calldata inputs) external view returns (bytes memory outputs) {
        Circuit storage c = _circuits[id];
        require(c.author != address(0), "no circuit");
        require(c.nState == 0, "has latch: use step");
        (, outputs) = _beat(c.netlist, c.nIn, c.nOut, "", inputs);
    }

    function step(uint256 id, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs)
    {
        Circuit storage c = _circuits[id];
        require(c.author != address(0), "no circuit");
        return _beat(c.netlist, c.nIn, c.nOut, state, inputs);
    }

    function _scan(bytes memory nl) internal pure returns (uint256 elements, uint256 latches) {
        uint256 p;
        while (p < nl.length) {
            uint8 op = uint8(nl[p]);
            if (op == 0) p += 7;
            else if (op == 1) {
                p += 4;
                latches++;
            } else revert("bad opcode");
            require(p <= nl.length, "truncated");
            elements++;
        }
    }

    function _u24(bytes memory nl, uint256 p) internal pure returns (uint256) {
        return (uint256(uint8(nl[p])) << 16) | (uint256(uint8(nl[p + 1])) << 8) | uint256(uint8(nl[p + 2]));
    }

    /// @dev Bit i of a packed vector: bit (i mod 8) of byte i / 8, and 0 past the end (TAP-02 §5)
    function _bitOf(bytes memory v, uint256 i) internal pure returns (bool) {
        return i / 8 < v.length && (uint8(v[i / 8]) >> (i % 8)) & 1 == 1;
    }

    function _beat(bytes memory nl, uint32 nIn, uint32 nOut, bytes memory state, bytes memory inputs)
        internal
        pure
        returns (bytes memory newState, bytes memory outputs)
    {
        (uint256 elements, uint256 latches) = _scan(nl);
        uint256 total = 2 + nIn + elements;
        bool[] memory s = new bool[](total);
        s[1] = true;
        for (uint256 i = 0; i < nIn; i++) s[2 + i] = _bitOf(inputs, i);
        uint256[] memory latchD = new uint256[](latches);
        uint256 p;
        uint256 k;
        for (uint256 idx = 2 + nIn; idx < total; idx++) {
            if (uint8(nl[p]) == 0) {
                s[idx] = !(s[_u24(nl, p + 1)] && s[_u24(nl, p + 4)]);
                p += 7;
            } else {
                s[idx] = _bitOf(state, k);
                latchD[k++] = _u24(nl, p + 1);
                p += 4;
            }
        }
        newState = new bytes((latches + 7) / 8);
        for (uint256 j = 0; j < latches; j++) {
            if (s[latchD[j]]) newState[j / 8] |= bytes1(uint8(1 << (j % 8)));
        }
        outputs = new bytes((uint256(nOut) + 7) / 8);
        for (uint256 j = 0; j < nOut; j++) {
            if (s[total - nOut + j]) outputs[j / 8] |= bytes1(uint8(1 << (j % 8)));
        }
    }
}

/// @notice A stand-in for TapeOut's beacon, so tests can simulate an upgrade
contract MockBeacon {
    address public implementation;

    constructor(address impl) {
        implementation = impl;
    }

    function upgradeTo(address impl) external {
        implementation = impl;
    }
}
