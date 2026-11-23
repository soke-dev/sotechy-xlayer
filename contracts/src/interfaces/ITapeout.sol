// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice A TapeOut processor: stores circuits (one ERC-721 each) and evaluates them. Signatures from TAP-02 §6.
interface ITapeoutProcessor {
    /// @notice The exact OKB a tape-out costs
    function TAPEOUT_FEE() external view returns (uint256);
    /// @notice Stores a netlist as a new circuit, burning the caller's NAND and LATCH transistor tokens
    function tapeout(bytes calldata netlist, uint32 nIn, uint32 nOut) external payable returns (uint256 id);
    function nextId() external view returns (uint256);
    function circuitInfo(uint256 id) external view returns (uint32 nIn, uint32 nOut, uint32 nState, uint32 gateCount);
    function netlist(uint256 id) external view returns (bytes memory);
    /// @notice One beat of a circuit without memory. Reverts "has latch: use step" for one with memory.
    function eval(uint256 id, bytes calldata inputs) external view returns (bytes memory outputs);
    /// @notice One beat with caller-supplied memory
    function step(uint256 id, bytes calldata state, bytes calldata inputs)
        external
        view
        returns (bytes memory newState, bytes memory outputs);
    function ownerOf(uint256 id) external view returns (address);
    /// @notice The processor's ERC-1155 transistor token (id 0 = NAND, id 1 = LATCH)
    function transistors() external view returns (address);
}

/// @notice A processor's transistor token: bought before a tape-out, burned by it
interface ITapeoutTransistors {
    function mint(uint256 id, uint256 amount) external payable;
    function mintPrice() external view returns (uint256);
    function protocolFee() external view returns (uint256);
    function balanceOf(address account, uint256 id) external view returns (uint256);
}

/// @notice The beacon every processor proxy runs through. If its implementation changes, circuits could behave differently.
interface ITapeoutBeacon {
    function implementation() external view returns (address);
}
