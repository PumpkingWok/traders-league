// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {MockPrecompileLive} from "../mocks/MockPrecompileLive.sol";
import {HyperChallenge} from "src/HyperChallenge.sol";

abstract contract HyperChallengeInt is Test {
    HyperChallenge internal challenge;
    IERC20Metadata internal buyInToken;

    string internal forkName;

    uint32[] internal tokensIndex;
    uint32[] internal tokensSpotIndex;
    uint8[] internal tokensDecimals;
    string[] internal tokensName = new string[](3);

    constructor(
        string memory forkName_,
        address buyInToken_,
        uint32[3] memory tokensIndex_,
        uint32[3] memory tokensSpotIndex_,
        uint8[3] memory tokensDecimals_,
        string[3] memory tokensName_
    ) {
        forkName = forkName_;
        buyInToken = IERC20Metadata(buyInToken_);
        tokensIndex = tokensIndex_;
        tokensSpotIndex = tokensSpotIndex_;
        tokensDecimals = tokensDecimals_;
        tokensName = tokensName_;
    }

    function setUp() public virtual {
        vm.createSelectFork(forkName);

        _mockPrecompiles();

        challenge = new HyperChallenge(address(buyInToken), 50);

        for (uint256 i; i < tokensIndex.length; ++i) {
            challenge.enableTradingToken(tokensIndex[i]);
        }
    }

    function test_EnableTradingToken() external view {
        uint256 length = tokensSpotIndex.length;

        for (uint256 i; i < length; ++i) {
            assertEq(challenge.tradingTokensDecimals(tokensSpotIndex[i]), tokensDecimals[i]);
            assertEq(challenge.tokensName(tokensSpotIndex[i]), tokensName[i]);
        }
    }

    function test_TokenPx() external view {
        uint256 length = tokensSpotIndex.length;

        for (uint256 i; i < length; ++i) {
            assertGt(challenge.tokenPx(tokensSpotIndex[i]), 0);
        }
    }

    function _mockPrecompiles() internal {
        for (uint160 i = 0; i < 17; i++) {
            address precompileAddress = address(uint160(0x0000000000000000000000000000000000000800) + i);
            vm.etch(precompileAddress, type(MockPrecompileLive).runtimeCode);
            vm.allowCheatcodes(precompileAddress);
        }
    }
}

address constant BUY_IN_TOKEN_MAINNET = 0xb88339CB7199b77E23DB6E890353E22632Ba630f;
address constant BUY_IN_TOKEN_TESTNET = 0x2B3370eE501B4a559b57D449569354196457D8Ab;

// hyperliquid mainnet indexes
// UBTC -> tokenIndex 197, spot index 142, decimals 3
// UETH -> tokenIndex 221, spot index 151, decimals 4
// USOL -> tokenIndex 254, spot index 156, decimals 5
contract HyperChallengeIntMainnet is
    HyperChallengeInt(
        "hl_mainnet",
        BUY_IN_TOKEN_MAINNET,
        [uint32(197), uint32(221), uint32(254)],
        [uint32(142), uint32(151), uint32(156)],
        [3, 4, 5],
        ["UBTC", "UETH", "USOL"]
    )
{}

// hyperliquid testnet indexes
// HYPE -> tokenIndex 1105, spot index 1035, decimals 6
// UETH -> tokenIndex 1242, spot index 1137, decimals 4
// HORSE -> tokenIndex 1435, spot index 1319, decimals 6
contract HyperChallengeIntTestnet is
    HyperChallengeInt(
        "hl_testnet",
        BUY_IN_TOKEN_TESTNET,
        [uint32(1105), uint32(1242), uint32(1435)],
        [uint32(1035), uint32(1137), uint32(1319)],
        [6, 4, 6],
        ["HYPE", "UETH", "HORSE"]
    )
{}
