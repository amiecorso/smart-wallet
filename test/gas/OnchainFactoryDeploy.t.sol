// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "../CoinbaseSmartWallet/SmartWalletTestBase.sol";

interface IOnchainFactory {
    function createAccount(bytes[] memory owners, uint256 threshold) external returns (address);
    function implementation() external view returns (address);
}

contract OnchainFactoryDeploy is SmartWalletTestBase {
    address internal factoryAddress;
    address internal implementationAddress;

    function setUp() public override {
        super.setUp();
        string memory implPath = vm.envOr("FIXED_IMPL_PATH", string(""));
        string memory factoryPath = vm.envOr("FIXED_FACTORY_PATH", string(""));
        require(bytes(implPath).length != 0, "FIXED_IMPL_PATH not set");
        require(bytes(factoryPath).length != 0, "FIXED_FACTORY_PATH not set");

        // Factory can be etched at any address (or supplied via env FIXED_FACTORY_ADDRESS).
        string memory facAddrStr = vm.envOr("FIXED_FACTORY_ADDRESS", string("0xF000000000000000000000000000000000000001"));
        factoryAddress = vm.parseAddress(facAddrStr);

        bytes memory facRuntime = _readHexFile(factoryPath);
        vm.etch(factoryAddress, facRuntime);

        // Query the baked implementation address from the runtime factory.
        implementationAddress = IOnchainFactory(factoryAddress).implementation();
        bytes memory implRuntime = _readHexFile(implPath);
        vm.etch(implementationAddress, implRuntime);
    }

    function test_factoryDeploysProxyWallet_onchainRuntime() public {
        // Use existing owners array from base; threshold = 1
        bytes[] memory ownersLocal = owners;
        uint256 threshold = 1;
        address deployed = IOnchainFactory(factoryAddress).createAccount(ownersLocal, threshold);
        // Ensure the deployed proxy has code
        assertGt(deployed.code.length, 0, "proxy not deployed");
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


