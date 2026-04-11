// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";

import {HyperDuel} from "src/HyperDuel.sol";
import {IHyperDuel} from "./IHyperDuel.sol";

contract HyperDuelTest is Test {
    HyperDuel internal duel;

    address internal buyInToken = 0xb88339CB7199b77E23DB6E890353E22632Ba630f; // USDC hl testnet
    address internal feeRecipient = address(0xBEEF);
    address internal playerA = address(0xABCD);
    address internal playerB = address(0xABBB);
    uint256 platformFee;

    function setUp() public {
        vm.createSelectFork("hl_mainnet");

        // deploy duel contract
        duel = new HyperDuel(buyInToken, platformFee, feeRecipient);

        // enable token
        duel.toggleTradingToken(1, 6);
        duel.toggleTradingToken(2, 6);

        deal(buyInToken, playerA, 100e6);
        deal(buyInToken, playerB, 100e6);

        vm.prank(playerA);
        IERC20(buyInToken).approve(address(duel), 100e6);
    }

    function test_deploy() public {
        assertEq(duel.platformFee(), platformFee);
    }

    function test_createMatchWithoutJoin() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        duel.createMatch(address(0), address(0), tokensAllowed, buyIn, duration);

        uint32[] memory matchTokensAllowed = duel.getMatchTokensAllowed(1);
        assertEq(matchTokensAllowed.length, 2);
        assertEq(matchTokensAllowed[0], tokensAllowed[0]);
        assertEq(matchTokensAllowed[1], tokensAllowed[1]);

        _checkMatchInfo(1, address(0), address(0), address(0), buyIn, duration, 0);
    }

    function test_createMatchAndJoin() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        uint256 balanceBefore = IERC20(buyInToken).balanceOf(playerA);
        vm.prank(playerA);
        duel.createMatch(playerA, address(0), tokensAllowed, buyIn, duration);
        uint256 balanceAfter = IERC20(buyInToken).balanceOf(playerA);
        uint256 duelBalance = IERC20(buyInToken).balanceOf(address(duel));
        assertEq(balanceBefore - balanceAfter, buyIn);
        assertEq(duelBalance, buyIn);

        _checkMatchInfo(1, playerA, address(0), address(0), buyIn, duration, 0);
    }

    function test_createMatchReserved() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        vm.prank(playerA);
        duel.createMatch(playerA, playerB, tokensAllowed, buyIn, duration);

        _checkMatchInfo(1, playerA, playerB, address(0), buyIn, duration, 0);
    }

    function test_removeMatch() external {
        (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed) = _getDefaultMatchData();

        uint256 initBalance = IERC20(buyInToken).balanceOf(playerA);
        vm.startPrank(playerA);
        // create match
        duel.createMatch(playerA, address(0), tokensAllowed, buyIn, duration);

        // remove match
        duel.removeMatch(1);
        vm.stopPrank();
        uint256 finalBalance = IERC20(buyInToken).balanceOf(playerA);
        assertEq(initBalance, finalBalance);
    }

    function _getDefaultMatchData()
        internal
        view
        returns (uint256 buyIn, uint256 duration, uint32[] memory tokensAllowed)
    {
        buyIn = 10e6;
        duration = 1 days;
        tokensAllowed = new uint32[](2);
        tokensAllowed[0] = 1;
        tokensAllowed[1] = 2;
    }

    function _checkMatchInfo(
        uint256 matchId,
        address playerA,
        address playerB,
        address winner,
        uint256 buyIn,
        uint256 duration,
        uint256 endTs
    ) internal {
        IHyperDuel.MatchInfo memory matchInfo = IHyperDuel(address(duel)).matches(matchId);
        assertEq(matchInfo.playerA, playerA);
        assertEq(matchInfo.playerB, playerB);
        assertEq(matchInfo.winner, winner);
        assertEq(matchInfo.buyIn, buyIn);
        assertEq(matchInfo.duration, duration);
        assertEq(matchInfo.endTime, endTs);
    }
}
