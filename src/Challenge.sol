// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/access/Ownable2Step.sol";

/// @title Challenge
/// @author Traders League Team
/// @notice Core Challenge mode.
/// @dev Tracks challenge lifecycle, virtual balances, and settlement using a buy-in token.
abstract contract Challenge is Ownable2Step {
    using SafeERC20 for IERC20Metadata;

    /// @notice Lifecycle states for a challenge.
    enum ChallengeStatus {
        TO_START,
        ONGOING,
        FINISHED,
        REMOVED
    }

    /// @notice Core challenge configuration and outcome data.
    struct ChallengeInfo {
        address creator;
        address player;
        address winner;
        uint256 buyIn;
        uint256 prize;
        uint256 duration;
        uint256 endTime;
        uint256 expiry;
        uint256 targetAmount;
        ChallengeStatus status;
    }

    /// @notice Initial virtual USD assigned to each player when a challenge starts (18 decimals).
    uint256 public constant INITIAL_VIRTUAL_USD = 100_000e18;
    /// @notice Virtual trading fee charged on each swap (30 bps = 0.3%).
    uint256 public constant GAME_TRADER_FEE = 30; // 0.3%
    /// @notice Basis-point denominator (10_000 = 100%).
    uint256 public constant BASE_FEE = 10_000;
    /// @notice Maximum platform fee (500 bps = 5%).
    uint256 public constant MAX_PLATFORM_FEE = 500; // 5%
    /// @notice Maximum expiry time for a challenge to be joined.
    uint256 public constant MAX_EXPIRY_DURATION = 8 weeks;

    /// @notice token used for challenge buy-ins and payouts.
    IERC20Metadata public immutable buyInToken;
    /// @notice Minimum allowed buy-in amount.
    uint256 public minBuyIn;
    /// @notice Maximum allowed buy-in amount.
    uint256 public maxBuyIn;
    /// @notice Minimum allowed challenge duration.
    uint256 public minDuration = 15 minutes;
    /// @notice Maximum allowed challenge duration.
    uint256 public maxDuration = 1 weeks;

    /// @notice Platform fee in basis points applied to non-tie prize pools.
    uint256 public platformFeePercentage;
    /// @notice Accumulated platform fees available for owner withdrawal.
    uint256 public accruedPlatformFee;

    /// @notice Last created challenge id (increments from 1).
    uint256 public challengeId;

    /// @notice Challenge id => challenge metadata.
    mapping(uint256 => ChallengeInfo) public challenges;

    /// @notice Spot token id => token price decimal scaling used for virtual conversion.
    mapping(uint32 => uint8) public tradingTokensDecimals;

    /// @notice Challenge id => token id => price decimal scaling snapshot for that challenge.
    mapping(uint256 => mapping(uint32 => uint8)) public challengeTokensDecimals;

    /// @notice Challenge id => list of allowed tradable token ids.
    mapping(uint256 => uint32[]) public challengeTokensAllowed;

    /// @notice Player => challenge id => token id => virtual token balance.
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public challengeBalances;

    error ChallengeCreator();
    error ChallengeExpired();
    error ChallengeNotExpired();
    error DifferentLength();
    error FeeTooHigh();
    error OngoingChallenge();
    error NotAllowed();
    error NotOngoingChallenge();
    error NotToStartChallenge();
    error OnlyPlayer();
    error SameToken();
    error TokenAlreadyEnabled();
    error TokenNotEnabled();
    error WrongBuyIn();
    error WrongDuration();
    error WrongExpiry();
    error WrongId();
    error WrongPrize();
    error WrongTargetAmount();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroToken();

    event ChallengeCreated(
        uint256 buyIn,
        uint256 prize,
        uint256 duration,
        uint256 expiryDuration,
        uint256 targetAmount,
        uint256 challengeId
    );

    event ChallengeConcluded(address indexed winner, uint256 challengeId);

    event ChallengeRemoved(uint256 challengeId);

    event ChallengeStarted(address indexed player, uint256 endTs, uint256 challengeId);

    event Swap(
        uint32 indexed tokenIn,
        uint32 indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address player,
        uint256 challengeId
    );

    /// @param buyInToken_ Token used for buy-ins and payouts.
    /// @param platformFeePercentage_ Initial platform fee in bps.
    constructor(address buyInToken_, uint256 platformFeePercentage_) Ownable(msg.sender) {
        if (buyInToken_ == address(0)) revert ZeroAddress();
        if (platformFeePercentage_ > MAX_PLATFORM_FEE) revert FeeTooHigh();

        buyInToken = IERC20Metadata(buyInToken_);
        platformFeePercentage = platformFeePercentage_;

        minBuyIn = 10 * (10 ** buyInToken.decimals()); // 10
        maxBuyIn = 1000 * (10 ** buyInToken.decimals()); // 1000
    }

    /// @notice Create a new challenge
    /// @param _tokensAllowed Tokens allowed to be traded during the match.
    /// @param _buyIn Buy-in amount required from each player.
    /// @param _prize Challenge prize
    /// @param _duration Challenge duration in seconds.
    /// @param _expiryDuration Expiry duration until the challenge is valid to be joined
    /// @param _targetAmount Usd amount to reach for winning the challenge
    function createChallenge(
        uint32[] memory _tokensAllowed,
        uint256 _buyIn,
        uint256 _prize,
        uint256 _duration,
        uint256 _expiryDuration,
        uint256 _targetAmount
    ) external {
        _createChallenge(_tokensAllowed, _buyIn, _prize, _duration, _expiryDuration, _targetAmount);
    }

    /// @notice Internal challenge creation with validated input shape.
    /// @param _tokensAllowed Tokens allowed to be traded during the challenge.
    /// @param _buyIn Buy-in amount.
    /// @param _prize Challenge prize
    /// @param _duration Challenge duration in seconds.
    /// @param _expiryDuration Expiry duration until the challenge is valid to be joined
    /// @param _targetAmount Usd amount to reach for winning the challenge
    function _createChallenge(
        uint32[] memory _tokensAllowed,
        uint256 _buyIn,
        uint256 _prize,
        uint256 _duration,
        uint256 _expiryDuration,
        uint256 _targetAmount
    ) internal {
        if (_tokensAllowed.length == 0) revert ZeroToken();
        if (_buyIn == 0 || _buyIn > maxBuyIn || _buyIn < minBuyIn) revert WrongBuyIn();
        if (_prize == 0 || _prize < _buyIn) revert WrongPrize();
        if (_duration == 0 || _duration > maxDuration || _duration < minDuration) revert WrongDuration();
        if (_expiryDuration == 0 || _expiryDuration > MAX_EXPIRY_DURATION) revert WrongExpiry();
        if (_targetAmount <= INITIAL_VIRTUAL_USD) revert WrongTargetAmount();

        // ensure each requested token is already enabled and not duplicated.
        uint256 nextChallengeId = ++challengeId;
        uint256 length = _tokensAllowed.length;
        for (uint256 i; i < length;) {
            uint32 tokenAllowed = _tokensAllowed[i];
            // token id `0` is reserved for virtual USD and cannot be listed here.
            if (tokenAllowed == 0 || tradingTokensDecimals[tokenAllowed] == 0) revert TokenNotEnabled();
            if (challengeTokensDecimals[nextChallengeId][tokenAllowed] != 0) revert TokenAlreadyEnabled();
            challengeTokensDecimals[nextChallengeId][tokenAllowed] = tradingTokensDecimals[tokenAllowed];
            unchecked {
                ++i;
            }
        }

        // transfer prize here
        buyInToken.safeTransferFrom(msg.sender, address(this), _prize);

        challenges[nextChallengeId] = ChallengeInfo({
            creator: msg.sender,
            player: address(0),
            winner: address(0),
            buyIn: _buyIn,
            prize: _prize,
            duration: _duration,
            endTime: 0,
            expiry: block.timestamp + _expiryDuration,
            targetAmount: _targetAmount,
            status: ChallengeStatus.TO_START
        });
        // store allowed tokens.
        challengeTokensAllowed[nextChallengeId] = _tokensAllowed;

        emit ChallengeCreated(_buyIn, _prize, _duration, _expiryDuration, _targetAmount, nextChallengeId);
    }

    /// @notice Join an existing challenge.
    /// @param _challengeId Challenge id to join.
    function joinChallenge(uint256 _challengeId) external onlyExistingChallenge(_challengeId) {
        ChallengeInfo storage challengeInfo = challenges[_challengeId];
        if (challengeInfo.expiry <= block.timestamp) revert ChallengeExpired();
        // challenge must still be waiting for player.
        if (challengeInfo.status != ChallengeStatus.TO_START) revert NotToStartChallenge();
        if (challengeInfo.creator == msg.sender) revert ChallengeCreator();

        // transfer buyIn here, then buyIn - fee to the creator
        uint256 fee = _chargeFee(challengeInfo.buyIn);
        buyInToken.safeTransferFrom(msg.sender, address(this), challengeInfo.buyIn);
        buyInToken.safeTransfer(challengeInfo.creator, challengeInfo.buyIn - fee);

        challengeInfo.player = msg.sender;
        challengeInfo.endTime = block.timestamp + challengeInfo.duration;
        challengeInfo.status = ChallengeStatus.ONGOING;
        // assign equal initial virtual portfolios to both players.
        challengeBalances[challengeInfo.player][_challengeId][0] = INITIAL_VIRTUAL_USD;

        emit ChallengeStarted(challengeInfo.player, challengeInfo.endTime, _challengeId);
    }

    /// @notice Remove challenge not started yet
    /// @param _challengeId Challenge id.
    function removeChallenge(uint256 _challengeId) external onlyExistingChallenge(_challengeId) {
        ChallengeInfo storage challengeInfo = challenges[_challengeId];
        if (challengeInfo.creator != msg.sender) revert NotAllowed();
        if (challengeInfo.status != ChallengeStatus.TO_START) revert NotToStartChallenge();
        if (challengeInfo.expiry > block.timestamp) revert ChallengeNotExpired();

        // mark the challenge as removed
        challengeInfo.status = ChallengeStatus.REMOVED;
        // return prize to the creator.
        buyInToken.safeTransfer(msg.sender, challengeInfo.prize);

        emit ChallengeRemoved(_challengeId);
    }

    /// @notice Execute a single virtual swap during an ongoing challenge.
    /// @param _challengeId Challenge id.
    /// @param _tokenIn Token to sell.
    /// @param _tokenOut Token to buy.
    /// @param _amountIn Amount to sell.
    function swap(uint256 _challengeId, uint32 _tokenIn, uint32 _tokenOut, uint256 _amountIn)
        external
        onlyExistingChallenge(_challengeId)
    {
        ChallengeInfo memory challengeInfo = challenges[_challengeId];

        _validateChallengeInfo(challengeInfo.player, challengeInfo.status, challengeInfo.endTime);

        _validateSwapInfo(_challengeId, _tokenIn, _tokenOut, _amountIn);

        _swap(_challengeId, _tokenIn, _tokenOut, _amountIn);
    }

    /// @notice Execute multiple virtual swaps in one transaction.
    /// @param _challengeId Challenge id.
    /// @param _tokensIn Tokens to sell.
    /// @param _tokensOut Tokens to buy.
    /// @param _amountsIn Amounts to sell.
    function swap(
        uint256 _challengeId,
        uint32[] calldata _tokensIn,
        uint32[] calldata _tokensOut,
        uint256[] calldata _amountsIn
    ) external onlyExistingChallenge(_challengeId) {
        ChallengeInfo memory challengeInfo = challenges[_challengeId];

        _validateChallengeInfo(challengeInfo.player, challengeInfo.status, challengeInfo.endTime);

        uint256 length = _tokensIn.length;
        if (length != _tokensOut.length || length != _amountsIn.length) revert DifferentLength();

        uint32 tokenIn;
        uint32 tokenOut;
        uint256 amountIn;
        for (uint256 i; i < length;) {
            // validate each swap and execute sequentially.
            tokenIn = _tokensIn[i];
            tokenOut = _tokensOut[i];
            amountIn = _amountsIn[i];
            _validateSwapInfo(_challengeId, tokenIn, tokenOut, amountIn);

            _swap(_challengeId, tokenIn, tokenOut, amountIn);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Internal virtual swap settlement helper.
    /// @param _challengeId Challenge id.
    /// @param _tokenIn Token being sold.
    /// @param _tokenOut Token being bought.
    /// @param _amountIn Swap amount.
    function _swap(uint256 _challengeId, uint32 _tokenIn, uint32 _tokenOut, uint256 _amountIn) internal {
        // decrease sold token balance (reverts on insufficient balance).
        challengeBalances[msg.sender][_challengeId][_tokenIn] -= _amountIn;
        // convert tokenIn amount to virtual USD.
        uint256 usdIn = _amountIn;
        if (_tokenIn != 0) {
            usdIn = usdIn * uint256(tokenPx(_tokenIn)) / (10 ** challengeTokensDecimals[_challengeId][_tokenIn]);
        }

        // apply per-trade game fee.
        uint256 amountOut = usdIn - (usdIn * GAME_TRADER_FEE / BASE_FEE);
        if (_tokenOut != 0) {
            // convert virtual USD into tokenOut.
            amountOut =
                amountOut * (10 ** challengeTokensDecimals[_challengeId][_tokenOut]) / uint256(tokenPx(_tokenOut));
        }

        challengeBalances[msg.sender][_challengeId][_tokenOut] += amountOut;

        emit Swap(_tokenIn, _tokenOut, _amountIn, amountOut, msg.sender, _challengeId);
    }

    /// @notice Validate caller participation and challenge trading window.
    /// @param _player Player address.
    /// @param _status Challenge status.
    /// @param _endTs Challenge end time.
    function _validateChallengeInfo(address _player, ChallengeStatus _status, uint256 _endTs) internal view {
        if (_player != msg.sender) revert OnlyPlayer();
        // challenge must be ongoing and not yet expired.
        if (_status != ChallengeStatus.ONGOING || block.timestamp >= _endTs) revert NotOngoingChallenge();
    }

    /// @notice Validate swap token ids and amount.
    /// @param _challengeId Challenge id.
    /// @param _tokenIn Token to sell.
    /// @param _tokenOut Token to buy.
    /// @param _amountIn Amount to swap.
    function _validateSwapInfo(uint256 _challengeId, uint32 _tokenIn, uint32 _tokenOut, uint256 _amountIn)
        internal
        view
    {
        if (_amountIn == 0) revert ZeroAmount();
        if (_tokenIn == _tokenOut) revert SameToken();
        if (_tokenIn != 0 && challengeTokensDecimals[_challengeId][_tokenIn] == 0) revert TokenNotEnabled();
        if (_tokenOut != 0 && challengeTokensDecimals[_challengeId][_tokenOut] == 0) revert TokenNotEnabled();
    }

    /// @notice Conclude a challenge
    /// @param _challengeId Challenge id to conclude.
    function concludeChallenge(uint256 _challengeId) external onlyExistingChallenge(_challengeId) {
        ChallengeInfo storage challengeInfo = challenges[_challengeId];
        if (challengeInfo.status != ChallengeStatus.ONGOING) revert NotOngoingChallenge();
        // challenge must be concluded
        if (block.timestamp <= challengeInfo.endTime) revert OngoingChallenge();

        uint256 prize = challengeInfo.prize;
        // compute final virtual USD values.
        uint256 usdPlayer = _getPlayerTotalUsd(_challengeId);

        if (usdPlayer >= challengeInfo.targetAmount) {
            // player won
            challengeInfo.winner = challengeInfo.player;
        } else {
            // challenge creator won
            challengeInfo.winner = challengeInfo.creator;
        }

        // charge platform fees
        uint256 fee = _chargeFee(prize);
        buyInToken.safeTransfer(challengeInfo.winner, prize - fee);

        // mark the challenge as finished.
        challenges[_challengeId].status = ChallengeStatus.FINISHED;

        emit ChallengeConcluded(challengeInfo.winner, _challengeId);
    }

    function _chargeFee(uint256 _amount) internal returns (uint256 fee) {
        fee = _amount * platformFeePercentage / BASE_FEE;
        accruedPlatformFee += fee;
    }

    /// @notice Calculate a player's marked-to-market virtual USD for a challenge.
    /// @param _challengeId Challenge id.
    function getPlayerTotalUsd(uint256 _challengeId)
        external
        view
        onlyExistingChallenge(_challengeId)
        returns (uint256 totalUsd)
    {
        return _getPlayerTotalUsd(_challengeId);
    }

    /// @notice Internal marked-to-market virtual USD calculation.
    /// @param _challengeId Challenge id.
    function _getPlayerTotalUsd(uint256 _challengeId) internal view returns (uint256 totalUsd) {
        ChallengeInfo memory challengeInfo = challenges[_challengeId];
        if (challengeInfo.status != ChallengeStatus.ONGOING) revert NotOngoingChallenge();
        uint32[] memory tokensAllowed = challengeTokensAllowed[_challengeId];
        uint256 length = tokensAllowed.length;

        for (uint256 i; i < length;) {
            uint32 token = tokensAllowed[i];
            uint256 balance = challengeBalances[challengeInfo.player][_challengeId][token];
            if (balance != 0) {
                uint256 usdValue =
                    balance * uint256(tokenPx(token)) / (10 ** challengeTokensDecimals[_challengeId][token]);
                totalUsd += usdValue;
            }
            unchecked {
                ++i;
            }
        }
        // add direct virtual USD balance.
        totalUsd += challengeBalances[challengeInfo.player][_challengeId][0];
    }

    /// @notice Return token spot price in implementation-specific format.
    /// @param _index Spot token id.
    function tokenPx(uint32 _index) public view virtual returns (uint64);

    /// @notice Return the list of tradable tokens configured for a challenge.
    /// @param _challengeId Challenge id.
    function getChallengeTokensAllowed(uint256 _challengeId)
        external
        view
        onlyExistingChallenge(_challengeId)
        returns (uint32[] memory _tokensAllowed)
    {
        _tokensAllowed = challengeTokensAllowed[_challengeId];
    }

    /// @notice Withdraw all accrued platform fees to a recipient.
    /// @param _recipient Fee recipient.
    function withdrawPlatformFee(address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        if (accruedPlatformFee != 0) {
            buyInToken.safeTransfer(_recipient, accruedPlatformFee);
            accruedPlatformFee = 0;
        }
    }

    /// @notice Enable a tradable token for future challenges.
    /// @dev Implementations are expected to resolve and pass the correct decimal scaling.
    /// @param _tokenId Spot token id to enable.
    /// @param _decimals Decimal scaling used for USD conversion.
    function _enableTradingToken(uint32 _tokenId, uint8 _decimals) internal virtual {
        // token id `0` is reserved for virtual USD.
        if (_tokenId == 0 || tradingTokensDecimals[_tokenId] != 0) revert TokenAlreadyEnabled();
        tradingTokensDecimals[_tokenId] = _decimals;
    }

    /// @notice Disable a trading token for future challenges.
    /// @param _tokenId Token id to disable.
    function disableTradingToken(uint32 _tokenId) external onlyOwner {
        if (tradingTokensDecimals[_tokenId] == 0) revert TokenNotEnabled();
        tradingTokensDecimals[_tokenId] = 0;
    }

    /// @notice Set platform fee for challenge payouts.
    /// @param _platformFeePercentage Platform fee in bps (10_000 = 100%).
    function setPlatformFeePercentage(uint256 _platformFeePercentage) external onlyOwner {
        if (_platformFeePercentage > MAX_PLATFORM_FEE) revert FeeTooHigh();
        platformFeePercentage = _platformFeePercentage;
    }

    /// @notice Set minimum buy-in.
    /// @param _minBuyIn Minimum buy-in amount.
    function setMinBuyIn(uint256 _minBuyIn) external onlyOwner {
        if (_minBuyIn == 0 || _minBuyIn >= maxBuyIn) revert WrongBuyIn();
        minBuyIn = _minBuyIn;
    }

    /// @notice Set maximum buy-in.
    /// @param _maxBuyIn Maximum buy-in amount.
    function setMaxBuyIn(uint256 _maxBuyIn) external onlyOwner {
        if (_maxBuyIn == 0 || _maxBuyIn <= minBuyIn) revert WrongBuyIn();
        maxBuyIn = _maxBuyIn;
    }

    /// @notice Set minimum challenge duration.
    /// @param _minDuration Minimum challenge duration.
    function setMinDuration(uint256 _minDuration) external onlyOwner {
        if (_minDuration == 0 || _minDuration >= maxDuration) revert WrongDuration();
        minDuration = _minDuration;
    }

    /// @notice Set maximum challenge duration.
    /// @param _maxDuration Maximum challenge duration.
    function setMaxDuration(uint256 _maxDuration) external onlyOwner {
        if (_maxDuration == 0 || _maxDuration <= minDuration) revert WrongDuration();
        maxDuration = _maxDuration;
    }

    /// @notice Revert if a challenge id does not exist.
    /// @param _challengeId Challenge id to validate.
    modifier onlyExistingChallenge(uint256 _challengeId) {
        if (_challengeId == 0 || _challengeId > challengeId) revert WrongId();
        _;
    }
}
