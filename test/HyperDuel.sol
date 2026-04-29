// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";

import {MockPrecompileLive} from "./mocks/MockPrecompileLive.sol";
import {MockSpotPx} from "./mocks/MockSpotPx.sol";

import "src/HyperDuel.sol";
import {IHyperDuel} from "./IHyperDuel.sol";

abstract contract HyperDuelTest is Test {
    MockSpotPx internal spotPxPrecompile;
    HyperDuel internal duel;

    IERC20Metadata internal buyInToken;
    address internal feeRecipient = address(0xBEEF);
    address internal playerA = address(0xABCD);
    address internal playerB = address(0xABBB);
    uint256 platformFeePercentage = 100; // 1%

    string forkName;
    // token index used to get the token name and token spot index
    uint32[] tokensIndex;
    // real index used in contract to get the spotPx
    uint32[] tokensSpotIndex;
    uint8[] tokensDecimals;
    string[] tokensName = new string[](3);

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

    function setUp() public {
        vm.createSelectFork(forkName);

        _mockPrecompiles();

        // deploy duel contract
        duel = new HyperDuel(address(buyInToken), platformFeePercentage);

        // enable token
        for (uint256 i; i < tokensIndex.length; ++i) {
            duel.enableTradingToken(tokensIndex[i]);
        }

        deal(address(buyInToken), playerA, 100e6);
        deal(address(buyInToken), playerB, 100e6);

        vm.prank(playerA);
        buyInToken.approve(address(duel), 100e6);
        vm.prank(playerB);
        buyInToken.approve(address(duel), 100e6);
    }

    function test_Deploy() public view {
        assertEq(address(duel.buyInToken()), address(buyInToken));
        assertEq(duel.platformFeePercentage(), platformFeePercentage);
        assertEq(duel.owner(), address(this));
        assertEq(duel.minBuyIn(), 10 * 10 ** buyInToken.decimals());
        assertEq(duel.maxBuyIn(), 1000 * 10 ** buyInToken.decimals());
        assertEq(duel.minDuration(), 15 minutes);
        assertEq(duel.maxDuration(), 1 weeks);
        assertEq(duel.INITIAL_VIRTUAL_USD(), 100_000e18);
        assertEq(duel.BASE_FEE(), 10_000);
        assertEq(duel.GAME_TRADER_FEE(), 30);
        assertEq(duel.MAX_PLATFORM_FEE(), 500);
    }

    function test_SetBuyIn() public {
        // try to set min buy in equal to zero
        vm.expectRevert(Duel.WrongBuyIn.selector);
        duel.setMinBuyIn(0);

        // try to set max buy in equal to zero
        vm.expectRevert(Duel.WrongBuyIn.selector);
        duel.setMaxBuyIn(0);

        uint256 decimals = buyInToken.decimals();

        // try to set a min buy in higher than max buy in
        vm.expectRevert(Duel.WrongBuyIn.selector);
        duel.setMinBuyIn(2000 * 10 ** decimals);

        // try to set a max buy in lower than min buy in
        vm.expectRevert(Duel.WrongBuyIn.selector);
        duel.setMaxBuyIn(5 * 10 ** decimals);
    }

    function test_SetDuration() public {
        // try to set min duration equal to zero
        vm.expectRevert(Duel.WrongDuration.selector);
        duel.setMinDuration(0);

        // try to set max duration equal to zero
        vm.expectRevert(Duel.WrongDuration.selector);
        duel.setMaxDuration(0);

        // try to set a min duration higher than max duration
        vm.expectRevert(Duel.WrongDuration.selector);
        duel.setMinDuration(2 weeks);

        // try to set a max duration lower than min duration
        vm.expectRevert(Duel.WrongDuration.selector);
        duel.setMaxDuration(1 minutes);
    }

    function test_setPlatformFee() public {
        uint256 maxPlatformFeePercentage = duel.MAX_PLATFORM_FEE();
        // try to set more than max platform fee
        vm.expectRevert(Duel.FeeTooHigh.selector);
        duel.setPlatformFeePercentage(maxPlatformFeePercentage + 1);

        duel.setPlatformFeePercentage(maxPlatformFeePercentage);
        assertEq(duel.platformFeePercentage(), maxPlatformFeePercentage);
    }

    function test_TradingTokens() public {
        for (uint256 i; i < tokensSpotIndex.length; ++i) {
            assertEq(duel.tradingTokensDecimals(tokensSpotIndex[i]), tokensDecimals[i]);
            assertEq(duel.tokensName(tokensSpotIndex[i]), tokensName[i]);
        }
    }

    function test_CreateMatchWithoutJoin() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        duel.createMatch(address(0), address(0), tokensAllowed, buyIn, duration);

        uint32[] memory matchTokensAllowed = duel.getMatchTokensAllowed(1);
        uint256 lenght = tokensSpotIndex.length;
        assertEq(matchTokensAllowed.length, lenght);
        for (uint256 i; i < lenght; ++i) {
            assertEq(matchTokensAllowed[i], tokensSpotIndex[i]);
        }

        _checkMatchInfo(1, address(0), address(0), address(0), buyIn, duration, 0, IHyperDuel.MatchStatus.TO_START);
    }

    function test_CreateMatchAndJoin() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        uint256 balanceBefore = buyInToken.balanceOf(playerA);
        vm.prank(playerA);
        duel.createMatch(playerA, address(0), tokensAllowed, buyIn, duration);
        uint256 balanceAfter = buyInToken.balanceOf(playerA);
        uint256 duelBalance = buyInToken.balanceOf(address(duel));
        assertEq(balanceBefore - balanceAfter, buyIn);
        assertEq(duelBalance, buyIn);

        _checkMatchInfo(1, playerA, address(0), address(0), buyIn, duration, 0, IHyperDuel.MatchStatus.TO_START);
    }

    function test_CreateMatchReserved() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        vm.prank(playerA);
        duel.createMatch(playerA, playerB, tokensAllowed, buyIn, duration);

        _checkMatchInfo(1, playerA, playerB, address(0), buyIn, duration, 0, IHyperDuel.MatchStatus.TO_START);
    }

    function test_UnjoinMatch() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        uint256 initBalance = buyInToken.balanceOf(playerA);
        vm.startPrank(playerA);
        // create match
        duel.createMatch(playerA, address(0), tokensAllowed, buyIn, duration);

        // remove match
        duel.unjoinMatch(1);
        vm.stopPrank();
        uint256 finalBalance = buyInToken.balanceOf(playerA);
        assertEq(initBalance, finalBalance);

        _checkMatchInfo(1, address(0), address(0), address(0), buyIn, duration, 0, IHyperDuel.MatchStatus.TO_START);
    }

    function test_StartMatch() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        vm.startPrank(playerA);
        // create match
        duel.createMatch(playerA, address(0), tokensAllowed, buyIn, duration);

        vm.startPrank(playerB);
        // playerB joins to start the match
        duel.joinMatch(1);

        _checkMatchInfo(
            1, playerA, playerB, address(0), buyIn, duration, block.timestamp + duration, IHyperDuel.MatchStatus.ONGOING
        );
    }

    function test_ConcludeMatchInTie() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        vm.startPrank(playerA);
        // create match
        duel.createMatch(playerA, address(0), tokensAllowed, buyIn, duration);

        vm.startPrank(playerB);
        // playerB joins to start the match
        duel.joinMatch(1);

        uint256 startTs = block.timestamp;
        vm.warp(startTs + duration + 1);

        duel.concludeMatch(1);

        _checkMatchInfo(
            1, playerA, playerB, address(0), buyIn, duration, startTs + duration, IHyperDuel.MatchStatus.FINISHED
        );
    }

    function test_ConcludeMatchWithWinner() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        vm.prank(playerA);
        // create match
        duel.createMatch(playerA, address(0), tokensAllowed, buyIn, duration);

        vm.prank(playerB);
        // playerB joins to start the match
        duel.joinMatch(1);

        // simulate buy, swap USDC to BTC
        uint32[] memory tokensIn = new uint32[](1);
        tokensIn[0] = 0;
        uint32[] memory tokensOut = new uint32[](1);
        tokensOut[0] = tokensSpotIndex[0]; // BTC
        uint256[] memory amountsIn = new uint256[](1);
        amountsIn[0] = 50_000e18;
        vm.prank(playerA);
        duel.swap(1, tokensIn, tokensOut, amountsIn);

        assertEq(duel.matchBalances(playerA, 1, 0), amountsIn[0]);
        assertGt(duel.matchBalances(playerA, 1, tokensSpotIndex[0]), 0);

        uint256 length = tokensSpotIndex.length;
        for (uint256 i = 1; i < length; ++i) {
            assertEq(duel.matchBalances(playerA, 1, tokensSpotIndex[i]), 0);
        }

        uint256 startTs = block.timestamp;
        vm.warp(startTs + duration + 1);

        uint256 playerABalanceBefore = buyInToken.balanceOf(playerA);
        uint256 playerBBalanceBefore = buyInToken.balanceOf(playerB);
        duel.concludeMatch(1);

        assertEq(playerABalanceBefore, buyInToken.balanceOf(playerA));
        assertLt(playerBBalanceBefore, buyInToken.balanceOf(playerB));

        _checkMatchInfo(
            1, playerA, playerB, playerB, buyIn, duration, startTs + duration, IHyperDuel.MatchStatus.FINISHED
        );

        // Check fee
        assertGt(buyInToken.balanceOf(address(duel)), 0);
        duel.withdrawPlatformFee(address(this));
        assertEq(buyInToken.balanceOf(address(duel)), 0);
    }

    function test_DisableTokenNotAffectOngoingMatch() public {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        vm.prank(playerA);
        // create match
        duel.createMatch(playerA, address(0), tokensAllowed, buyIn, duration);

        vm.prank(playerB);
        // playerB joins to start the match
        duel.joinMatch(1);

        // disable a token
        duel.disableTradingToken(tokensSpotIndex[0]);

        // simulate buy, swap usd to tokens disabled in next matches
        uint32[] memory tokensIn = new uint32[](1);
        tokensIn[0] = 0;
        uint32[] memory tokensOut = new uint32[](1);
        tokensOut[0] = tokensSpotIndex[0]; // BTC
        uint256[] memory amountsIn = new uint256[](1);
        amountsIn[0] = 50_000e18;
        vm.prank(playerA);
        duel.swap(1, tokensIn, tokensOut, amountsIn);
    }

    function _getDefaultMatchData()
        internal
        view
        returns (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed)
    {
        buyIn = 10e6;
        duration = 1 days;

        uint256 length = tokensSpotIndex.length;
        tokensAllowed = new uint32[](length);
        for (uint256 i; i < length; ++i) {
            tokensAllowed[i] = tokensSpotIndex[i];
        }
    }

    function _checkMatchInfo(
        uint256 matchId,
        address _playerA,
        address _playerB,
        address winner,
        uint256 buyIn,
        uint256 duration,
        uint256 endTs,
        IHyperDuel.MatchStatus status
    ) internal view {
        IHyperDuel.MatchInfo memory matchInfo = IHyperDuel(address(duel)).matches(matchId);
        assertEq(matchInfo.playerA, _playerA);
        assertEq(matchInfo.playerB, _playerB);
        assertEq(matchInfo.winner, winner);
        assertEq(matchInfo.buyIn, buyIn);
        assertEq(matchInfo.duration, duration);
        assertEq(matchInfo.endTime, endTs);
        assertEq(uint8(matchInfo.status), uint8(status));
    }

    function _mockPrecompiles() internal {
        for (uint160 i = 0; i < 17; i++) {
            address precompileAddress = address(uint160(0x0000000000000000000000000000000000000800) + i);
            vm.etch(precompileAddress, type(MockPrecompileLive).runtimeCode);
            vm.allowCheatcodes(precompileAddress);
        }

        // Owerwrite precompiles required to change
        // vm.etch(0x0000000000000000000000000000000000000808, type(MockSpotPx).runtimeCode);
        // spotPxPrecompile = MockSpotPx(0x0000000000000000000000000000000000000808);
    }
}

