// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Fixture} from "./Fixture.sol";

import {HyperionRouter} from "../src/HyperionRouter.sol";
import {RouteKind} from "../src/HyperionTypes.sol";
import {AxelarItsAdapter} from "../src/adapters/AxelarItsAdapter.sol";
import {CctpAdapter} from "../src/adapters/CctpAdapter.sol";
import {MockGasService} from "./mocks/MockGasService.sol";
import {MockIts} from "./mocks/MockIts.sol";
import {MockTokenMessenger} from "./mocks/MockTokenMessenger.sol";

/// @title The EVM half of the contract interface capability check
/// @notice Reads the committed snapshots and proves the deployed surfaces still back them.
/// @dev The snapshots are line oriented so the Rust, Solidity and TypeScript suites can all read
/// the same reviewed file. This suite owns the parts that only make sense on this chain: the
/// router can reach every route it advertises, each adapter reports the route it is recorded
/// under, and the development surfaces stay gated.
///
/// The method list itself is checked against the compiled ABI in `packages/protocol` and against
/// the Rust source in each contract crate; repeating an ABI enumeration here would be a third
/// parser with nothing new to say.
contract CapabilitySnapshotTest is Fixture {
    string internal constant ROUTER_SNAPSHOT = "../testdata/capabilities/evm-router.cap";
    string internal constant CCTP_SNAPSHOT = "../testdata/capabilities/evm-cctp-adapter.cap";
    string internal constant AXELAR_SNAPSHOT = "../testdata/capabilities/evm-axelar-adapter.cap";
    string internal constant RECOVERY_SNAPSHOT = "../testdata/capabilities/evm-token-recovery-manager.cap";

    function testRouterAdvertisesOnlyRoutesItCanReach() public view {
        string[] memory slugs = _values(ROUTER_SNAPSHOT, "route");
        assertGt(slugs.length, 0, "the router snapshot declares no routes");
        for (uint256 i; i < slugs.length; ++i) {
            RouteKind kind = _routeKind(slugs[i]);
            assertTrue(router.adapter(kind) != address(0), string.concat("no adapter for ", slugs[i]));
            assertTrue(router.routeEnabled(kind), string.concat("route disabled: ", slugs[i]));
        }
    }

    function testPaidEntryPointsNamedInTheSnapshotAreCallable() public view {
        string[] memory paid = _values(ROUTER_SNAPSHOT, "paid-method");
        assertEq(paid.length, 6, "unexpected number of paid entry points");
        assertTrue(_contains(paid, "bridgeOut"), "bridgeOut is not declared");
        assertTrue(_contains(paid, "bridgeOutBounded"), "bridgeOutBounded is not declared");
        assertTrue(_contains(paid, "bridgeOutWithPermit"), "bridgeOutWithPermit is not declared");
        assertTrue(_contains(paid, "bridgeOutWithRefundCredit"), "bridgeOutWithRefundCredit is not declared");
        assertTrue(_contains(paid, "bridgeOutWithIntent"), "bridgeOutWithIntent is not declared");
        assertTrue(_contains(paid, "bridgeOutWithRelayerFee"), "bridgeOutWithRelayerFee is not declared");
        // A selector reference stops compiling if the entry point is removed, which is the whole
        // point of naming them here as well as in the snapshot.
        bytes4 legacy = HyperionRouter.bridgeOut.selector;
        bytes4 bounded = HyperionRouter.bridgeOutBounded.selector;
        bytes4 permit = HyperionRouter.bridgeOutWithPermit.selector;
        bytes4 credit = HyperionRouter.bridgeOutWithRefundCredit.selector;
        bytes4 intent = HyperionRouter.bridgeOutWithIntent.selector;
        bytes4 relayerFee = HyperionRouter.bridgeOutWithRelayerFee.selector;
        assertTrue(
            legacy != bytes4(0) && bounded != bytes4(0) && permit != bytes4(0) && credit != bytes4(0)
                && intent != bytes4(0) && relayerFee != bytes4(0),
            "paid selectors are empty"
        );
    }

    function testCctpAdapterAdvertisesItsRecordedRoute() public {
        CctpAdapter cctp =
            new CctpAdapter(address(router), address(new MockTokenMessenger()), address(usdc), admin);
        string[] memory routes = _values(CCTP_SNAPSHOT, "route");
        assertEq(routes.length, 1, "the CCTP adapter serves exactly one route");
        assertEq(uint8(cctp.route()), uint8(_routeKind(routes[0])), "CCTP adapter route drifted");
    }

    function testAxelarAdapterAdvertisesItsRecordedRoute() public {
        AxelarItsAdapter axelar = new AxelarItsAdapter(
            address(router), address(new MockIts()), address(new MockGasService()), admin
        );
        string[] memory routes = _values(AXELAR_SNAPSHOT, "route");
        assertEq(routes.length, 1, "the Axelar adapter serves exactly one route");
        assertEq(uint8(axelar.route()), uint8(_routeKind(routes[0])), "Axelar adapter route drifted");
    }

    function testDevelopmentSurfacesStayGated() public view {
        // Recording an EVM surface never activates it. The active deployment is the Stellar
        // Testnet router and its ITS/CCTP adapters.
        assertEq(_single(ROUTER_SNAPSHOT, "status"), "gated", "the EVM router must stay gated");
        assertEq(_single(CCTP_SNAPSHOT, "status"), "gated", "the EVM CCTP adapter must stay gated");
        assertEq(_single(AXELAR_SNAPSHOT, "status"), "gated", "the EVM Axelar adapter must stay gated");
        assertEq(_single(RECOVERY_SNAPSHOT, "status"), "gated", "the EVM recovery manager must stay gated");
    }

    // -------------------------------------------------------------------------------------
    // Snapshot reading
    // -------------------------------------------------------------------------------------

    function _values(string memory path, string memory directive) internal view returns (string[] memory) {
        string[] memory lines = vm.split(vm.readFile(path), "\n");
        string memory prefix = string.concat(directive, " ");
        string[] memory buffer = new string[](lines.length);
        uint256 count;
        for (uint256 i; i < lines.length; ++i) {
            string memory line = _trim(vm.replace(lines[i], "\r", ""));
            if (!_startsWith(line, prefix)) continue;
            buffer[count++] = _slice(line, bytes(prefix).length);
        }
        string[] memory out = new string[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = buffer[i];
        }
        return out;
    }

    function _single(string memory path, string memory directive) internal view returns (string memory) {
        string[] memory found = _values(path, directive);
        assertEq(found.length, 1, string.concat("expected one ", directive, " line"));
        return found[0];
    }

    function _routeKind(string memory slug) internal pure returns (RouteKind) {
        bytes32 hash = keccak256(bytes(slug));
        if (hash == keccak256("cctp")) return RouteKind.Cctp;
        if (hash == keccak256("axelar-its")) return RouteKind.AxelarIts;
        if (hash == keccak256("axelar-gmp")) return RouteKind.AxelarGmp;
        if (hash == keccak256("allbridge")) return RouteKind.Allbridge;
        revert(string.concat("unknown route slug: ", slug));
    }

    function _contains(string[] memory list, string memory needle) internal pure returns (bool) {
        bytes32 wanted = keccak256(bytes(needle));
        for (uint256 i; i < list.length; ++i) {
            if (keccak256(bytes(list[i])) == wanted) return true;
        }
        return false;
    }

    function _startsWith(string memory value, string memory prefix) internal pure returns (bool) {
        bytes memory a = bytes(value);
        bytes memory b = bytes(prefix);
        if (a.length < b.length) return false;
        for (uint256 i; i < b.length; ++i) {
            if (a[i] != b[i]) return false;
        }
        return true;
    }

    function _slice(string memory value, uint256 offset) internal pure returns (string memory) {
        bytes memory a = bytes(value);
        bytes memory out = new bytes(a.length - offset);
        for (uint256 i; i < out.length; ++i) {
            out[i] = a[offset + i];
        }
        return string(out);
    }

    function _trim(string memory value) internal pure returns (string memory) {
        bytes memory a = bytes(value);
        uint256 start;
        while (start < a.length && a[start] == " ") ++start;
        uint256 end = a.length;
        while (end > start && a[end - 1] == " ") --end;
        bytes memory out = new bytes(end - start);
        for (uint256 i; i < out.length; ++i) {
            out[i] = a[start + i];
        }
        return string(out);
    }
}
