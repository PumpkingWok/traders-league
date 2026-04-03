// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC20Metadata} from "openzeppelin/token/ERC20/extensions/IERC20Metadata.sol";
import "openzeppelin/access/Ownable2Step.sol";

// 1 VS 1 Match creator
// Hyperliquid version
// USDC at evm -> decimals ?
// oracle px decimals
// use USDC as buy in token
// initial virtual usd for every user
contract HyperDuel is Ownable2Step {
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
        uint32[] tokensAllowed;
        MatchStatus status;
    }

    // Constant
    address constant ORACLE_PX_PRECOMPILE_ADDRESS = 0x0000000000000000000000000000000000000807;
    uint256 constant INITIAL_VIRTUAL_USD = 100_000e18;
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

    // hyperliquid spot tokens id => enabled/disabled
    mapping(uint32 => bool) public tradingTokens;

    // player => matchId => token => balance
    mapping(address => mapping(uint256 => mapping(uint256 => uint256))) public matchBalances;

    error DifferentLength();
    error FeeTooHigh();
    error OngoingMatch();
    error NotAllowed();
    error NotAuthorized();
    error NotOngoingMatch();
    error OnlyPlayer();
    error SameToken();
    error TokenNotEnabled();
    error WrongBuyIn();
    error WrongDuration();
    error WrongId();
    error ZeroAddress();

    event MatchCreated(uint256 buyIn, uint256 duration, uint256 matchId);

    event MatchConcluded(address indexed winner, uint256 prize, uint256 matchId);

    event MatchStarted(address indexed player1, address indexed player2, uint256 endTs, uint256 matchId);

    event MatchRemoved(uint256 matchId);

    constructor(address buyInToken_, uint256 platformFee_, address feeRecipient_) Ownable(msg.sender) {
        if (buyInToken_ == address(0)) revert ZeroAddress();
        if (platformFee_ > BASE_FEE) revert FeeTooHigh();

        buyInToken = IERC20Metadata(buyInToken_);
        platformFee = platformFee_;
        feeRecipient = feeRecipient_;

        minBuyIn = 10 * (10 ** buyInToken.decimals());
        maxBuyIn = 1000 * (10 ** buyInToken.decimals());
    }

    /// @notice Create a match deciding the tokens allowed, duration and buyIn amount 
    /// @param tokenAllowed Tokens allowed to be traded
    /// @param buyIn Buy in amount required to join the match
    /// @param duration Match duration
    function createMatch(uint32[] calldata tokenAllowed, uint256 buyIn, uint256 duration) external {
        _createMatch(address(0), address(0), tokenAllowed, buyIn, duration);
    }

    /// @notice Create and join a match
    /// @param tokensAllowed Tokens allowed to be traded
    /// @param buyIn Buy in amount required to join the match
    /// @param duration Match duration
    function createMatchAndJoin(uint32[] calldata tokensAllowed, uint256 buyIn, uint256 duration) external {
        _createMatch(msg.sender, address(0), tokensAllowed, buyIn, duration);
        // transfer buy in for player A
        buyInToken.transferFrom(msg.sender, address(this), buyIn);
    }

    /// @notice Ask for a match (reserved one)
    /// @param playerToAsk Player to ask for a match (only this player can join it)
    /// @param tokensAllowed Tokens allowed to be traded
    /// @param buyIn Buy in amount required to join the match
    /// @param duration Match duration 
    function askForMatch(address playerToAsk, uint32[] calldata tokensAllowed, uint256 buyIn, uint256 duration)
        external
    {
        _createMatch(msg.sender, playerToAsk, tokensAllowed, buyIn, duration);
        // transfer buy in for player A
        buyInToken.transferFrom(msg.sender, address(this), buyIn);
    }

    /// @notice Join a match
    /// @param _matchId Match id to join
    function joinMatch(uint256 _matchId) external onlyExistingMatch(_matchId) {
        MatchInfo memory matchInfo = matches[_matchId];
        // check if match is ongoing
        if (matchInfo.status != MatchStatus.TO_START) revert OngoingMatch();

        bool matchStarted;
        if (matchInfo.playerA == address(0)) {
            // first player to subscribe
            matches[_matchId].playerA = msg.sender;
        } else if (matchInfo.playerB == address(0)) {
            // second player to subscribe
            matches[_matchId].playerB = msg.sender;
            // start match
            matchStarted = true;
        } else {
            // reserved match
            if (matchInfo.playerB != msg.sender) revert NotAuthorized();
            // start match
            matchStarted = true;
        }

        buyInToken.transferFrom(msg.sender, address(this), matchInfo.buyIn);

        if (matchStarted) {
            matches[_matchId].endTime = block.timestamp + matchInfo.duration;
            matches[_matchId].status = MatchStatus.ONGOING;
            // add init virtual usd
            matchBalances[matchInfo.playerA][matchId][0] = INITIAL_VIRTUAL_USD;
            matchBalances[matchInfo.playerB][matchId][0] = INITIAL_VIRTUAL_USD;
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
        buyInToken.transfer(msg.sender, matchInfo.buyIn);

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

        uint256 length = tokensIn.length;
        if (length != tokensOut.length) revert DifferentLength();
        if (length != amountsIn.length) revert DifferentLength();

        uint32 tokenIn;
        uint32 tokenOut;
        uint256 amountIn;
        uint256 amountOut;
        for (uint256 i; i < length;) {
            // check if the tokens id are valid
            tokenIn = tokensIn[i];
            tokenOut = tokensOut[i];
            amountIn = amountsIn[i];
            if (tokenIn == tokenOut) revert SameToken();
            if (!tradingTokens[tokenIn]) revert TokenNotEnabled();
            if (!tradingTokens[tokenOut]) revert TokenNotEnabled();

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
        uint256 usdIn;
        if (_tokenIn == 0) {
            // swap from virtual usd
            usdIn = _amountIn;
        } else {
            usdIn = _amountIn * uint256(oraclePx(_tokenIn));
        }

        uint256 amountOut;
        if (_tokenOut == 0) {
            // swap to virtual usd
            amountOut = usdIn;
        } else {
            amountOut = usdIn / uint256(oraclePx(_tokenOut));
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
            buyInToken.transfer(playerA, buyIn);
            buyInToken.transfer(playerB, buyIn);
        } else {
            // calculate prize
            prize = buyIn * 2;
            uint256 fee = prize * platformFee / BASE_FEE;
            // transfer prize to the winner
            buyInToken.transfer(winner, prize - fee);
            // transfer platform fee to the dao
            buyInToken.transfer(feeRecipient, fee);
        }

        // mark the match as finished
        matches[_matchId].status = MatchStatus.FINISHED;

        emit MatchConcluded(winner, prize, matchId);
    }

    /// @notice Create a match
    /// @param player1 Player1 address
    /// @param player2 Player2 address
    /// @param tokensAllowed Tokens allowed to be traded
    /// @param buyIn Buy in amount
    /// @param duration Match duration
    function _createMatch(
        address player1,
        address player2,
        uint32[] calldata tokensAllowed,
        uint256 buyIn,
        uint256 duration
    ) internal {
        if (buyIn == 0 || buyIn > maxBuyIn || buyIn < minBuyIn) revert WrongBuyIn();
        if (duration == 0 || duration > maxDuration || duration < minDuration) revert WrongDuration();
        // check if all tokens are enabled to trade
        // permit duplicate
        uint256 length = tokensAllowed.length;
        for (uint256 i; i < length;) {
            // 0 is virtual usd
            if (tokensAllowed[i] == 0 || !tradingTokens[tokensAllowed[i]]) revert TokenNotEnabled();
            unchecked {
                ++i;
            }
        }
        matches[++matchId] =
            MatchInfo(player1, player2, address(0), buyIn, duration, 0, tokensAllowed, MatchStatus.TO_START);

        emit MatchCreated(buyIn, duration, matchId);
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
                uint256 usdValue = balance * uint256(oraclePx(token));
                totalUsd += usdValue;
            }
            unchecked {
                ++i;
            }
        }
        // add usd at the end
        totalUsd += matchBalances[_player][_matchId][0];
    }

    /// @notice Get the oracle price for the spot asset in hyperliquid
    /// @param index Spot token index
    function oraclePx(uint32 index) public view returns (uint64) {
        bool success;
        bytes memory result;
        (success, result) = ORACLE_PX_PRECOMPILE_ADDRESS.staticcall(abi.encode(index));
        require(success, "OraclePx precompile call failed");
        return abi.decode(result, (uint64));
    }

    /// @notice Enable/Disable trading tokens
    /// @param _tokenId Hyperliquid spot token index
    /// @param _status Enable or disable it
    function toggleTradingToken(uint32 _tokenId, bool _status) external onlyOwner {
        tradingTokens[_tokenId] = _status;
    }

    /// @notice Set platform fees
    /// @param _platformFee Platform fees
    function setPlatformFee(uint256 _platformFee) external onlyOwner {
        if (_platformFee < BASE_FEE) revert FeeTooHigh();
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
        if (_matchId > matchId) revert WrongId();
        _;
    }
}
