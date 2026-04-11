// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.25;

interface IHyperDuel {
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
    function matches(uint256) external view returns (MatchInfo memory);
}
