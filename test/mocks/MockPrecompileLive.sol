// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Vm} from "forge-std/Vm.sol";

Vm constant vm = Vm(address(0x7109709ECfa91a80626fF3989D68f67F5b1DD12D));

contract MockPrecompileLive {
    fallback() external payable {
        vm.pauseGasMetering();
        bytes memory response = _makeRpcCall(address(this), msg.data);
        vm.resumeGasMetering();
        assembly {
            return(add(response, 32), mload(response))
        }
    }

    function _makeRpcCall(address target, bytes memory params) internal returns (bytes memory) {
        // Construct the JSON-RPC payload
        string memory jsonPayload =
            string.concat('[{"to":"', vm.toString(target), '","data":"', vm.toString(params), '"},"latest"]');

        // Make the RPC call
        try vm.rpc("eth_call", jsonPayload) returns (bytes memory data) {
            return data;
        } catch {
            return "";
        }
    }
}