address constant BUY_IN_TOKEN_MAINNET = 0xb88339CB7199b77E23DB6E890353E22632Ba630f; // USDC
address constant BUY_IN_TOKEN_TESTNET = 0x2B3370eE501B4a559b57D449569354196457D8Ab; // USDC

// hyperliquid mainnet indexes
// UBTC -> tokenIndex 197, spot index 142, decimals 3
// UETH -> tokenIndex 221, spot index 151, decimals 4
// USOL -> tokenIndex 254, spot index 156, decimals 5
contract HyperDuelTestMainnet is
    HyperDuelTest(
        "hl_mainnet",
        BUY_IN_TOKEN_MAINNET,
        [uint32(197), uint32(221), uint32(254)],
        [uint32(142), uint32(151), uint32(156)],
        [3, 4, 5],
        ["UBTC", "UETH", "USOL"]
    )
{}

// HYPE -> tokenIndex 1105, spot index 1035, decimals 6
// UETH -> tokenIndex 1242, spot index 1137, decimals 4
// HORSE -> tokenIndex 1435, spot index 1319, decimals 6
contract HyperDuelTestTestnet is
    HyperDuelTest(
        "hl_testnet",
        BUY_IN_TOKEN_TESTNET,
        [uint32(1105), uint32(1242), uint32(1435)],
        [uint32(1035), uint32(1137), uint32(1319)],
        [6, 4, 6],
        ["HYPE", "UETH", "HORSE"]
    )
{}

