// SPDX-License-Identifier: UNLICENSED
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

    error PriceCallFailed();

    constructor(address buyInToken_, uint256 platformFeePercentage_) Duel(buyInToken_, platformFeePercentage_) {}

    /// @notice Get the token price for the spot asset in hyperliquid
    /// @param _index Spot token index
    function tokenPx(uint32 _index) public view override returns (uint64) {
        bool success;
        bytes memory result;
        (success, result) = SPOT_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(_index));
        if (!success) revert PriceCallFailed();
        return abi.decode(result, (uint64));
    }
}
