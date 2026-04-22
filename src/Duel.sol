// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/access/Ownable2Step.sol";

// 1 VS 1 Match creator
// 100K as initial virtual usd for every user
abstract contract Duel is Ownable2Step {
    using SafeERC20 for IERC20Metadata;
    enum MatchStatus {
        TO_START,
        ONGOING,
        FINISHED,
        REMOVED
    }

    struct MatchInfo {
        address playerA;
        address playerB;
        address winner;
        uint256 buyIn;
        uint256 duration;
        uint256 endTime;
        MatchStatus status;
    }

    // Constant
    // every virtual token has 18 decimals
    uint256 public constant INITIAL_VIRTUAL_USD = 100_000e18;
    uint256 public constant GAME_TRADER_FEE = 30; // 0.3%
    uint256 public constant BASE_FEE = 10_000;
    uint256 public constant MAX_PLATFORM_FEE = 500; // 5%

    // match parameters
    IERC20Metadata public immutable buyInToken;
    uint256 public minBuyIn;
    uint256 public maxBuyIn;
    uint256 public minDuration = 1 hours;
    uint256 public maxDuration = 1 weeks;

    uint256 public platformFeePercentage;
    uint256 public accruedPlatformFee;

    uint256 public matchId;

    // match Id => match info
    mapping(uint256 => MatchInfo) public matches;

    // tokens id => usd price decimals
    mapping(uint32 => uint8) public tradingTokensDecimals;

    // match id => tokens id => allowed
    mapping(uint256 => mapping(uint32 => bool)) public isMatchTokensAllowed;

    // match id => tokens allowed to trade
    mapping(uint256 => uint32[]) public matchTokensAllowed;

    // player => matchId => token => balance
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public matchBalances;

    error DifferentLength();
    error FeeTooHigh();
    error OngoingMatch();
    error NotAllowed();
    error NotAuthorized();
    error NotOngoingMatch();
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

    constructor(address buyInToken_, uint256 platformFeePercentage_) Ownable(msg.sender) {
        if (buyInToken_ == address(0)) revert ZeroAddress();
        if (platformFeePercentage_ > MAX_PLATFORM_FEE) revert FeeTooHigh();

        buyInToken = IERC20Metadata(buyInToken_);
        platformFeePercentage = platformFeePercentage_;

        minBuyIn = 10 * (10 ** buyInToken.decimals());
        maxBuyIn = 1000 * (10 ** buyInToken.decimals());
    }

    /// @notice Create a match deciding the tokens allowed, duration and buyIn amount
    /// @param _playerA Player A (it can be msg.sender or no player)
    /// @param _playerB Player B (setting it will reserve the match only for this address)
    /// @param _tokensAllowed Tokens allowed to be traded during the match
    /// @param _buyIn Buy in amount required to join the match
    /// @param _duration Match duration
    function createMatch(
        address _playerA,
        address _playerB,
        uint32[] memory _tokensAllowed,
        uint256 _buyIn,
        uint256 _duration
    ) external {
        if (_playerA != address(0)) {
            if (_playerA != msg.sender) revert WrongPlayerA();
            // transfer buy in for player A
            buyInToken.safeTransferFrom(msg.sender, address(this), _buyIn);
        }
        if (_playerB != address(0) && _playerB == msg.sender) revert SamePlayer();
        _createMatch(_playerA, _playerB, _tokensAllowed, _buyIn, _duration);
    }

    /// @notice Create a match
    /// @param _player1 Player1 address
    /// @param _player2 Player2 address
    /// @param _tokensAllowed Tokens allowed to be traded during the match
    /// @param _buyIn Buy in amount
    /// @param _duration Match duration
    function _createMatch(
        address _player1,
        address _player2,
        uint32[] memory _tokensAllowed,
        uint256 _buyIn,
        uint256 _duration
    ) internal {
        if (_tokensAllowed.length == 0) revert ZeroToken();
        if (_buyIn == 0 || _buyIn > maxBuyIn || _buyIn < minBuyIn) revert WrongBuyIn();
        if (_duration == 0 || _duration > maxDuration || _duration < minDuration) revert WrongDuration();
        // check if all tokens are enabled to trade
        // permit duplicate
        uint256 nextMatchId = ++matchId;
        uint256 length = _tokensAllowed.length;
        for (uint256 i; i < length;) {
            uint32 tokenAllowed = _tokensAllowed[i];
            // 0 is virtual usd
            if (tokenAllowed == 0 || tradingTokensDecimals[tokenAllowed] == 0) revert TokenNotEnabled();
            if (isMatchTokensAllowed[nextMatchId][tokenAllowed]) revert TokenAlreadyEnabled();
            isMatchTokensAllowed[nextMatchId][tokenAllowed] = true;
            unchecked {
                ++i;
            }
        }
        matches[nextMatchId] = MatchInfo(_player1, _player2, address(0), _buyIn, _duration, 0, MatchStatus.TO_START);
        // store it as array also
        matchTokensAllowed[nextMatchId] = _tokensAllowed;

        emit MatchCreated(_buyIn, _duration, nextMatchId);
    }

    /// @notice Join a match
    /// @param _matchId Match id to join
    function joinMatch(uint256 _matchId) external onlyExistingMatch(_matchId) {
        MatchInfo storage matchInfo = matches[_matchId];
        // check if match is ongoing
        if (matchInfo.status != MatchStatus.TO_START) revert OngoingMatch();

        bool matchStarted;
        if (matchInfo.playerA == address(0)) {
            // first player to subscribe
            matchInfo.playerA = msg.sender;
        } else if (matchInfo.playerB == address(0)) {
            // check if it isn't player A
            if (msg.sender == matchInfo.playerA) revert SamePlayer();
            // second player to subscribe
            matchInfo.playerB = msg.sender;
            // start match
            matchStarted = true;
        } else {
            // reserved match
            if (matchInfo.playerB != msg.sender) revert NotAuthorized();
            // start match
            matchStarted = true;
        }

        buyInToken.safeTransferFrom(msg.sender, address(this), matchInfo.buyIn);

        if (matchStarted) {
            matchInfo.endTime = block.timestamp + matchInfo.duration;
            matchInfo.status = MatchStatus.ONGOING;
            // add init virtual usd
            matchBalances[matchInfo.playerA][_matchId][0] = INITIAL_VIRTUAL_USD;
            matchBalances[matchInfo.playerB][_matchId][0] = INITIAL_VIRTUAL_USD;

            emit MatchStarted(matchInfo.playerA, matchInfo.playerB, matchInfo.endTime, _matchId);
        }
    }

    /// @notice Unjoin a match not started yet
    /// @param _matchId Match id
    function unjoinMatch(uint256 _matchId) external onlyExistingMatch(_matchId) {
        MatchInfo storage matchInfo = matches[_matchId];
        if (matchInfo.playerA != msg.sender) revert NotAllowed();
        if (matchInfo.status != MatchStatus.TO_START) revert OngoingMatch();

        // transfer back token to player A
        buyInToken.safeTransfer(msg.sender, matchInfo.buyIn);

        if (matchInfo.playerB == address(0)) {
            // remove playerA
            matchInfo.playerA = address(0);
            emit MatchUnjoined(msg.sender, _matchId);
        } else {
            // reserved match, mark is as removed
            matchInfo.status = MatchStatus.REMOVED;
            emit MatchReservedRemoved(msg.sender, _matchId);
        }
    }

    /// @notice Swap tokens in a match
    /// @param _matchId Match id
    /// @param _tokensIn Tokens to swap for
    /// @param _tokensOut Tokens to obtain
    /// @param _amountsIn Amounts to swap for
    function swap(
        uint256 _matchId,
        uint32[] calldata _tokensIn,
        uint32[] calldata _tokensOut,
        uint256[] calldata _amountsIn
    ) external onlyExistingMatch(_matchId) {
        // check if it's a player
        MatchInfo memory matchInfo = matches[_matchId];
        if (matchInfo.playerA != msg.sender && matchInfo.playerB != msg.sender) revert OnlyPlayer();
        // check if the match is ongoing
        if (matchInfo.status != MatchStatus.ONGOING) revert NotOngoingMatch();
        // check if the match has to conclude
        if (block.timestamp >= matchInfo.endTime) revert NotOngoingMatch();

        uint256 length = _tokensIn.length;
        if (length != _tokensOut.length) revert DifferentLength();
        if (length != _amountsIn.length) revert DifferentLength();

        uint32 tokenIn;
        uint32 tokenOut;
        uint256 amountIn;
        for (uint256 i; i < length;) {
            // check if the tokens id are valid
            tokenIn = _tokensIn[i];
            tokenOut = _tokensOut[i];
            amountIn = _amountsIn[i];
            if (amountIn == 0) revert ZeroAmount();
            if (tokenIn == tokenOut) revert SameToken();
            if (tokenIn != 0 && !isMatchTokensAllowed[_matchId][tokenIn]) revert TokenNotEnabled();
            if (tokenOut != 0 && !isMatchTokensAllowed[_matchId][tokenOut]) revert TokenNotEnabled();

            _swap(_matchId, tokenIn, tokenOut, amountIn);
            unchecked {
                ++i;
            }
        }
    }

    /// @notice Internal function to virtual swap
    /// @param _matchId Match id
    /// @param _tokenIn Tokens to swap for
    /// @param _tokenOut Tokens to obtain
    /// @param _amountIn Swap amount
    function _swap(uint256 _matchId, uint32 _tokenIn, uint32 _tokenOut, uint256 _amountIn) internal {
        // swap tokenIn to tokenOut
        // it would revert if the balance is not enough
        matchBalances[msg.sender][_matchId][_tokenIn] -= _amountIn;
        // calculate usd value of token
        // obtain usd value of token in
        uint256 usdIn = _amountIn;
        if (_tokenIn != 0) {
            usdIn = usdIn * uint256(tokenPx(_tokenIn)) / (10 ** tradingTokensDecimals[_tokenIn]);
        }

        uint256 amountOut = usdIn - (usdIn * GAME_TRADER_FEE / BASE_FEE);
        if (_tokenOut != 0) {
            amountOut = amountOut * (10 ** tradingTokensDecimals[_tokenOut]) / uint256(tokenPx(_tokenOut));
        }

        matchBalances[msg.sender][_matchId][_tokenOut] += amountOut;

        emit Swap(_tokenIn, _tokenOut, _amountIn, amountOut, msg.sender, _matchId);
    }

    /// @notice Conclude a match
    /// @param _matchId Match id to conclude
    function concludeMatch(uint256 _matchId) external onlyExistingMatch(_matchId) {
        MatchInfo memory matchInfo = matches[_matchId];
        if (matchInfo.status != MatchStatus.ONGOING) revert NotOngoingMatch();
        // check if it is still ongoing
        if (block.timestamp <= matchInfo.endTime) revert OngoingMatch();

        // check the winner
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

        // mark the match as finished
        matches[_matchId].status = MatchStatus.FINISHED;

        // tie match
        if (winner == address(0)) {
            // resend back buy in to players, no fee on tie
            buyInToken.safeTransfer(playerA, buyIn);
            buyInToken.safeTransfer(playerB, buyIn);
        } else {
            matches[_matchId].winner = winner;

            // calculate prize
            prize = buyIn * 2;
            uint256 fee = prize * platformFeePercentage / BASE_FEE;
            // transfer prize to the winner
            buyInToken.safeTransfer(winner, prize - fee);
            // account fee in the contract
            accruedPlatformFee += fee;
        }

        emit MatchConcluded(winner, prize, _matchId);
    }

    /// @notice Calculate the player total usd for the match
    /// @param _matchId Match id
    /// @param _player Player address
    function getPlayerTotalUsd(uint256 _matchId, address _player) external view returns (uint256 totalUsd) {
        return _getPlayerTotalUsd(_matchId, _player);
    }

    /// @notice Calculate the player total usd for the match
    /// @param _matchId Match id
    /// @param _player Player address
    function _getPlayerTotalUsd(uint256 _matchId, address _player) internal view returns (uint256 totalUsd) {
        uint32[] memory tokensAllowed = matchTokensAllowed[_matchId];
        uint256 length = tokensAllowed.length;

        for (uint256 i; i < length;) {
            uint32 token = tokensAllowed[i];
            uint256 balance = matchBalances[_player][_matchId][token];
            if (balance != 0) {
                uint256 usdValue = balance * uint256(tokenPx(token)) / (10 ** tradingTokensDecimals[token]);
                totalUsd += usdValue;
            }
            unchecked {
                ++i;
            }
        }
        // add usd at the end
        totalUsd += matchBalances[_player][_matchId][0];
    }

    /// @notice Get the token price
    /// @param _index Token index
    function tokenPx(uint32 _index) public view virtual returns (uint64);

    /// @notice Get the match tokens allowed list
    /// @param _matchId Match id
    function getMatchTokensAllowed(uint256 _matchId) external view returns (uint32[] memory _tokensAllowed) {
        _tokensAllowed = matchTokensAllowed[_matchId];
    }

    /// @notice Withdraw platform fee
    /// @param _amount Amount to withdraw
    /// @param _recipient Fee recipient
    function withdrawPlatformFee(uint256 _amount, address _recipient) external onlyOwner {
        if (_recipient == address(0)) revert ZeroAddress();
        accruedPlatformFee -= _amount;
        buyInToken.safeTransfer(_recipient, _amount);
    }

    /// @notice Enable a token to be traded in matches
    /// it's an internal function, another one has that call it has to be defined
    /// @param _tokenId Token id to enable
    /// @param _decimals Token decimals
    function _enableTradingToken(uint32 _tokenId, uint8 _decimals) internal {
        if (tradingTokensDecimals[_tokenId] != 0) revert TokenAlreadyEnabled();
        //uint8 tokenDecimals = _getTokenPxDecimals(_tokenId);
        //_getSpotTokenId()
        tradingTokensDecimals[_tokenId] = _decimals;
    }

    /// @notice Disable a trading token (not in ongoing matches)
    /// @param _tokenId Token id to disable
    function disableTradingToken(uint32 _tokenId) external onlyOwner {
        if (tradingTokensDecimals[_tokenId] == 0) revert TokenNotEnabled();
        tradingTokensDecimals[_tokenId] = 0;
    }

    /// @notice Set platform fees
    /// @param _platformFeePercentage Platform fees percentage (10_000 = 100%)
    function setPlatformFeePercentage(uint256 _platformFeePercentage) external onlyOwner {
        if (_platformFeePercentage > MAX_PLATFORM_FEE) revert FeeTooHigh();
        platformFeePercentage = _platformFeePercentage;
    }

    /// @notice Set min buy in for the match
    /// @param _minBuyIn Min buy in amount
    function setMinBuyIn(uint256 _minBuyIn) external onlyOwner {
        if (_minBuyIn == 0 || _minBuyIn >= maxBuyIn) revert WrongBuyIn();
        minBuyIn = _minBuyIn;
    }

    /// @notice Set max buy in for the match
    /// @param _maxBuyIn Max buy in amount
    function setMaxBuyIn(uint256 _maxBuyIn) external onlyOwner {
        if (_maxBuyIn == 0 || _maxBuyIn <= minBuyIn) revert WrongBuyIn();
        maxBuyIn = _maxBuyIn;
    }

    /// @notice Set min match duration
    /// @param _minDuration Minimum match duration
    function setMinDuration(uint256 _minDuration) external onlyOwner {
        if (_minDuration == 0 || _minDuration >= maxDuration) revert WrongDuration();
        minDuration = _minDuration;
    }

    /// @notice Set max match duration
    /// @param _maxDuration Maximum match duration
    function setMaxDuration(uint256 _maxDuration) external onlyOwner {
        if (_maxDuration == 0 || _maxDuration <= minDuration) revert WrongDuration();
        maxDuration = _maxDuration;
    }

    modifier onlyExistingMatch(uint256 _matchId) {
        // check if match id exist
        if (_matchId == 0 || _matchId > matchId) revert WrongId();
        _;
    }
}
