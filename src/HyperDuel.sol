// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Duel} from "./Duel.sol";
import {L1Read} from "./L1Read.sol";

// 1 VS 1 Match creator
// Hyperliquid version
// USDC at evm -> decimals ?
// spot px decimals
// use USDC as buy in token
// initial virtual usd for every user
contract HyperDuel is Duel {
    // spot token id => token name
    mapping(uint32 => string) public tokensName;

    error SpotPxCallFailed();
    error TokenInfoCallFailed();

    constructor(address buyInToken_, uint256 platformFeePercentage_) Duel(buyInToken_, platformFeePercentage_) {}

    /// @notice Enable a trading token setting the usd spot price decimals
    /// @param _tokenId Token id
    function enableTradingToken(uint32 _tokenId) external onlyOwner {
        (bool success, bytes memory result) = L1Read.TOKEN_INFO_PRECOMPILE_ADDRESS.staticcall(abi.encode(_tokenId));
        if (!success || result.length == 0) revert TokenInfoCallFailed();

        L1Read.TokenInfo memory tokenInfo = abi.decode(result, (L1Read.TokenInfo));
        if (tokenInfo.spots.length == 0) revert TokenInfoCallFailed();

        // spot price decimals is 8 - szDecimals
        if (tokenInfo.szDecimals > 8) revert TokenInfoCallFailed();
        uint8 tokenDecimal = 8 - tokenInfo.szDecimals;
        // get the first spot index as price source
        uint32 spotTokenId = uint32(tokenInfo.spots[0]);

        tokensName[spotTokenId] = tokenInfo.name;

        _enableTradingToken(spotTokenId, tokenDecimal);
    }

    /// @notice Get the token price for the spot asset in hyperliquid
    /// @param _tokenId Spot token id
    function tokenPx(uint32 _tokenId) public view override returns (uint64) {
        (bool success, bytes memory result) = L1Read.SPOT_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(_tokenId));
        if (!success) revert SpotPxCallFailed();
        return abi.decode(result, (uint64));
    }
}
