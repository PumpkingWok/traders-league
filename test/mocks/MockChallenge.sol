// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Challenge} from "src/Challenge.sol";

contract MockChallenge is Challenge {
    mapping(uint32 => uint64) internal _prices;

    constructor(address buyInToken_, uint256 platformFeePercentage_) Challenge(buyInToken_, platformFeePercentage_) {}

    function tokenPx(uint32 _index) public view override returns (uint64) {
        return _prices[_index];
    }

    function setToken(uint32 tokenId, uint8 decimals_, uint64 px_) external {
        _enableTradingToken(tokenId, decimals_);
        _prices[tokenId] = px_;
    }

    function setPrice(uint32 tokenId, uint64 px_) external {
        _prices[tokenId] = px_;
    }
}
