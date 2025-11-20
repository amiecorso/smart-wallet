// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../CoinbaseSmartWallet/SmartWalletTestBase.sol";
import "../mocks/MockEntryPoint.sol";
import "../../src/CoinbaseSmartWallet.sol";

contract FixedBytecodeValidate is SmartWalletTestBase {
    function setUp() public override {
        super.setUp();
        string memory path = vm.envOr("FIXED_BYTECODE_PATH", string(""));
        require(bytes(path).length != 0, "FIXED_BYTECODE_PATH not set");
        bytes memory runtime = _readHexFile(path);
        vm.etch(address(account), runtime);
    }

    function test_validateUserOp_fixedBytecode() public {
        // Mirror essential parts of TestValidateUserOp.test_succeedsWithEOASigner
        bytes32 userOpHash = keccak256("123");
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, userOpHash);
        uint256 missingAccountFunds = 456;

        vm.deal(address(account), 1 ether);
        vm.etch(account.entryPoint(), address(new MockEntryPoint()).code);
        MockEntryPoint ep = MockEntryPoint(payable(account.entryPoint()));

        UserOperation memory userOp;
        userOp.signature = abi.encode(CoinbaseSmartWallet.SignatureWrapper(0, abi.encodePacked(r, s, v)));
        // Expect success path to return 0 and transfer prefund.
        assertEq(ep.validateUserOp(address(account), userOp, userOpHash, missingAccountFunds), 0);
        assertEq(address(ep).balance, missingAccountFunds);
    }

    function _readHexFile(string memory path) internal view returns (bytes memory out) {
        string memory raw = vm.readFile(path);
        bytes memory src = bytes(_stripHexPrefixAndNewlines(raw));
        require(src.length % 2 == 0, "hex length");
        out = new bytes(src.length / 2);
        for (uint256 i = 0; i < out.length; i++) {
            out[i] = bytes1(
                (uint8(_fromHexChar(src[2 * i])) << 4) | uint8(_fromHexChar(src[2 * i + 1]))
            );
        }
    }

    function _stripHexPrefixAndNewlines(string memory s) internal pure returns (string memory) {
        bytes memory b = bytes(s);
        uint256 start = 0;
        uint256 end = b.length;
        if (end >= 2 && b[0] == "0" && (b[1] == "x" || b[1] == "X")) {
            start = 2;
        }
        // Remove all newlines and carriage returns
        bytes memory tmp = new bytes(end - start);
        uint256 j;
        for (uint256 i = start; i < end; i++) {
            bytes1 c = b[i];
            if (c != 0x0a && c != 0x0d) {
                tmp[j++] = c;
            }
        }
        bytes memory out = new bytes(j);
        for (uint256 i = 0; i < j; i++) out[i] = tmp[i];
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



