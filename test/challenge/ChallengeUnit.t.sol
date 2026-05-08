// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";
import "../mocks/MockChallenge.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";

contract ChallengeUnit is Test {
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
    uint256 internal constant PLATFORM_FEE = 50; // 0.5%

    uint32 internal constant TOKEN_1 = 1;
    uint32 internal constant TOKEN_2 = 2;
    uint32 internal constant TOKEN_3 = 3; // not enabled

    function setUp() public {
        challenge = new MockChallenge(address(usdc), PLATFORM_FEE);

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

    function test_RevertCreateChallengeZeroToken() external {
        uint32[] memory tokens;

        vm.expectRevert(Challenge.ZeroToken.selector);
        challenge.createChallenge(tokens, buyIn, prize, DURATION, EXPIRY_DURATION, TARGET);
    }

    function test_RevertCreateChallengeWrongBuyIn() external {
        uint32[] memory tokens = _defaultTokens();

        // buyIn=0
        vm.expectRevert(Challenge.WrongBuyIn.selector);
        challenge.createChallenge(tokens, 0, prize, DURATION, EXPIRY_DURATION, TARGET);

        // buyIn < minBuyIn
        uint256 minBuyIn = challenge.minBuyIn();
        vm.expectRevert(Challenge.WrongBuyIn.selector);
        challenge.createChallenge(tokens, minBuyIn - 1, prize, DURATION, EXPIRY_DURATION, TARGET);

        // buyIn > maxBuyIn
        uint256 maxBuyIn = challenge.maxBuyIn();
        vm.expectRevert(Challenge.WrongBuyIn.selector);
        challenge.createChallenge(tokens, maxBuyIn + 1, prize, DURATION, EXPIRY_DURATION, TARGET);
    }

    function test_RevertCreateChallengeWrongPrize() external {
        uint32[] memory tokens = _defaultTokens();

        // prize=0
        vm.expectRevert(Challenge.WrongPrize.selector);
        challenge.createChallenge(tokens, buyIn, 0, DURATION, EXPIRY_DURATION, TARGET);

        // prize < buyIn
        vm.expectRevert(Challenge.WrongPrize.selector);
        challenge.createChallenge(tokens, buyIn, buyIn - 1, DURATION, EXPIRY_DURATION, TARGET);
    }

    function test_RevertCreateChallengeWrongDuration() external {
        uint32[] memory tokens = _defaultTokens();

        // duration=0
        vm.expectRevert(Challenge.WrongDuration.selector);
        challenge.createChallenge(tokens, buyIn, prize, 0, EXPIRY_DURATION, TARGET);

        // duration < minDuration
        uint256 minDuration = challenge.minDuration();
        vm.expectRevert(Challenge.WrongDuration.selector);
        challenge.createChallenge(tokens, buyIn, prize, minDuration - 1, EXPIRY_DURATION, TARGET);

        // duration > maxDuration
        uint256 maxDuration = challenge.maxDuration();
        vm.expectRevert(Challenge.WrongDuration.selector);
        challenge.createChallenge(tokens, buyIn, prize, maxDuration + 1, EXPIRY_DURATION, TARGET);
    }

    function test_RevertCreateChallengeWrongExpiry() external {
        uint32[] memory tokens = _defaultTokens();

        // expiry=0
        vm.expectRevert(Challenge.WrongExpiry.selector);
        challenge.createChallenge(tokens, buyIn, prize, DURATION, 0, TARGET);

        // expiry > max expiry
        uint256 maxExpiry = challenge.MAX_EXPIRY_DURATION();
        vm.expectRevert(Challenge.WrongExpiry.selector);
        challenge.createChallenge(tokens, buyIn, prize, DURATION, maxExpiry + 1, TARGET);
    }

    function test_RevertCreateChallengeWrongTargetAmount() external {
        uint32[] memory tokens = _defaultTokens();

        // target amount <= initial virtual usd ()
        uint256 initialVirtualUsd = challenge.INITIAL_VIRTUAL_USD();
        vm.expectRevert(Challenge.WrongTargetAmount.selector);
        challenge.createChallenge(tokens, buyIn, prize, DURATION, EXPIRY_DURATION, initialVirtualUsd);
    }

    function test_RevertCreateChallengeTokenNotEnabled() external {
        uint32[] memory tokens = new uint32[](2);
        tokens[0] = TOKEN_1;
        tokens[1] = TOKEN_3;

        vm.expectRevert(Challenge.TokenNotEnabled.selector);
        challenge.createChallenge(tokens, buyIn, prize, DURATION, EXPIRY_DURATION, TARGET);
    }

    function test_RevertCreateChallengeTokenAlreadyEnabled() external {
        uint32[] memory tokens = new uint32[](2);
        tokens[0] = TOKEN_1;
        tokens[1] = TOKEN_1;

        vm.expectRevert(Challenge.TokenAlreadyEnabled.selector);
        challenge.createChallenge(tokens, buyIn, prize, DURATION, EXPIRY_DURATION, TARGET);
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

    function test_RevertJoinChallengeWrongId() external {
        _createDefaultChallenge();

        vm.expectRevert(Challenge.WrongId.selector);
        challenge.joinChallenge(2);
    }

    function test_RevertJoinChallengeExpired() external {
        _createDefaultChallenge();

        vm.warp(block.timestamp + EXPIRY_DURATION);

        vm.expectRevert(Challenge.ChallengeExpired.selector);
        challenge.joinChallenge(1);
    }

    function test_RevertJoinChallengeNotToStartChallenge() external {
        _createAndStartDefaultChallenge();

        vm.expectRevert(Challenge.NotToStartChallenge.selector);
        challenge.joinChallenge(1);
    }

    function test_RevertJoinChallengeCreator() external {
        _createDefaultChallenge();

        vm.prank(creator);
        vm.expectRevert(Challenge.ChallengeCreator.selector);
        challenge.joinChallenge(1);
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

    function test_RevertRemoveChallengeNotAllowed() external {
        _createDefaultChallenge();

        vm.expectRevert(Challenge.NotAllowed.selector);
        challenge.removeChallenge(1);
    }

    function test_RevertRemoveChallengeNotToStart() external {
        _createAndStartDefaultChallenge();

        vm.prank(creator);
        vm.expectRevert(Challenge.NotToStartChallenge.selector);
        challenge.removeChallenge(1);
    }

    function test_RevertRemoveChallengNotExpired() external {
        _createDefaultChallenge();

        vm.expectRevert(Challenge.ChallengeNotExpired.selector);
        vm.prank(creator);
        challenge.removeChallenge(1);
    }

    function test_SingleSwapUsdToToken() external {
        _createAndStartDefaultChallenge();

        uint256 amountIn = 50_000e18;

        vm.prank(player);
        // vUSD -> TOKEN_1
        challenge.swap(1, 0, TOKEN_1, amountIn);

        // vUSD
        assertEq(challenge.challengeBalances(player, 1, 0), challenge.INITIAL_VIRTUAL_USD() - amountIn);

        // TOKEN_1
        uint256 amountOut = amountIn * 10 ** challenge.tradingTokensDecimals(TOKEN_1) / challenge.tokenPx(TOKEN_1);
        uint256 platformFee = amountOut * challenge.GAME_TRADER_FEE() / challenge.BASE_FEE();
        assertEq(challenge.challengeBalances(player, 1, TOKEN_1), amountOut - platformFee);
    }

    function test_SingleSwapTokenToUsd() external {
        _createAndStartDefaultChallenge();

        uint256 amountIn = 50_000e18;

        vm.prank(player);
        // vUSD -> TOKEN_1
        challenge.swap(1, 0, TOKEN_1, amountIn);

        uint256 vUsdBalanceBefore = challenge.challengeBalances(player, 1, 0);

        amountIn = challenge.challengeBalances(player, 1, TOKEN_1);

        vm.prank(player);
        // TOKEN_1 -> vUSD
        challenge.swap(1, TOKEN_1, 0, amountIn);

        uint256 usdIn =
            amountIn * uint256(challenge.tokenPx(TOKEN_1)) / (10 ** challenge.challengeTokensDecimals(1, TOKEN_1));
        uint256 platformFee = usdIn * challenge.GAME_TRADER_FEE() / challenge.BASE_FEE();

        assertEq(challenge.challengeBalances(player, 1, 0), vUsdBalanceBefore + usdIn - platformFee);
    }

    function test_SingleSwapTokenToToken() external {
        _createAndStartDefaultChallenge();

        uint256 amountIn = 50_000e18;

        vm.prank(player);
        // vUSD -> TOKEN_1
        challenge.swap(1, 0, TOKEN_1, amountIn);

        uint256 vUsdBalanceBefore = challenge.challengeBalances(player, 1, 0);

        amountIn = challenge.challengeBalances(player, 1, TOKEN_1);

        vm.prank(player);
        // TOKEN_1 -> TOKEN_2
        challenge.swap(1, TOKEN_1, TOKEN_2, amountIn);

        uint256 usdIn =
            amountIn * uint256(challenge.tokenPx(TOKEN_1)) / (10 ** challenge.challengeTokensDecimals(1, TOKEN_1));
        uint256 platformFee = usdIn * challenge.GAME_TRADER_FEE() / challenge.BASE_FEE();

        usdIn -= platformFee;

        uint256 amountOut =
            usdIn * (10 ** challenge.challengeTokensDecimals(1, TOKEN_2)) / uint256(challenge.tokenPx(TOKEN_2));

        assertEq(challenge.challengeBalances(player, 1, 0), vUsdBalanceBefore);
        assertEq(challenge.challengeBalances(player, 1, TOKEN_1), 0);
        assertEq(challenge.challengeBalances(player, 1, TOKEN_2), amountOut);
    }

    function test_MultiSwap() external {
        _createAndStartDefaultChallenge();

        uint256[] memory amountsIn = new uint256[](2);
        amountsIn[0] = 50_000e18;
        amountsIn[1] = 50_000e18;

        uint32[] memory tokensIn = new uint32[](2);
        tokensIn[0] = 0;
        tokensIn[1] = 0;

        uint32[] memory tokensOut = new uint32[](2);
        tokensOut[0] = TOKEN_1;
        tokensOut[1] = TOKEN_2;

        vm.prank(player);
        // vUSD -> TOKEN_1
        // vUSD -> TOKEN_2
        challenge.swap(1, tokensIn, tokensOut, amountsIn);

        // vUSD -> zero left
        assertEq(challenge.challengeBalances(player, 1, 0), 0);

        // TOKEN_1
        uint256 amountOut = amountsIn[0] * 10 ** challenge.tradingTokensDecimals(TOKEN_1) / challenge.tokenPx(TOKEN_1);
        uint256 platformFee = amountOut * challenge.GAME_TRADER_FEE() / challenge.BASE_FEE();
        assertEq(challenge.challengeBalances(player, 1, TOKEN_1), amountOut - platformFee);

        // TOKEN_1
        amountOut = amountsIn[1] * 10 ** challenge.tradingTokensDecimals(TOKEN_2) / challenge.tokenPx(TOKEN_2);
        platformFee = amountOut * challenge.GAME_TRADER_FEE() / challenge.BASE_FEE();
        assertEq(challenge.challengeBalances(player, 1, TOKEN_2), amountOut - platformFee);
    }

    function test_RevertSwapOnlyPlayer() external {
        _createAndStartDefaultChallenge();

        uint256 amountIn = 50_000e18;

        vm.expectRevert(Challenge.OnlyPlayer.selector);
        challenge.swap(1, 0, TOKEN_1, amountIn);
    }

    function test_RevertSwapNotOngoingChallenge() external {
        _createAndStartDefaultChallenge();

        vm.warp(block.timestamp + DURATION);

        uint256 amountIn = 50_000e18;

        vm.expectRevert(Challenge.NotOngoingChallenge.selector);
        vm.prank(player);
        challenge.swap(1, 0, TOKEN_1, amountIn);
    }

    function test_RevertSwapZeroAmount() external {
        _createAndStartDefaultChallenge();

        vm.expectRevert(Challenge.ZeroAmount.selector);
        vm.prank(player);
        challenge.swap(1, 0, TOKEN_1, 0);
    }

    function test_RevertSwapSameToken() external {
        _createAndStartDefaultChallenge();

        uint256 amountIn = 50_000e18;

        vm.expectRevert(Challenge.SameToken.selector);
        vm.prank(player);
        challenge.swap(1, 0, 0, amountIn);
    }

    function test_RevertSwapTokenNotEnabled() external {
        _createAndStartDefaultChallenge();

        uint256 amountIn = 50_000e18;

        vm.expectRevert(Challenge.TokenNotEnabled.selector);
        vm.prank(player);
        challenge.swap(1, 0, TOKEN_3, amountIn);

        vm.expectRevert(Challenge.TokenNotEnabled.selector);
        vm.prank(player);
        challenge.swap(1, TOKEN_3, 0, amountIn);
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

        uint256 prizeFee = cPrize * challenge.platformFeePercentage() / challenge.BASE_FEE();

        assertEq(cWinner, player);
        assertEq(uint256(cStatus), uint256(Challenge.ChallengeStatus.FINISHED));
        assertEq(usdc.balanceOf(player), playerBalanceBefore + cPrize - prizeFee);
        assertEq(usdc.balanceOf(creator), creatorBalanceBefore);
        assertEq(usdc.balanceOf(address(challenge)), challengeBalanceBefore - (cPrize - prizeFee));
        assertEq(challenge.accruedPlatformFee(), accruedFeeBefore + prizeFee);
    }

    function test_ConcludeChallengeCreatorWins() external {
        _createAndStartDefaultChallenge();

        vm.warp(block.timestamp + DURATION + 1);

        uint256 creatorBalanceBefore = usdc.balanceOf(creator);

        challenge.concludeChallenge(1);

        (,, address cWinner,, uint256 cPrize,,,,, Challenge.ChallengeStatus cStatus) = challenge.challenges(1);

        uint256 prizeFee = cPrize * challenge.platformFeePercentage() / challenge.BASE_FEE();

        assertEq(cWinner, creator);
        assertEq(uint256(cStatus), uint256(Challenge.ChallengeStatus.FINISHED));
        assertEq(usdc.balanceOf(creator), creatorBalanceBefore + cPrize - prizeFee);
    }

    function test_RevertConcludeNotOngoingChallenge() external {
        _createDefaultChallenge();

        vm.expectRevert(Challenge.NotOngoingChallenge.selector);
        challenge.concludeChallenge(1);
    }

    function test_RevertConcludeOngoingChallenge() external {
        _createAndStartDefaultChallenge();

        vm.expectRevert(Challenge.OngoingChallenge.selector);
        challenge.concludeChallenge(1);
    }

    function test_WithdrawPlatformFee() external {
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

    function test_RevertWithdrawPlatformFeeZeroAddress() external {
        vm.expectRevert(Challenge.ZeroAddress.selector);
        challenge.withdrawPlatformFee(address(0));
    }

    function test_RevertEnableTradingTokenAlreadyEnabled() external {
        // test it via the mocked function
        vm.expectRevert(Challenge.TokenAlreadyEnabled.selector);
        challenge.setToken(TOKEN_1, 3, 100_000e3);
    }

    function test_DisableTradingToken() external {
        assertGt(challenge.tradingTokensDecimals(TOKEN_1), 0);

        challenge.disableTradingToken(TOKEN_1);

        assertEq(challenge.tradingTokensDecimals(TOKEN_1), 0);

        vm.expectRevert(Challenge.TokenNotEnabled.selector);
        challenge.disableTradingToken(TOKEN_1);
    }

    function test_DisableTradingTokenOnlyAffectsFutureUse() external {
        _createDefaultChallenge();

        assertGt(challenge.tradingTokensDecimals(TOKEN_1), 0);
        assertGt(challenge.challengeTokensDecimals(1, TOKEN_1), 0);

        challenge.disableTradingToken(TOKEN_1);

        assertEq(challenge.tradingTokensDecimals(TOKEN_1), 0);
        assertGt(challenge.challengeTokensDecimals(1, TOKEN_1), 0);
    }

    function test_SetPlatformFeePercentage() external {
        assertEq(challenge.platformFeePercentage(), PLATFORM_FEE);

        challenge.setPlatformFeePercentage(100);

        assertEq(challenge.platformFeePercentage(), 100);

        vm.expectRevert(Challenge.FeeTooHigh.selector);
        challenge.setPlatformFeePercentage(600);
    }

    function test_SetMinBuyIn() external {
        uint256 maxBuyIn = challenge.maxBuyIn();
        challenge.setMinBuyIn(maxBuyIn - 1);

        assertEq(challenge.minBuyIn(), maxBuyIn - 1);

        vm.expectRevert(Challenge.WrongBuyIn.selector);
        challenge.setMinBuyIn(0);

        vm.expectRevert(Challenge.WrongBuyIn.selector);
        challenge.setMinBuyIn(maxBuyIn);
    }

    function test_SetMaxBuyIn() external {
        uint256 minBuyIn = challenge.minBuyIn();
        challenge.setMaxBuyIn(minBuyIn + 1);

        assertEq(challenge.maxBuyIn(), minBuyIn + 1);

        vm.expectRevert(Challenge.WrongBuyIn.selector);
        challenge.setMaxBuyIn(0);

        vm.expectRevert(Challenge.WrongBuyIn.selector);
        challenge.setMaxBuyIn(minBuyIn);
    }

    function test_SetMinDuration() external {
        uint256 maxDuration = challenge.maxDuration();
        challenge.setMinDuration(maxDuration - 1);

        assertEq(challenge.minDuration(), maxDuration - 1);

        vm.expectRevert(Challenge.WrongDuration.selector);
        challenge.setMinDuration(0);

        vm.expectRevert(Challenge.WrongDuration.selector);
        challenge.setMinDuration(maxDuration);
    }

    function test_SetMaxDuration() external {
        uint256 minDuration = challenge.minDuration();
        challenge.setMaxDuration(minDuration + 1);

        assertEq(challenge.maxDuration(), minDuration + 1);

        vm.expectRevert(Challenge.WrongDuration.selector);
        challenge.setMaxDuration(0);

        vm.expectRevert(Challenge.WrongDuration.selector);
        challenge.setMaxDuration(minDuration);
    }

    function test_GetPlayerTotalUsd() external {
        _createAndStartDefaultChallenge();

        uint256 totalUsd = challenge.getPlayerTotalUsd(1);
        assertEq(totalUsd, challenge.INITIAL_VIRTUAL_USD());
    }

    function test_RevertGetPlayerTotalUsdNotOngoingChallenge() external {
        _createDefaultChallenge();

        vm.expectRevert(Challenge.NotOngoingChallenge.selector);
        challenge.getPlayerTotalUsd(1);
    }

    function test_GetChallengeTokensAllowed() external {
        _createDefaultChallenge();

        uint32[] memory tokensAllowed = challenge.getChallengeTokensAllowed(1);
        assertEq(tokensAllowed[0], TOKEN_1);
        assertEq(tokensAllowed[1], TOKEN_2);
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
