// SPDX-License-Identifier: MIT
pragma solidity ^0.8.18;

contract MockSpotPx {
    mapping(uint32 => uint64) public spotPxs;

    function setSpotPx(uint32 token, uint64 spotPx) external {
        spotPxs[token] = spotPx;
    }

    fallback() external {
        uint32 token = abi.decode(msg.data, (uint32));
        bytes memory encoded = abi.encode(spotPxs[token]);
        assembly {
            return(add(encoded, 0x20), mload(encoded))
        }
    }
}
