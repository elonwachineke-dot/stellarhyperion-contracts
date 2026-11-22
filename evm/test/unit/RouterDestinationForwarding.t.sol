// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InvalidDestination, ZeroAddressKey} from "../../src/HyperionErrors.sol";
import {HyperionRouter} from "../../src/HyperionRouter.sol";
import {AddressKind} from "../../src/HyperionTypes.sol";
import {Fixture} from "../Fixture.sol";

/// @notice Exercise the actual router forwarding boundary against independent SEP-23 fixtures.
contract RouterDestinationForwardingTest is Fixture {
    function test_router_forwards_exact_account_contract_and_muxed_tuples() public view {
        bytes32 account = 0x3b9c2115c0efd344ba0a8901eb1cfe44f36cf7dbe946beb0ee4820f7ec49bf15;
        bytes32 contractId = 0x0d1ea8b866708fdad0f4ed8c677cf4fe66e56a247837266036e4e0f3d05c7b10;
        _assertTuple(G_ADDR, AddressKind.Account, account, 0);
        _assertTuple(C_ADDR, AddressKind.Contract, contractId, 0);
        _assertTuple(M_ADDR, AddressKind.MuxedAccount, account, 9_007_199_254_740_993);
    }

    function test_router_preserves_exact_parser_reverts() public view {
        _assertRevert("", InvalidDestination.selector);
        string memory badChecksum = "GA5ZYIIVYDX5GRF2BKEQD2Y47ZCPG3HX3PUUNPVQ5ZECB57MJG7RLVNV";
        _assertRevert(badChecksum, InvalidDestination.selector);
        _assertRevert("GAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAWHF", ZeroAddressKey.selector);
    }

    function _assertTuple(string memory strkey, AddressKind kind, bytes32 key, uint64 muxedId) private view {
        (bool ok, bytes memory result) =
            address(router).staticcall(abi.encodeCall(HyperionRouter.checkDestination, (strkey)));
        assertTrue(ok);
        assertEq(result.length, 96);
        assertEq(result, abi.encode(kind, key, muxedId));
        (AddressKind observedKind, bytes32 observedKey, uint64 observedId) = router.checkDestination(strkey);
        assertEq(uint8(observedKind), uint8(kind));
        assertEq(observedKey, key);
        assertEq(observedId, muxedId);
    }

    function _assertRevert(string memory strkey, bytes4 selector) private view {
        (bool ok, bytes memory result) =
            address(router).staticcall(abi.encodeCall(HyperionRouter.checkDestination, (strkey)));
        assertFalse(ok);
        assertEq(result, abi.encodeWithSelector(selector));
    }
}
