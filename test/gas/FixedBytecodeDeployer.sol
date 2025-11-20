// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

contract _ReturnRuntimeOnConstruction {
    constructor(bytes memory runtime) {
        assembly {
            return(add(runtime, 0x20), mload(runtime))
        }
    }
}

contract FixedBytecodeDeployer {
    function deploy(bytes memory runtime) external returns (address deployed) {
        deployed = address(new _ReturnRuntimeOnConstruction(runtime));
    }
}



