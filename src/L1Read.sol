// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title L1Read
abstract contract L1Read {
    address constant SPOT_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000808;
    address constant TOKEN_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080C;

    struct TokenInfo {
        string name;
        uint64[] spots;
        uint64 deployerTradingFeeShare;
        address deployer;
        address evmContract;
        uint8 szDecimals;
        uint8 weiDecimals;
        int8 evmExtraWeiDecimals;
    }

    function spotPx(uint32 index) internal view returns (uint64) {
        bool success;
        bytes memory result;
        (success, result) = SPOT_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(index));
        require(success, "SpotPx precompile call failed");
        return abi.decode(result, (uint64));
    }

    function tokenInfo(uint32 token) internal view returns (TokenInfo memory) {
        bool success;
        bytes memory result;
        (success, result) = TOKEN_INFO_PRECOMPILE_ADDRESS.staticcall(abi.encode(token));
        require(success, "TokenInfo precompile call failed");
        return abi.decode(result, (TokenInfo));
    }
}
