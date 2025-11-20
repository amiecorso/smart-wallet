// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../../src/CoinbaseSmartWallet.sol";
import "../CoinbaseSmartWallet/SmartWalletTestBase.sol";

interface IOnchainFactory2 {
    function implementation() external view returns (address);
    function createAccount(bytes[] memory owners, uint256 nonce) external returns (address);
    function getAddress(bytes[] memory owners, uint256 nonce) external view returns (address);
}

contract Verify_v06 is SmartWalletTestBase {
    address internal fixedFactory;

    function setUp() public override {
        super.setUp();
        string memory path = vm.envOr("FIXED_BYTECODE_PATH", string(""));
        if (bytes(path).length != 0) {
            bytes memory runtime = _readHexFile(path);
            vm.etch(address(account), runtime);
            console2.log("etched wallet runtime at:", address(account));
            console2.log("wallet code length:", address(account).code.length);
        }
        // optional: if provided, etch a factory runtime too (used in first-deploy tests)
        string memory factoryPath = vm.envOr("FIXED_FACTORY_PATH", string(""));
        if (bytes(factoryPath).length != 0) {
            fixedFactory = vm.parseAddress(
                vm.envOr("FIXED_FACTORY_ADDRESS", string("0xF000000000000000000000000000000000000002"))
            );
            bytes memory facRuntime = _readHexFile(factoryPath);
            vm.etch(fixedFactory, facRuntime);
            console2.log("etched factory runtime at:", fixedFactory);
            console2.log("factory code length:", fixedFactory.code.length);
            // if the factory exposes implementation(), etch the impl runtime at that address
            string memory implPath = vm.envOr("FIXED_IMPL_PATH", string(""));
            if (bytes(implPath).length != 0) {
                address impl;
                try IOnchainFactory2(fixedFactory).implementation() returns (address a) {
                    impl = a;
                } catch {
                    impl = address(0);
                }
                console2.log("factory.implementation():", impl);
                bytes memory implRuntime = _readHexFile(implPath);
                if (impl != address(0)) {
                    vm.etch(impl, implRuntime);
                    console2.log("etched impl runtime at:", impl);
                    console2.log("impl code length:", impl.code.length);
                } else {
                    console2.log("warning: implementation() not readable, skipping etch");
                }
            }
        }
    }

    function test_verificationGas_deployed_simAndHandleOps() public {
        CoinbaseSmartWallet w = CoinbaseSmartWallet(payable(address(account)));
        UserOperation memory op = _getUserOp();
        op.sender = address(w);
        op.callData = abi.encodeCall(CoinbaseSmartWallet.execute, (address(0), 0, ""));
        op.signature = _signWrapper(op);

        // verification-only via simulateHandleOp (returns preOpGas in revert)
        (uint256 preOpGas,,) = _simulateHandleOp(op);
        console2.log("simulateHandleOp preOpGas (deployed):", preOpGas);

        // end-to-end via handleOps with minimal execution payload
        vm.startSnapshotGas("v06_handleOps_deployed");
        _sendUserOperation(op);
        uint256 gasUsed = vm.stopSnapshotGas();
        console2.log("handleOps gas (deployed):", gasUsed);
    }

    function test_verificationGas_firstDeploy_simAndHandleOps() public {
        // require factory + impl provided
        require(fixedFactory != address(0), "factory not set");

        // build initCode = factory address + abi.encodeCall(createAccount, (owners, 1))
        uint256 nonce = 0;
        bytes memory initCalldata = abi.encodeCall(IOnchainFactory2.createAccount, (owners, nonce));
        bytes memory initCode = abi.encodePacked(fixedFactory, initCalldata);

        // predict sender: prefer factory.getAddress if available; else fallback to EntryPoint.getSenderAddress
        address predicted;
        try IOnchainFactory2(fixedFactory).getAddress(owners, nonce) returns (address a) {
            predicted = a;
        } catch {
            predicted = _predictSender(initCode);
        }

        UserOperation memory op = _getUserOp();
        op.sender = predicted;
        op.initCode = initCode;
        op.callData = abi.encodeCall(CoinbaseSmartWallet.execute, (address(0), 0, ""));
        op.signature = _signWrapper(op);

        // ensure sender has ETH in case prefund is required
        vm.deal(predicted, 1 ether);

        console2.log("predicted sender:", predicted);
        console2.log("predicted sender code (before):", predicted.code.length);
        // verification-only via simulateHandleOp (returns preOpGas in revert)
        (uint256 preOpGas,,) = _simulateHandleOp(op);
        console2.log("simulateHandleOp preOpGas (first-deploy):", preOpGas);

        // end-to-end via handleOps including deployment
        vm.startSnapshotGas("v06_handleOps_firstDeploy");
        UserOperation[] memory ops = new UserOperation[](1);
        ops[0] = op;
        try entryPoint.handleOps(ops, payable(bundler)) {
            uint256 gasUsed = vm.stopSnapshotGas();
            console2.log("handleOps gas (first-deploy):", gasUsed);
            console2.log("predicted sender code (after):", predicted.code.length);
        } catch (bytes memory err) {
            vm.stopSnapshotGas();
            console2.log("handleOps revert (first-deploy), bytes:");
            console2.logBytes(err);
        }
    }

    function _signWrapper(UserOperation memory op) internal view returns (bytes memory) {
        bytes32 toSign = entryPoint.getUserOpHash(op);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, toSign);
        return abi.encode(CoinbaseSmartWallet.SignatureWrapper(0, abi.encodePacked(r, s, v)));
    }

    function _predictSender(bytes memory initCode) internal view returns (address sender) {
        // EntryPoint.getSenderAddress(initCode) always reverts with SenderAddressResult(sender).
        (bool ok, bytes memory ret) =
            address(entryPoint).staticcall(abi.encodeWithSelector(entryPoint.getSenderAddress.selector, initCode));
        ok; // silence
            // selector = SenderAddressResult(address): 0x556f1830
        assembly {
            // default: read last 32 bytes as address
            let len := mload(ret)
            if gt(len, 0x1f) {
                let base := add(ret, 32)
                sender := mload(add(base, sub(len, 32)))
            }
            // if selector matches and has standard layout, prefer first word after selector
            if and(eq(mload(add(ret, 32)), 0), eq(mload(ret), add(32, 32))) {
                // crude sanity: selector + one word
                sender := mload(add(ret, 36))
            }
        }
        require(sender != address(0), "predict sender failed");
    }

    function _simulateHandleOp(UserOperation memory op)
        internal
        returns (uint256 preOpGas, uint256 paid, bool targetSuccess)
    {
        // reverts with ExecutionResult(preOpGas, paid, validAfter, validUntil, targetSuccess, targetResult)
        (bool ok, bytes memory ret) =
            address(entryPoint).call(abi.encodeWithSelector(entryPoint.simulateHandleOp.selector, op, address(0), ""));
        ok; // silence
        if (ret.length >= 164) {
            // skip 4-byte selector, then read ABI-encoded fields
            assembly {
                let ptr := add(ret, 4)
                preOpGas := mload(add(ptr, 32))
                paid := mload(add(ptr, 64))
                // validAfter at +96, validUntil at +128 (ignored)
                // targetSuccess at +160
                targetSuccess := iszero(iszero(mload(add(ptr, 160))))
            }
        }
    }

    function _readHexFile(string memory path) internal view returns (bytes memory out) {
        string memory raw = vm.readFile(path);
        bytes memory src = bytes(_stripHexPrefixAndNewlines(raw));
        require(src.length % 2 == 0, "hex length");
        out = new bytes(src.length / 2);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = bytes1((uint8(_fromHexChar(src[2 * i])) << 4) | uint8(_fromHexChar(src[2 * i + 1])));
        }
    }

    function _stripHexPrefixAndNewlines(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 start = 0;
        uint256 end = b.length;
        if (end >= 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) {
            start = 2;
        }
        bytes memory tmp = new bytes(end - start);
        uint256 j;
        for (uint256 i = start; i < end; i++) {
            bytes1 c = b[i];
            if (c != 0x0a && c != 0x0d) {
                tmp[j++] = c;
            }
        }
        bytes memory out = new bytes(j);
        for (uint256 i = 0; i < j; i++) {
            out[i] = tmp[i];
        }
        return string(out);
    }

    function _fromHexChar(bytes1 c) internal pure returns (uint8) {
        if (uint8(c) >= 48 && uint8(c) <= 57) {
            return uint8(c) - 48;
        }
        if (uint8(c) >= 97 && uint8(c) <= 102) {
            return uint8(c) - 87;
        }
        if (uint8(c) >= 65 && uint8(c) <= 70) {
            return uint8(c) - 55;
        }
        revert("invalid hex");
    }
}

