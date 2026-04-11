// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "openzeppelin/token/ERC20/utils/SafeERC20.sol";
import "openzeppelin/access/Ownable2Step.sol";

// 1 VS 1 Match creator
// Hyperliquid version
// USDC at evm -> decimals ?
// spot px decimals
// use USDC as buy in token
// initial virtual usd for every user
contract HyperDuel is Ownable2Step {
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
        uint32[] tokensAllowed;
    }

    // Constant
    address constant SPOT_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000808;
    // every token has 8 decimals
    uint256 constant INITIAL_VIRTUAL_USD = 100_000e8;
    uint256 constant GAME_TRADER_FEE = 30; // 0.3%
    uint256 constant BASE_FEE = 10_000;

    // match parameters
    IERC20Metadata public immutable buyInToken;
    uint256 public minBuyIn;
    uint256 public maxBuyIn;
    uint256 public minDuration = 1 hours;
    uint256 public maxDuration = 1 weeks;

    uint256 public platformFee;
    address public feeRecipient;

    uint256 public matchId;

    // match Id => match info
    mapping(uint256 => MatchInfo) public matches;

    // hyperliquid spot tokens id => decimals
    mapping(uint32 => uint8) public tradingTokens;
    // spot tokens spotPx decimals
    mapping(uint256 => mapping(uint32 => bool)) public matchTradingTokens;

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

    event MatchStarted(address indexed player1, address indexed player2, uint256 endTs, uint256 matchId);

    event MatchRemoved(uint256 matchId);

    constructor(address buyInToken_, uint256 platformFee_, address feeRecipient_) Ownable(msg.sender) {
        if (buyInToken_ == address(0)) revert ZeroAddress();
        if (feeRecipient_ == address(0)) revert ZeroAddress();
        if (platformFee_ > BASE_FEE) revert FeeTooHigh();

        buyInToken = IERC20Metadata(buyInToken_);
        platformFee = platformFee_;
        feeRecipient = feeRecipient_;

        minBuyIn = 10 * (10 ** buyInToken.decimals());
        maxBuyIn = 1000 * (10 ** buyInToken.decimals());
    }

    /// @notice Create a match deciding the tokens allowed, duration and buyIn amount
    /// @param playerA Player A (it can be msg.sender or no player)
    /// @param playerB Player B (setting it will reserve the match only for this address)
    /// @param tokensAllowed Tokens allowed to be traded during the match
    /// @param buyIn Buy in amount required to join the match
    /// @param duration Match duration
    function createMatch(
        address playerA,
        address playerB,
        uint32[] memory tokensAllowed,
        uint256 buyIn,
        uint256 duration
    ) external {
        if (playerA != address(0)) {
            if (playerA != msg.sender) revert WrongPlayerA();
            // transfer buy in for player A
            buyInToken.safeTransferFrom(msg.sender, address(this), buyIn);
        }
        if (playerB != address(0) && playerB == msg.sender) revert SamePlayer();
        _createMatch(playerA, playerB, tokensAllowed, buyIn, duration);
    }

    /// @notice Create a match
    /// @param player1 Player1 address
    /// @param player2 Player2 address
    /// @param tokensAllowed Tokens allowed to be traded during the match
    /// @param buyIn Buy in amount
    /// @param duration Match duration
    function _createMatch(
        address player1,
        address player2,
        uint32[] memory tokensAllowed,
        uint256 buyIn,
        uint256 duration
    ) internal {
        if (tokensAllowed.length == 0) revert ZeroToken();
        if (buyIn == 0 || buyIn > maxBuyIn || buyIn < minBuyIn) revert WrongBuyIn();
        if (duration == 0 || duration > maxDuration || duration < minDuration) revert WrongDuration();
        // check if all tokens are enabled to trade
        // permit duplicate
        uint256 nextMatchId = ++matchId;
        uint256 length = tokensAllowed.length;
        for (uint32 i; i < length;) {
            uint32 tokenAllowed = tokensAllowed[i];
            // 0 is virtual usd
            if (tokensAllowed[i] == 0 || tradingTokens[tokenAllowed] == 0) revert TokenNotEnabled();
            if (matchTradingTokens[nextMatchId][tokenAllowed]) revert TokenAlreadyEnabled();
            matchTradingTokens[nextMatchId][tokenAllowed] = true;
            unchecked {
                ++i;
            }
        }
        matches[nextMatchId] =
            MatchInfo(player1, player2, address(0), buyIn, duration, 0, MatchStatus.TO_START, tokensAllowed);

        emit MatchCreated(buyIn, duration, nextMatchId);
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

    /// @notice Remove a not started match, only playerA can remove a match
    /// no players subscribed matches can't be removed
    /// @param _matchId Match id to remove
    function removeMatch(uint256 _matchId) external onlyExistingMatch(_matchId) {
        MatchInfo memory matchInfo = matches[_matchId];
        if (matchInfo.playerA != msg.sender) revert NotAllowed();
        if (matchInfo.status != MatchStatus.TO_START) revert OngoingMatch();

        // transfer back token to player A
        buyInToken.safeTransfer(msg.sender, matchInfo.buyIn);

        matches[_matchId].status = MatchStatus.REMOVED;

        emit MatchRemoved(_matchId);
    }

    /// @notice Swap tokens in a match
    /// @param _matchId Match id
    /// @param tokensIn Tokens to swap for
    /// @param tokensOut Tokens to obtain
    /// @param amountsIn Amounts to swap for
    function swap(
        uint256 _matchId,
        uint32[] calldata tokensIn,
        uint32[] calldata tokensOut,
        uint256[] calldata amountsIn
    ) external onlyExistingMatch(_matchId) {
        // check if it's a player
        MatchInfo memory matchInfo = matches[_matchId];
        if (matchInfo.playerA != msg.sender && matchInfo.playerB != msg.sender) revert OnlyPlayer();
        // check if the match is ongoing
        if (matchInfo.status != MatchStatus.ONGOING) revert NotOngoingMatch();
        // check if the match has to conclude
        if (block.timestamp >= matchInfo.endTime) revert NotOngoingMatch();

        uint256 length = tokensIn.length;
        if (length != tokensOut.length) revert DifferentLength();
        if (length != amountsIn.length) revert DifferentLength();

        uint32 tokenIn;
        uint32 tokenOut;
        uint256 amountIn;
        for (uint256 i; i < length;) {
            // check if the tokens id are valid
            tokenIn = tokensIn[i];
            tokenOut = tokensOut[i];
            amountIn = amountsIn[i];
            if (amountIn == 0) revert ZeroAmount();
            if (tokenIn == tokenOut) revert SameToken();
            if (tokenIn != 0 && !matchTradingTokens[_matchId][tokenIn]) revert TokenNotEnabled();
            if (tokenOut != 0 && !matchTradingTokens[_matchId][tokenOut]) revert TokenNotEnabled();

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
        // calculate usd value of token in via hyperliquid spot px
        // obtain usd value of token in
        uint256 usdIn = _amountIn;
        if (_tokenIn != 0) {
            usdIn = usdIn * uint256(spotPx(_tokenIn)) / (10 ** tradingTokens[_tokenIn]);
        }

        uint256 amountOut = usdIn - (usdIn * GAME_TRADER_FEE / BASE_FEE);
        if (_tokenOut != 0) {
            amountOut = amountOut * (10 ** tradingTokens[_tokenOut]) / uint256(spotPx(_tokenOut));
        }

        matchBalances[msg.sender][_matchId][_tokenOut] += amountOut;
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
        uint256 usdPlayerA = _getTotalUsd(_matchId, playerA);
        uint256 usdPlayerB = _getTotalUsd(_matchId, playerB);

        address winner;
        if (usdPlayerA > usdPlayerB) {
            winner = playerA;
        } else if (usdPlayerB > usdPlayerA) {
            winner = playerB;
        }

        uint256 buyIn = matchInfo.buyIn;
        uint256 prize;
        // tie match
        if (winner == address(0)) {
            // resend back buy in to players, no fee on tie
            buyInToken.safeTransfer(playerA, buyIn);
            buyInToken.safeTransfer(playerB, buyIn);
        } else {
            matches[_matchId].winner = winner;

            // calculate prize
            prize = buyIn * 2;
            uint256 fee = prize * platformFee / BASE_FEE;
            // transfer prize to the winner
            buyInToken.safeTransfer(winner, prize - fee);
            // transfer platform fee to the dao
            buyInToken.safeTransfer(feeRecipient, fee);
        }

        // mark the match as finished before transfer
        matches[_matchId].status = MatchStatus.FINISHED;

        emit MatchConcluded(winner, prize, _matchId);
    }

    /// @notice Calculate the total usd portfolio value
    /// @param _matchId Match id
    /// @param _player Player address
    function _getTotalUsd(uint256 _matchId, address _player) internal view returns (uint256 totalUsd) {
        MatchInfo memory matchInfo = matches[_matchId];
        uint32[] memory tokensAllowed = matchInfo.tokensAllowed;
        uint256 length = tokensAllowed.length;

        //uint256 totalUsd;
        for (uint256 i; i < length;) {
            uint32 token = tokensAllowed[i];
            uint256 balance = matchBalances[_player][_matchId][token];
            if (balance != 0) {
                uint256 usdValue = balance * uint256(spotPx(token)) / (10 ** tradingTokens[token]);
                totalUsd += usdValue;
            }
            unchecked {
                ++i;
            }
        }
        // add usd at the end
        totalUsd += matchBalances[_player][_matchId][0];
    }

    /// @notice Get the spot price for the spot asset in hyperliquid
    /// @param index Spot token index
    function spotPx(uint32 index) public view returns (uint64) {
        bool success;
        bytes memory result;
        (success, result) = SPOT_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(index));
        require(success, "SpotPx precompile call failed");
        return abi.decode(result, (uint64));
    }

    /// @notice Get the match tokens allowed list
    /// @param _matchId Match id
    function getMatchTokensAllowed(uint256 _matchId) external view returns (uint32[] memory _tokensAllowed) {
        _tokensAllowed = matches[_matchId].tokensAllowed;
    }

    /// @notice Enable/Disable trading tokens
    /// @param _tokenId Hyperliquid spot token index
    /// @param _spotPxDecimals SpotPx decimals (0 to disable the token)
    function toggleTradingToken(uint32 _tokenId, uint8 _spotPxDecimals) external onlyOwner {
        tradingTokens[_tokenId] = _spotPxDecimals;
    }

    /// @notice Set platform fees
    /// @param _platformFee Platform fees
    function setPlatformFee(uint256 _platformFee) external onlyOwner {
        if (_platformFee > BASE_FEE) revert FeeTooHigh();
        platformFee = _platformFee;
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
