// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {MockSpotPx} from "./mocks/MockSpotPx.sol";

import {HyperDuel} from "src/HyperDuel.sol";
import {IHyperDuel} from "./IHyperDuel.sol";

contract HyperDuelTest is Test {
    MockSpotPx internal spotPxPrecompile;
    HyperDuel internal duel;

    IERC20 internal buyInToken = IERC20(0xb88339CB7199b77E23DB6E890353E22632Ba630f); // USDC hl testnet
    address internal feeRecipient = address(0xBEEF);
    address internal playerA = address(0xABCD);
    address internal playerB = address(0xABBB);
    uint256 platformFee;
    uint32 btcIndex = 142;
    uint32 ethIndex = 151;
    uint32 solIndex = 156;

    function setUp() public {
        vm.createSelectFork("hl_mainnet");

        // deploy duel contract
        duel = new HyperDuel(address(buyInToken), platformFee, feeRecipient);

        // enable token
        // BTC
        duel.toggleTradingToken(btcIndex, 3);
        // ETH
        duel.toggleTradingToken(ethIndex, 4);
        // SOL
        duel.toggleTradingToken(solIndex, 5);

        deal(address(buyInToken), playerA, 100e6);
        deal(address(buyInToken), playerB, 100e6);

        vm.prank(playerA);
        buyInToken.approve(address(duel), 100e6);
        vm.prank(playerB);
        buyInToken.approve(address(duel), 100e6);

        spotPxPrecompile = new MockSpotPx();
        vm.etch(0x0000000000000000000000000000000000000808, address(spotPxPrecompile).code);
        spotPxPrecompile = MockSpotPx(0x0000000000000000000000000000000000000808);

        spotPxPrecompile.setSpotPx(btcIndex, 70000000); // 70K, 3 decimals
        spotPxPrecompile.setSpotPx(ethIndex, 30000000); // 3K, 4 decimals
        spotPxPrecompile.setSpotPx(solIndex, 10000000); // 100, 5 decimals
    }

    function test_deploy() public view {
        assertEq(duel.platformFee(), platformFee);
    }

    function test_createMatchWithoutJoin() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        duel.createMatch(address(0), address(0), tokensAllowed, buyIn, duration);

        uint32[] memory matchTokensAllowed = duel.getMatchTokensAllowed(1);
        assertEq(matchTokensAllowed.length, 3);
        assertEq(matchTokensAllowed[0], tokensAllowed[0]);
        assertEq(matchTokensAllowed[1], tokensAllowed[1]);
        assertEq(matchTokensAllowed[2], tokensAllowed[2]);

        _checkMatchInfo(1, address(0), address(0), address(0), buyIn, duration, 0, IHyperDuel.MatchStatus.TO_START);
    }

    function test_createMatchAndJoin() external {
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

    function test_createMatchReserved() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        vm.prank(playerA);
        duel.createMatch(playerA, playerB, tokensAllowed, buyIn, duration);

        _checkMatchInfo(1, playerA, playerB, address(0), buyIn, duration, 0, IHyperDuel.MatchStatus.TO_START);
    }

    function test_unjoinMatch() external {
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

    function test_startMatch() external {
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

    function test_concludeMatchInTie() external {
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

    function test_concludeMatchWithWinner() external {
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
        tokensOut[0] = 142; // BTC
        uint256[] memory amountsIn = new uint256[](1);
        amountsIn[0] = 50_000e18;
        vm.prank(playerA);
        duel.swap(1, tokensIn, tokensOut, amountsIn);

        assertEq(duel.matchBalances(playerA, 1, 0), amountsIn[0]);
        assertGt(duel.matchBalances(playerA, 1, btcIndex), 0);
        assertEq(duel.matchBalances(playerA, 1, ethIndex), 0);
        assertEq(duel.matchBalances(playerA, 1, solIndex), 0);

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
    }

    function _getDefaultMatchData()
        internal
        view
        returns (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed)
    {
        buyIn = 10e6;
        duration = 1 days;
        tokensAllowed = new uint32[](3);
        tokensAllowed[0] = btcIndex;
        tokensAllowed[1] = ethIndex;
        tokensAllowed[2] = solIndex;
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
}
