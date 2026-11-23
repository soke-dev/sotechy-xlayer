// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice X Layer mainnet (chain 196) addresses this project builds on. Scripts check the chain before using them.
library XLayer {
    uint256 internal constant CHAIN_ID = 196;
    /// @notice TapeOut's "OrderGuard" processor, where Sotechy's circuits are taped out
    address internal constant ORDERGUARD = 0x57F319CF056F72F48cF1dbb670F2A3DB007Aa355;
    /// @notice The beacon every TapeOut processor proxy runs through (TAP-10)
    address internal constant TAPEOUT_BEACON = 0xf70d1ed4f62CF3780157B0b421b7E2F45bD0991C;
    /// @notice USD₮0, 6 decimals
    address internal constant USDT0 = 0x779Ded0c9e1022225f8E0630b35a9b54bE713736;
}
