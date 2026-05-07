// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import "./mocks/MockChallenge.sol";
import {MockUSDC} from "./mocks/MockUsdc.sol";

contract ChallengeUnitTest is Test {
    MockUSDC internal usdc = new MockUSDC();
    MockChallenge internal challenge;

    address internal creator = address(0xABBB);
    address internal player = address(0xABCD);
    address internal feeRecipient = address(0xABBD);

    uint256 internal immutable buyIn = 10 * 10 ** usdc.decimals();
    uint256 internal immutable prize = 20 * 10 ** usdc.decimals();
    uint256 internal constant TARGET = 110_000e18;
    uint256 internal constant DURATION = 1 days;
    uint256 internal constant EXPIRY_DURATION = 3 days;
    uint256 internal constant JOIN_FEE = 50; // 0.5%

    uint32 internal constant TOKEN_1 = 1;
    uint32 internal constant TOKEN_2 = 2;

    function setUp() public {
        challenge = new MockChallenge(address(usdc), JOIN_FEE);

        challenge.setToken(TOKEN_1, 3, 100_000e3);
        challenge.setToken(TOKEN_2, 4, 1_000e4);

        uint256 amountToMint = 1000 * 10 ** usdc.decimals();
        usdc.mint(creator, amountToMint);
        usdc.mint(player, amountToMint);

        vm.prank(creator);
        usdc.approve(address(challenge), amountToMint);

        vm.prank(player);
        usdc.approve(address(challenge), amountToMint);
    }

    function test_CreateChallenge() external {
        uint32[] memory tokens = _defaultTokens();

        vm.prank(creator);
        challenge.createChallenge(tokens, buyIn, prize, DURATION, EXPIRY_DURATION, TARGET);

        (
            address cCreator,
            address cPlayer,
            address cWinner,
            uint256 cBuyIn,
            uint256 cPrize,
            uint256 cDuration,
            uint256 cEndTime,
            uint256 cExpiry,
            uint256 cTargetAmount,
            Challenge.ChallengeStatus cStatus
        ) = challenge.challenges(1);

        assertEq(cCreator, creator);
        assertEq(cPlayer, address(0));
        assertEq(cWinner, address(0));
        assertEq(cBuyIn, buyIn);
        assertEq(cPrize, prize);
        assertEq(cDuration, DURATION);
        assertEq(cEndTime, 0);
        assertEq(cExpiry, block.timestamp + EXPIRY_DURATION);
        assertEq(cTargetAmount, TARGET);
        assertEq(uint256(cStatus), uint256(Challenge.ChallengeStatus.TO_START));

        assertEq(challenge.challengeId(), 1);
        assertEq(usdc.balanceOf(address(challenge)), prize);

        uint32[] memory allowed = challenge.getChallengeTokensAllowed(1);
        assertEq(allowed.length, 2);
        assertEq(allowed[0], TOKEN_1);
        assertEq(allowed[1], TOKEN_2);
    }

    function test_JoinChallenge() external {
        _createDefaultChallenge();

        uint256 creatorBalanceBefore = usdc.balanceOf(creator);
        uint256 playerBalanceBefore = usdc.balanceOf(player);

        vm.prank(player);
        challenge.joinChallenge(1);

        (address cCreator, address cPlayer, address cWinner,,,, uint256 cEndTime,,, Challenge.ChallengeStatus cStatus) =
            challenge.challenges(1);

        assertEq(cCreator, creator);
        assertEq(cPlayer, player);
        assertEq(cWinner, address(0));
        assertEq(cEndTime, block.timestamp + DURATION);
        assertEq(uint256(cStatus), uint256(Challenge.ChallengeStatus.ONGOING));

        uint256 joinFee = buyIn * challenge.platformFeePercentage() / challenge.BASE_FEE();

        assertEq(usdc.balanceOf(creator), creatorBalanceBefore + buyIn - joinFee);
        assertEq(usdc.balanceOf(player), playerBalanceBefore - buyIn);
        assertEq(usdc.balanceOf(address(challenge)), prize + joinFee);

        assertEq(challenge.accruedPlatformFee(), joinFee);
        // player, match id 1, asset 0 vUSD
        assertEq(challenge.challengeBalances(player, 1, 0), challenge.INITIAL_VIRTUAL_USD());
    }

    function test_RemoveChallengeAfterExpiry() external {
        _createDefaultChallenge();

        vm.warp(block.timestamp + EXPIRY_DURATION + 1);

        uint256 creatorBalanceBefore = usdc.balanceOf(creator);

        vm.prank(creator);
        challenge.removeChallenge(1);

        (,,,,,,,,, Challenge.ChallengeStatus cStatus) = challenge.challenges(1);
        assertEq(uint256(cStatus), uint256(Challenge.ChallengeStatus.REMOVED));

        assertEq(usdc.balanceOf(creator), creatorBalanceBefore + prize);
    }

    function test_RevertRemoveChallengBeforeExpiry() external {
        _createDefaultChallenge();

        vm.expectRevert(Challenge.ChallengeNotExpired.selector);
        vm.prank(creator);
        challenge.removeChallenge(1);
    }

    function test_SwapUsdToToken() external {
        _createAndStartDefaultChallenge();

        uint256 amountIn = 50_000e18;

        vm.prank(player);
        challenge.swap(1, 0, TOKEN_1, amountIn);

        // vUSD
        assertEq(challenge.challengeBalances(player, 1, 0), challenge.INITIAL_VIRTUAL_USD() - amountIn);
        // TOKEN_1
        uint256 amountOut = amountIn * 10 ** challenge.tradingTokensDecimals(TOKEN_1) / challenge.tokenPx(TOKEN_1);
        uint256 platformFee = amountOut * challenge.GAME_TRADER_FEE() / challenge.BASE_FEE();
        assertEq(challenge.challengeBalances(player, 1, TOKEN_1), amountOut - platformFee);
    }

    function test_ConcludeChallengePlayerWin() external {
        _createAndStartDefaultChallenge();

        uint256 amountIn = 50_000e18;

        vm.prank(player);
        challenge.swap(1, 0, TOKEN_1, amountIn);

        // pump TOKEN_1
        challenge.setPrice(TOKEN_1, uint64(200_000e3));

        vm.warp(block.timestamp + DURATION + 1);

        uint256 creatorBalanceBefore = usdc.balanceOf(creator);
        uint256 playerBalanceBefore = usdc.balanceOf(player);
        uint256 challengeBalanceBefore = usdc.balanceOf(address(challenge));
        uint256 accruedFeeBefore = challenge.accruedPlatformFee();

        challenge.concludeChallenge(1);

        (,, address cWinner,, uint256 cPrize,,,,, Challenge.ChallengeStatus cStatus) = challenge.challenges(1);

        uint256 prizeFee = prize * challenge.platformFeePercentage() / challenge.BASE_FEE();

        assertEq(cWinner, player);
        assertEq(uint256(cStatus), uint256(Challenge.ChallengeStatus.FINISHED));
        assertEq(usdc.balanceOf(player), playerBalanceBefore + prize - prizeFee);
        assertEq(usdc.balanceOf(creator), creatorBalanceBefore);
        assertEq(usdc.balanceOf(address(challenge)), challengeBalanceBefore - (prize - prizeFee));
        assertEq(challenge.accruedPlatformFee(), accruedFeeBefore + prizeFee);
    }

    function test_ConcludeChallenge_CreatorWins() public {
        _createAndStartDefaultChallenge();

        vm.warp(block.timestamp + DURATION + 1);

        uint256 creatorBalanceBefore = usdc.balanceOf(creator);

        challenge.concludeChallenge(1);

        (,, address cWinner,, uint256 cPrize,,,,, Challenge.ChallengeStatus cStatus) = challenge.challenges(1);

        uint256 prizeFee = prize * challenge.platformFeePercentage() / challenge.BASE_FEE();

        assertEq(cWinner, creator);
        assertEq(uint256(cStatus), uint256(Challenge.ChallengeStatus.FINISHED));
        assertEq(usdc.balanceOf(creator), creatorBalanceBefore + prize - prizeFee);
    }

    function test_WithdrawPlatformFee() public {
        _createAndStartDefaultChallenge();

        vm.warp(block.timestamp + DURATION + 1);
        challenge.concludeChallenge(1);

        uint256 accrued = challenge.accruedPlatformFee();
        assertGt(accrued, 0);

        uint256 feeRecipientBalanceBefore = usdc.balanceOf(feeRecipient);

        challenge.withdrawPlatformFee(feeRecipient);

        assertEq(usdc.balanceOf(feeRecipient), feeRecipientBalanceBefore + accrued);
        assertEq(challenge.accruedPlatformFee(), 0);
    }

    function _createDefaultChallenge() internal {
        uint32[] memory tokens = _defaultTokens();

        vm.prank(creator);
        challenge.createChallenge(tokens, buyIn, prize, DURATION, EXPIRY_DURATION, TARGET);
    }

    function _createAndStartDefaultChallenge() internal {
        _createDefaultChallenge();

        vm.prank(player);
        challenge.joinChallenge(1);
    }

    function _defaultTokens() internal pure returns (uint32[] memory tokens) {
        tokens = new uint32[](2);
        tokens[0] = TOKEN_1;
        tokens[1] = TOKEN_2;
    }
}
