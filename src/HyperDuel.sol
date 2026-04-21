// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/access/Ownable2Step.sol";

import {Duel} from "./Duel.sol";

// 1 VS 1 Match creator
// Hyperliquid version
// USDC at evm -> decimals ?
// spot px decimals
// use USDC as buy in token
// initial virtual usd for every user
contract HyperDuel is Duel {
    // Constant
    address constant SPOT_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000808;
    address constant TOKEN_INFO_PRECOMPILE_ADDRESS = 0x000000000000000000000000000000000000080C;

    // spot token id => token name
    mapping(uint32 => string) public tokensName;

    error SpotPxCallFailed();
    error TokenInfoCallFailed();

    constructor(address buyInToken_, uint256 platformFeePercentage_) Duel(buyInToken_, platformFeePercentage_) {}

    /// @notice Enable a trading token setting the usd spot price decimals (0 to disable the token)
    function toggleTradingToken(uint32 _tokenId) external onlyOwner {
        // disable it setting decimals to zero
        if (tradingTokensDecimals[_tokenId] != 0) {
            tradingTokensDecimals[_tokenId] = 0;
            return;
        }
        (bool success, bytes memory result) = TOKEN_INFO_PRECOMPILE_ADDRESS.staticcall(abi.encode(_tokenId));
        if (!success || result.length == 0) revert TokenInfoCallFailed();

        uint8 szDecimals;
        uint64 spotTokenId;
        string memory tokenName;
        assembly {
            // 1) fetch szDecimals
            szDecimals := and(mload(add(result, 0xE0)), 0xff)

            let data := add(result, 0x20) // start of returndata payload
            let tuplePtr := add(data, mload(data)) // TokenInfo tuple start

            // 2) fetch spot token id
            // slot 1 of TokenInfo head = offset to spots[]
            let spotsOffset := mload(add(tuplePtr, 0x20))
            let spotsPtr := add(tuplePtr, spotsOffset)

            // spotsPtr[0] = length, spotsPtr[1] = first element
            if gt(mload(spotsPtr), 0) {
                spotTokenId := and(mload(add(spotsPtr, 0x20)), 0xFFFFFFFFFFFFFFFF)
            }

            // 3) fetch token name
            let nameOffset := mload(tuplePtr)
            tokenName := add(tuplePtr, nameOffset)
        }

        tokensName[uint32(spotTokenId)] = tokenName;

        // spot price decimals is 8 - szDecimals
        _toggleTradingToken(uint32(spotTokenId), 8 - szDecimals);
    }

    /// @notice Get the token price for the spot asset in hyperliquid
    /// @param _tokenId Spot token id
    function tokenPx(uint32 _tokenId) public view override returns (uint64) {
        (bool success, bytes memory result) = SPOT_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(_tokenId));
        if (!success) revert SpotPxCallFailed();
        return abi.decode(result, (uint64));
    }
}
