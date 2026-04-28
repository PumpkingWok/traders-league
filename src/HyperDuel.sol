// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Duel} from "./Duel.sol";
import {L1Read} from "./L1Read.sol";

/// @title HyperDuel
/// @author Traders League Team
/// @notice Hyperliquid-specific Duel implementation backed by HyperEVM precompiles.
/// @dev Resolves token metadata and spot prices from L1 read precompiles.
contract HyperDuel is Duel, L1Read {
    /// @notice Spot token id => human-readable token name.
    mapping(uint32 => string) public tokensName;

    error TokenInfoCallFailed();

    /// @param buyInToken_ token used for buy-ins and payouts.
    /// @param platformFeePercentage_ Initial platform fee in bps.
    constructor(address buyInToken_, uint256 platformFeePercentage_) Duel(buyInToken_, platformFeePercentage_) {}

    /// @notice Enable a trading token by resolving Hyperliquid metadata.
    /// @dev Uses token info precompile to map token id to spot id and conversion decimals.
    /// @param _tokenId Hyperliquid token id.
    function enableTradingToken(uint32 _tokenId) external onlyOwner {
        TokenInfo memory tokenInfo = tokenInfo(_tokenId);
        if (tokenInfo.spots.length == 0) revert TokenInfoCallFailed();

        // spot conversion decimals derive from the Hyperliquid token precision.
        if (tokenInfo.szDecimals >= 8) revert TokenInfoCallFailed();
        uint8 tokenDecimal = 8 - tokenInfo.szDecimals;
        // use the first reported spot as the price source.
        uint32 spotTokenId = uint32(tokenInfo.spots[0]);
        if (spotTokenId == 0) revert TokenInfoCallFailed();

        tokensName[spotTokenId] = tokenInfo.name;

        _enableTradingToken(spotTokenId, tokenDecimal);
    }

    /// @notice Get the current spot price for a Hyperliquid spot token.
    /// @param _tokenId Spot token id.
    function tokenPx(uint32 _tokenId) public view override returns (uint64) {
        return spotPx(_tokenId);
    }
}
