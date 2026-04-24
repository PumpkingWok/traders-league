// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {HyperDuel} from "src/HyperDuel.sol";

contract DeployHyperDuel is Script {
    address internal constant BUY_IN_TOKEN_MAINNET = 0xb88339CB7199b77E23DB6E890353E22632Ba630f; // USDC
    address internal constant BUY_IN_TOKEN_TESTNET = 0x2B3370eE501B4a559b57D449569354196457D8Ab; // USDC

    function run() external returns (HyperDuel duel) {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        string memory network = vm.envOr("HYPERLIQUID_NETWORK", string("testnet"));
        uint256 platformFeeBps = 100; // 1%

        (address buyInToken, uint32[] memory tokenIdsToEnable) = _deploymentConfig(network);

        vm.startBroadcast(deployerPrivateKey);

        duel = new HyperDuel(buyInToken, platformFeeBps);

        uint256 length = tokenIdsToEnable.length;
        for (uint256 i; i < length;) {
            duel.enableTradingToken(tokenIdsToEnable[i]);
            unchecked {
                ++i;
            }
        }

        vm.stopBroadcast();

        console2.log("HyperDuel deployed at:", address(duel));
        console2.log("Buy-in token:", buyInToken);
        console2.log("Enabled tokens:", length);
    }

    function _deploymentConfig(string memory network)
        internal
        pure
        returns (address buyInToken, uint32[] memory tokenIds)
    {
        if (_eq(network, "mainnet")) {
            buyInToken = BUY_IN_TOKEN_MAINNET;
            tokenIds = _mainnetTokenIds();
            return (buyInToken, tokenIds);
        }

        if (_eq(network, "testnet")) {
            buyInToken = BUY_IN_TOKEN_TESTNET;
            tokenIds = _testnetTokenIds();
            return (buyInToken, tokenIds);
        }

        revert("invalid HYPERLIQUID_NETWORK");
    }

    function _mainnetTokenIds() internal pure returns (uint32[] memory tokenIds) {
        // UBTC, UETH, USOL token ids on Hyperliquid mainnet
        tokenIds = new uint32[](3);
        tokenIds[0] = 197;
        tokenIds[1] = 221;
        tokenIds[2] = 254;
    }

    function _testnetTokenIds() internal pure returns (uint32[] memory tokenIds) {
        // HYPE, UETH, HORSE token ids on Hyperliquid testnet
        tokenIds = new uint32[](3);
        tokenIds[0] = 1105;
        tokenIds[1] = 1242;
        tokenIds[2] = 1435;
    }

    function _eq(string memory a, string memory b) internal pure returns (bool) {
        return keccak256(bytes(a)) == keccak256(bytes(b));
    }
}
