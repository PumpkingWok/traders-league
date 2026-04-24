// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/access/Ownable2Step.sol";

/// @title Duel
/// @author Traders League Team
/// @notice Core 1v1 virtual trading game engine.
/// @dev Tracks match lifecycle, virtual balances, and settlement using a buy-in token.
abstract contract Duel is Ownable2Step {
    using SafeERC20 for IERC20Metadata;

    /// @notice Lifecycle states for a match.
    enum MatchStatus {
        TO_START,
        ONGOING,
        FINISHED,
        REMOVED
    }

    /// @notice Core match configuration and outcome data.
    struct MatchInfo {
        address playerA;
        address playerB;
        address winner;
        uint256 buyIn;
        uint256 duration;
        uint256 endTime;
        MatchStatus status;
    }

    /// @notice Initial virtual USD assigned to each player when a match starts (18 decimals).
    uint256 public constant INITIAL_VIRTUAL_USD = 100_000e18;
    /// @notice Virtual trading fee charged on each swap (30 bps = 0.3%).
    uint256 public constant GAME_TRADER_FEE = 30; // 0.3%
    /// @notice Basis-point denominator (10_000 = 100%).
    uint256 public constant BASE_FEE = 10_000;
    /// @notice Maximum platform fee (500 bps = 5%).
    uint256 public constant MAX_PLATFORM_FEE = 500; // 5%

    /// @notice token used for match buy-ins and payouts.
    IERC20Metadata public immutable buyInToken;
    /// @notice Minimum allowed buy-in amount.
    uint256 public minBuyIn;
    /// @notice Maximum allowed buy-in amount.
    uint256 public maxBuyIn;
    /// @notice Minimum allowed match duration.
    uint256 public minDuration = 15 minutes;
    /// @notice Maximum allowed match duration.
    uint256 public maxDuration = 1 weeks;

    /// @notice Platform fee in basis points applied to non-tie prize pools.
    uint256 public platformFeePercentage;
    /// @notice Accumulated platform fees available for owner withdrawal.
    uint256 public accruedPlatformFee;

    /// @notice Last created match id (increments from 1).
    uint256 public matchId;

    /// @notice Match id => match metadata.
    mapping(uint256 => MatchInfo) public matches;

    /// @notice Spot token id => token price decimal scaling used for virtual conversion.
    mapping(uint32 => uint8) public tradingTokensDecimals;

    /// @notice Match id => token id => price decimal scaling snapshot for that match.
    mapping(uint256 => mapping(uint32 => uint8)) public matchTokensDecimals;

    /// @notice Match id => list of allowed tradable token ids.
    mapping(uint256 => uint32[]) public matchTokensAllowed;

    /// @notice Player => match id => token id => virtual token balance.
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public matchBalances;

    error DifferentLength();
    error FeeTooHigh();
    error OngoingMatch();
    error NotAllowed();
    error NotAuthorized();
    error NotOngoingMatch();
    error NotToStartMatch();
    error OnlyPlayer();
    error SamePlayer();
    error SameToken();
    error TokenAlreadyEnabled();
    error TokenNotEnabled();
    error WrongBuyIn();
    error WrongDuration();
    error WrongId();
    error WrongPlayerA();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroToken();

    event MatchCreated(uint256 buyIn, uint256 duration, uint256 matchId);

    event MatchConcluded(address indexed winner, uint256 prize, uint256 matchId);

    event MatchReservedRemoved(address indexed playerA, uint256 matchId);

    event MatchStarted(address indexed playerA, address indexed playerB, uint256 endTs, uint256 matchId);

    event MatchUnjoined(address indexed playerA, uint256 matchId);

    event Swap(
        uint32 indexed tokenIn,
        uint32 indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address player,
        uint256 matchId
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

    /// @notice Create a new match with optional reservation.
    /// @param _playerA Player A (must be `msg.sender` or zero address).
    /// @param _playerB Optional reserved opponent (zero means open match).
    /// @param _tokensAllowed Tokens allowed to be traded during the match.
    /// @param _buyIn Buy-in amount required from each player.
    /// @param _duration Match duration in seconds.
    function createMatch(
        address _playerA,
        address _playerB,
        uint32[] memory _tokensAllowed,
        uint256 _buyIn,
        uint256 _duration
    ) external {
        if (_playerA != address(0)) {
            if (_playerA != msg.sender) revert WrongPlayerA();
            // transfer player A buy-in at creation time when provided.
            buyInToken.safeTransferFrom(msg.sender, address(this), _buyIn);
        }
        if (_playerB != address(0) && _playerB == msg.sender) revert SamePlayer();
        _createMatch(_playerA, _playerB, _tokensAllowed, _buyIn, _duration);
    }

    /// @notice Internal match creation with validated input shape.
    /// @param _playerA Player A address.
    /// @param _playerB Player B address.
    /// @param _tokensAllowed Tokens allowed to be traded during the match.
    /// @param _buyIn Buy-in amount.
    /// @param _duration Match duration in seconds.
    function _createMatch(
        address _playerA,
        address _playerB,
        uint32[] memory _tokensAllowed,
        uint256 _buyIn,
        uint256 _duration
    ) internal {
        if (_tokensAllowed.length == 0) revert ZeroToken();
        if (_buyIn == 0 || _buyIn > maxBuyIn || _buyIn < minBuyIn) revert WrongBuyIn();
        if (_duration == 0 || _duration > maxDuration || _duration < minDuration) revert WrongDuration();
        // ensure each requested token is already enabled and not duplicated.
        uint256 nextMatchId = ++matchId;
        uint256 length = _tokensAllowed.length;
        for (uint256 i; i < length;) {
            uint32 tokenAllowed = _tokensAllowed[i];
            // token id `0` is reserved for virtual USD and cannot be listed here.
            if (tokenAllowed == 0 || tradingTokensDecimals[tokenAllowed] == 0) revert TokenNotEnabled();
            if (matchTokensDecimals[nextMatchId][tokenAllowed] != 0) revert TokenAlreadyEnabled();
            matchTokensDecimals[nextMatchId][tokenAllowed] = tradingTokensDecimals[tokenAllowed];
            unchecked {
                ++i;
            }
        }
        matches[nextMatchId] = MatchInfo({
            playerA: _playerA,
            playerB: _playerB,
            winner: address(0),
            buyIn: _buyIn,
            duration: _duration,
            endTime: 0,
            status: MatchStatus.TO_START
        });
        // store allowed tokens.
        matchTokensAllowed[nextMatchId] = _tokensAllowed;

        emit MatchCreated(_buyIn, _duration, nextMatchId);
    }

    /// @notice Join an existing match and start it when both players are present.
    /// @param _matchId Match id to join.
    function joinMatch(uint256 _matchId) external onlyExistingMatch(_matchId) {
        MatchInfo storage matchInfo = matches[_matchId];
        // match must still be waiting for players.
        if (matchInfo.status != MatchStatus.TO_START) revert NotToStartMatch();

        bool matchStarted;
        if (matchInfo.playerA == address(0)) {
            // first joiner becomes player A for open matches.
            matchInfo.playerA = msg.sender;
        } else if (matchInfo.playerB == address(0)) {
            // second joiner must be different from player A.
            if (msg.sender == matchInfo.playerA) revert SamePlayer();
            // second joiner becomes player B.
            matchInfo.playerB = msg.sender;
            matchStarted = true;
        } else {
            // reserved match path.
            if (matchInfo.playerB != msg.sender) revert NotAuthorized();
            matchStarted = true;
        }

        buyInToken.safeTransferFrom(msg.sender, address(this), matchInfo.buyIn);

        if (matchStarted) {
            matchInfo.endTime = block.timestamp + matchInfo.duration;
            matchInfo.status = MatchStatus.ONGOING;
            // assign equal initial virtual portfolios to both players.
            matchBalances[matchInfo.playerA][_matchId][0] = INITIAL_VIRTUAL_USD;
            matchBalances[matchInfo.playerB][_matchId][0] = INITIAL_VIRTUAL_USD;

            emit MatchStarted(matchInfo.playerA, matchInfo.playerB, matchInfo.endTime, _matchId);
        }
    }

    /// @notice Cancel player A participation before a match starts.
    /// @param _matchId Match id.
    function unjoinMatch(uint256 _matchId) external onlyExistingMatch(_matchId) {
        MatchInfo storage matchInfo = matches[_matchId];
        if (matchInfo.playerA != msg.sender) revert NotAllowed();
        if (matchInfo.status != MatchStatus.TO_START) revert NotToStartMatch();

        // return player A buy-in.
        buyInToken.safeTransfer(msg.sender, matchInfo.buyIn);

        if (matchInfo.playerB == address(0)) {
            // open match: clear player A and keep match available.
            matchInfo.playerA = address(0);
            emit MatchUnjoined(msg.sender, _matchId);
        } else {
            // reserved match: cancel entirely.
            matchInfo.status = MatchStatus.REMOVED;
            emit MatchReservedRemoved(msg.sender, _matchId);
        }
    }

    /// @notice Execute a single virtual swap during an ongoing match.
    /// @param _matchId Match id.
    /// @param _tokenIn Token to sell.
    /// @param _tokenOut Token to buy.
    /// @param _amountIn Amount to sell.
    function swap(uint256 _matchId, uint32 _tokenIn, uint32 _tokenOut, uint256 _amountIn)
        external
        onlyExistingMatch(_matchId)
    {
        MatchInfo memory matchInfo = matches[_matchId];

        _validateMatchInfo(matchInfo.playerA, matchInfo.playerB, matchInfo.status, matchInfo.endTime);

        _validateSwapInfo(_matchId, _tokenIn, _tokenOut, _amountIn);

        _swap(_matchId, _tokenIn, _tokenOut, _amountIn);
    }

    /// @notice Execute multiple virtual swaps in one transaction.
    /// @param _matchId Match id.
    /// @param _tokensIn Tokens to sell.
    /// @param _tokensOut Tokens to buy.
    /// @param _amountsIn Amounts to sell.
    function swap(
        uint256 _matchId,
        uint32[] calldata _tokensIn,
        uint32[] calldata _tokensOut,
        uint256[] calldata _amountsIn
    ) external onlyExistingMatch(_matchId) {
        MatchInfo memory matchInfo = matches[_matchId];

        _validateMatchInfo(matchInfo.playerA, matchInfo.playerB, matchInfo.status, matchInfo.endTime);

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
            _validateSwapInfo(_matchId, tokenIn, tokenOut, amountIn);

            _swap(_matchId, tokenIn, tokenOut, amountIn);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Internal virtual swap settlement helper.
    /// @param _matchId Match id.
    /// @param _tokenIn Token being sold.
    /// @param _tokenOut Token being bought.
    /// @param _amountIn Swap amount.
    function _swap(uint256 _matchId, uint32 _tokenIn, uint32 _tokenOut, uint256 _amountIn) internal {
        // decrease sold token balance (reverts on insufficient balance).
        matchBalances[msg.sender][_matchId][_tokenIn] -= _amountIn;
        // convert tokenIn amount to virtual USD.
        uint256 usdIn = _amountIn;
        if (_tokenIn != 0) {
            usdIn = usdIn * uint256(tokenPx(_tokenIn)) / (10 ** matchTokensDecimals[_matchId][_tokenIn]);
        }

        // apply per-trade game fee.
        uint256 amountOut = usdIn - (usdIn * GAME_TRADER_FEE / BASE_FEE);
        if (_tokenOut != 0) {
            // convert virtual USD into tokenOut.
            amountOut = amountOut * (10 ** matchTokensDecimals[_matchId][_tokenOut]) / uint256(tokenPx(_tokenOut));
        }

        matchBalances[msg.sender][_matchId][_tokenOut] += amountOut;

        emit Swap(_tokenIn, _tokenOut, _amountIn, amountOut, msg.sender, _matchId);
    }

    /// @notice Validate caller participation and match trading window.
    /// @param _playerA Player A address.
    /// @param _playerB Player B address.
    /// @param _status Match status.
    /// @param _endTs Match end time.
    function _validateMatchInfo(address _playerA, address _playerB, MatchStatus _status, uint256 _endTs) internal view {
        if (_playerA != msg.sender && _playerB != msg.sender) revert OnlyPlayer();
        // match must be ongoing and not yet expired.
        if (_status != MatchStatus.ONGOING || block.timestamp >= _endTs) revert NotOngoingMatch();
    }

    /// @notice Validate swap token ids and amount.
    /// @param _matchId Match id.
    /// @param _tokenIn Token to sell.
    /// @param _tokenOut Token to buy.
    /// @param _amountIn Amount to swap.
    function _validateSwapInfo(uint256 _matchId, uint32 _tokenIn, uint32 _tokenOut, uint256 _amountIn) internal view {
        if (_amountIn == 0) revert ZeroAmount();
        if (_tokenIn == _tokenOut) revert SameToken();
        if (_tokenIn != 0 && matchTokensDecimals[_matchId][_tokenIn] == 0) revert TokenNotEnabled();
        if (_tokenOut != 0 && matchTokensDecimals[_matchId][_tokenOut] == 0) revert TokenNotEnabled();
    }

    /// @notice Conclude an expired match and distribute payouts.
    /// @param _matchId Match id to conclude.
    function concludeMatch(uint256 _matchId) external onlyExistingMatch(_matchId) {
        MatchInfo memory matchInfo = matches[_matchId];
        if (matchInfo.status != MatchStatus.ONGOING) revert NotOngoingMatch();
        // match must be expired.
        if (block.timestamp <= matchInfo.endTime) revert OngoingMatch();

        // compute final virtual USD values.
        address playerA = matchInfo.playerA;
        address playerB = matchInfo.playerB;
        uint256 usdPlayerA = _getPlayerTotalUsd(_matchId, playerA);
        uint256 usdPlayerB = _getPlayerTotalUsd(_matchId, playerB);

        address winner;
        if (usdPlayerA > usdPlayerB) {
            winner = playerA;
        } else if (usdPlayerB > usdPlayerA) {
            winner = playerB;
        }

        uint256 buyIn = matchInfo.buyIn;
        uint256 prize;

        // mark the match as finished.
        matches[_matchId].status = MatchStatus.FINISHED;

        // tie path: refund both buy-ins with no platform fee.
        if (winner == address(0)) {
            buyInToken.safeTransfer(playerA, buyIn);
            buyInToken.safeTransfer(playerB, buyIn);
        } else {
            matches[_matchId].winner = winner;

            // winner takes the pot minus platform fee.
            prize = buyIn * 2;
            uint256 fee = prize * platformFeePercentage / BASE_FEE;
            buyInToken.safeTransfer(winner, prize - fee);
            accruedPlatformFee += fee;
        }

        emit MatchConcluded(winner, prize, _matchId);
    }

    /// @notice Calculate a player's marked-to-market virtual USD for a match.
    /// @param _matchId Match id.
    /// @param _player Player address.
    function getPlayerTotalUsd(uint256 _matchId, address _player)
        external
        view
        onlyExistingMatch(_matchId)
        returns (uint256 totalUsd)
    {
        return _getPlayerTotalUsd(_matchId, _player);
    }

    /// @notice Internal marked-to-market virtual USD calculation.
    /// @param _matchId Match id.
    /// @param _player Player address.
    function _getPlayerTotalUsd(uint256 _matchId, address _player) internal view returns (uint256 totalUsd) {
        uint32[] memory tokensAllowed = matchTokensAllowed[_matchId];
        uint256 length = tokensAllowed.length;

        for (uint256 i; i < length;) {
            uint32 token = tokensAllowed[i];
            uint256 balance = matchBalances[_player][_matchId][token];
            if (balance != 0) {
                uint256 usdValue = balance * uint256(tokenPx(token)) / (10 ** matchTokensDecimals[_matchId][token]);
                totalUsd += usdValue;
            }
            unchecked {
                ++i;
            }
        }
        // add direct virtual USD balance.
        totalUsd += matchBalances[_player][_matchId][0];
    }

    /// @notice Return token spot price in implementation-specific format.
    /// @param _index Spot token id.
    function tokenPx(uint32 _index) public view virtual returns (uint64);

    /// @notice Return the list of tradable tokens configured for a match.
    /// @param _matchId Match id.
    function getMatchTokensAllowed(uint256 _matchId)
        external
        view
        onlyExistingMatch(_matchId)
        returns (uint32[] memory _tokensAllowed)
    {
        _tokensAllowed = matchTokensAllowed[_matchId];
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

    /// @notice Enable a tradable token for future matches.
    /// @dev Implementations are expected to resolve and pass the correct decimal scaling.
    /// @param _tokenId Spot token id to enable.
    /// @param _decimals Decimal scaling used for USD conversion.
    function _enableTradingToken(uint32 _tokenId, uint8 _decimals) internal virtual {
        // token id `0` is reserved for virtual USD.
        if (_tokenId == 0 || tradingTokensDecimals[_tokenId] != 0) revert TokenAlreadyEnabled();
        tradingTokensDecimals[_tokenId] = _decimals;
    }

    /// @notice Disable a trading token for future matches.
    /// @param _tokenId Token id to disable.
    function disableTradingToken(uint32 _tokenId) external onlyOwner {
        if (tradingTokensDecimals[_tokenId] == 0) revert TokenNotEnabled();
        tradingTokensDecimals[_tokenId] = 0;
    }

    /// @notice Set platform fee for match payouts.
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

    /// @notice Set minimum match duration.
    /// @param _minDuration Minimum match duration.
    function setMinDuration(uint256 _minDuration) external onlyOwner {
        if (_minDuration == 0 || _minDuration >= maxDuration) revert WrongDuration();
        minDuration = _minDuration;
    }

    /// @notice Set maximum match duration.
    /// @param _maxDuration Maximum match duration.
    function setMaxDuration(uint256 _maxDuration) external onlyOwner {
        if (_maxDuration == 0 || _maxDuration <= minDuration) revert WrongDuration();
        maxDuration = _maxDuration;
    }

    /// @notice Revert if a match id does not exist.
    /// @param _matchId Match id to validate.
    modifier onlyExistingMatch(uint256 _matchId) {
        if (_matchId == 0 || _matchId > matchId) revert WrongId();
        _;
    }
}
