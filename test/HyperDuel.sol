// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {HyperDuel} from "src/HyperDuel.sol";

contract HyperDuelTest is Test {
    HyperDuel internal duel;

    address internal buyInToken = 0xb88339CB7199b77E23DB6E890353E22632Ba630f; // USDC hl testnet
    address internal feeRecipient = address(0xBEEF);
    address internal player1 = address(0xABCD);
    address internal player2 = address(0xABBB);
    uint256 platformFee;

    function setUp() public {
        vm.createSelectFork("hl_mainnet");

        // deploy duel contract
        duel = new HyperDuel(buyInToken, platformFee, feeRecipient);

        // enable token
        duel.toggleTradingToken(1, 6);
        duel.toggleTradingToken(2, 6);

        deal(buyInToken, player1, 100e6);
    }

    function test_deploy() public {
        assertEq(duel.platformFee(), platformFee);
    }

    function test_createMatch() public {
        uint256 buyIn = 10e6;
        uint256 duration = 1 days;
        vm.prank(player1);
        uint32[] memory tokensAllowed = new uint32[](2);
        tokensAllowed[0] = 1;
        tokensAllowed[1] = 2;
        duel.createMatch(tokensAllowed, buyIn, duration);
        uint32[] memory matchTokensAllowed = duel.getMatchTokensAllowed(1);
        assertEq(matchTokensAllowed.length, 2);
        assertEq(matchTokensAllowed[0], tokensAllowed[0]);
        assertEq(matchTokensAllowed[1], tokensAllowed[1]);
        //assertEq(matchInfo.buyIn, buyIn);
    }
}
