// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {stdJson} from "forge-std/StdJson.sol";
import {console} from "forge-std/console.sol";

import {HyperionRouter} from "../src/HyperionRouter.sol";
import {RouteKind} from "../src/HyperionTypes.sol";
import {OutboundProvenance} from "../src/OutboundProvenance.sol";
import {TokenRecoveryManager} from "../src/TokenRecoveryManager.sol";
import {AxelarItsAdapter} from "../src/adapters/AxelarItsAdapter.sol";
import {CctpAdapter} from "../src/adapters/CctpAdapter.sol";

import {DeployConfig} from "./DeployConfig.sol";

/// @title Read a live deployment back and check it against the record
/// @author dotmantissa
/// @notice Signs nothing and sends nothing. Every value below is read off the chain and compared
/// against the file, and the script fails if any of them disagree.
///
/// Worth having as its own script rather than a tail on the deploy, because the question "is the
/// thing on chain still what we wrote down" is one somebody asks weeks later, during an incident,
/// from a laptop that never ran the deployment. It should not require reading nine `cast call`
/// invocations off a wiki.
///
/// Usage:
///   forge script script/Verify.s.sol --rpc-url $RPC
contract Verify is DeployConfig {
    using stdJson for string;

    uint256 internal problems;

    function run() external {
        problems = 0;
        string memory path = vm.envOr(
            "HYPERION_RECORD", string.concat("deployments/evm-", vm.toString(block.chainid), "-phase1.json")
        );
        string memory record = vm.readFile(path);

        HyperionRouter router = HyperionRouter(payable(record.readAddress(".router")));
        CctpAdapter cctp = CctpAdapter(payable(record.readAddress(".cctpAdapter")));

        console.log("record              ", path);
        console.log("router              ", address(router));
        console.log("");

        _expectUint("chain id", block.chainid, record.readUint(".chainId"));
        _verifyProvenance(record, router);
        _verifyRecoveryManager(record, router);
        CompatibilityProfile memory profile =
            _verifiedArtifactProfile(vm.getArtifactPathByCode(type(HyperionRouter).creationCode));
        _verifiedArtifactProfile(vm.getArtifactPathByCode(type(CctpAdapter).creationCode));
        if (vm.keyExistsJson(record, ".axelarAdapter")) {
            _verifiedArtifactProfile(vm.getArtifactPathByCode(type(AxelarItsAdapter).creationCode));
        }
        _expectString("EVM revision", record.readString(".evmVersion"), profile.evmVersion);
        _expectString("compiler revision", record.readString(".solcVersion"), profile.compilerVersion);
        _expectUint("optimizer runs", record.readUint(".optimizerRuns"), profile.optimizerRuns);
        _expectTrue("via IR matches artifact", record.readBool(".viaIR") == profile.viaIR);
        _expectAddress("treasury", router.treasury(), record.readAddress(".treasury"));
        _expectUint("fee bps", router.feeBps(), record.readUint(".feeBps"));
        _expectUint("timelock delay", router.timelockDelay(), record.readUint(".timelockDelay"));
        _expectUint("flow window", router.flowWindow(), record.readUint(".flowWindow"));

        _expectAddress("cctp adapter", router.adapter(RouteKind.Cctp), address(cctp));
        _expectAddress("cctp receiver", router.railReceiver(RouteKind.Cctp), address(cctp));
        _expectTrue("cctp route enabled", router.routeEnabled(RouteKind.Cctp));
        _expectAddress("cctp adapter router", cctp.ROUTER(), address(router));
        _expectAddress(
            "cctp token messenger", address(cctp.TOKEN_MESSENGER()), record.readAddress(".cctpTokenMessenger")
        );

        // The lane is the value a wrong entry costs the most: it decides who Circle credits.
        CctpAdapter.Lane memory lane = cctp.laneOf(record.readString(".stellarChain"));
        _expectTrue("cctp lane configured", lane.configured);
        _expectTrue("cctp lane enabled", lane.enabled);
        _expectUint("cctp lane domain", lane.domain, STELLAR_CCTP_DOMAIN);
        bytes32 recordedRecipient = record.readBytes32(".stellarRailRecipient");
        _expectBytes32("cctp mint recipient", lane.mintRecipient, recordedRecipient);

        address token = record.readAddress(".token");
        _expectTrue("token registered", router.tokenConfig(token).registered);
        _expectTrue("token enabled", router.tokenConfig(token).enabled);
        _expectUint("token decimals", router.tokenConfig(token).decimals, record.readUint(".tokenDecimals"));
        _expectUint(
            "token flow limit", router.tokenConfig(token).flowLimit, record.readUint(".tokenFlowLimit")
        );

        _expectFalse("router paused", router.paused());

        _verifyAxelar(record, router, token);
        _verifyAuthority(record, router);

        console.log("");
        if (problems == 0) {
            console.log("Everything on chain matches the record.");
        } else {
            console.log("Mismatches          ", problems);
            revert("the chain and the record disagree");
        }
    }

    function _verifyProvenance(string memory record, HyperionRouter router) internal {
        address expected =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(router), hex"01")))));
        address recorded = record.readAddress(".provenanceStore");
        _expectAddress("immutable provenance address", recorded, expected);
        _expectTrue("immutable provenance code exists", expected.code.length != 0);
        _expectBytes32(
            "immutable provenance code hash",
            expected.codehash,
            record.readBytes32(".provenanceStoreCodeHash")
        );
        if (expected.code.length != 0) {
            _expectAddress(
                "immutable provenance router", OutboundProvenance(expected).ROUTER(), address(router)
            );
        }
    }

    function _verifyRecoveryManager(string memory record, HyperionRouter router) internal {
        address expected =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(router), hex"02")))));
        bool hasAddress = vm.keyExistsJson(record, ".recoveryManager");
        bool hasCodeHash = vm.keyExistsJson(record, ".recoveryManagerCodeHash");
        require(hasAddress == hasCodeHash, "record has incomplete token recovery manager fields");
        if (!hasAddress) {
            require(expected.code.length == 0, "record lacks required token recovery manager");
            console.log("WARN legacy router record has no token recovery manager");
            return;
        }
        address recorded = record.readAddress(".recoveryManager");
        _expectAddress("immutable token recovery manager address", recorded, expected);
        _expectTrue("immutable token recovery manager code exists", expected.code.length != 0);
        _expectBytes32(
            "immutable token recovery manager code hash",
            expected.codehash,
            record.readBytes32(".recoveryManagerCodeHash")
        );
        if (expected.code.length != 0) {
            _expectAddress(
                "immutable token recovery manager router",
                TokenRecoveryManager(expected).ROUTER(),
                address(router)
            );
        }
    }

    function _verifyAxelar(string memory record, HyperionRouter router, address token) private {
        if (vm.keyExistsJson(record, ".axelarAdapter")) {
            AxelarItsAdapter axelar = AxelarItsAdapter(payable(record.readAddress(".axelarAdapter")));
            _expectAddress("axelar adapter", router.adapter(RouteKind.AxelarIts), address(axelar));
            _expectAddress("axelar receiver", router.railReceiver(RouteKind.AxelarIts), address(axelar));
            _expectTrue("axelar route enabled", router.routeEnabled(RouteKind.AxelarIts));
            _expectAddress("axelar adapter router", axelar.ROUTER(), address(router));
            _expectBytes32("axelar token id", axelar.tokenIdOf(token), record.readBytes32(".axelarTokenId"));

            AxelarItsAdapter.Peer memory peer = axelar.peerOf(record.readString(".stellarChain"));
            _expectTrue("axelar peer configured", peer.configured);
            _expectTrue("axelar peer enabled", peer.enabled);
            _expectBytes("axelar peer address", peer.peer, vm.envBytes("STELLAR_AXELAR_PEER"));
        }
    }

    function _verifyAuthority(string memory record, HyperionRouter router) private {
        // The admin handover is the one thing that cannot be checked by equality alone, because a
        // record written before the handover matured names the deployer.
        address recordedAdmin = record.readAddress(".admin");
        bool adminHolds = router.hasRole(router.DEFAULT_ADMIN_ROLE(), recordedAdmin);
        console.log(
            adminHolds
                ? "  ok   admin role held by the recorded admin"
                : "  WARN admin role not yet handed over"
        );
        if (!adminHolds) {
            problems += 1;
            console.log("       recorded admin    ", recordedAdmin);
            console.log("       deployer          ", record.readAddress(".deployer"));
            console.log("       authority policy is not satisfied");
        }

        address recordedGuardian = record.readAddress(".guardian");
        if (recordedGuardian == address(0)) {
            // AccessControl is not enumerable. A zero address alone cannot prove absence of other
            // guardians: reconstruct every grant/revoke from before deployment and fail closed
            // when history is unavailable, truncated or exceeds the bounded read window.
            _expectFalse(
                "zero address has guardian authority", router.hasRole(router.GUARDIAN_ROLE(), address(0))
            );
            _expectUint(
                "active guardians under disabled policy",
                _activeGuardianCount(router, record.readUint(".deployedAtBlock")),
                0
            );
        } else {
            _expectTrue("recorded guardian role", router.hasRole(router.GUARDIAN_ROLE(), recordedGuardian));
        }
    }

    function _activeGuardianCount(HyperionRouter router, uint256 fromBlock) private returns (uint256) {
        require(
            fromBlock <= block.number && block.number - fromBlock <= 262_144,
            "guardian history exceeds bounded verification window"
        );
        if (fromBlock > 0) {
            string memory prior = vm.rpcJson(
                "eth_getCode",
                string.concat("[\"", vm.toString(address(router)), "\",\"", _quantity(fromBlock - 1), "\"]")
            );
            require(
                keccak256(bytes(vm.parseJsonString(prior, "$"))) == keccak256(bytes("0x")),
                "guardian history starts after deployment"
            );
        }
        address[] memory members = new address[](128);
        bool[] memory active = new bool[](128);
        uint256 used;
        uint256 count;
        bytes32 granted = keccak256("RoleGranted(bytes32,address,address)");
        bytes32 revoked = keccak256("RoleRevoked(bytes32,address,address)");
        for (uint256 first = fromBlock; first <= block.number;) {
            uint256 last = first + 4095;
            if (last > block.number) last = block.number;
            string memory filter = string.concat(
                "[{\"address\":\"",
                vm.toString(address(router)),
                "\",\"fromBlock\":\"",
                _quantity(first),
                "\",\"toBlock\":\"",
                _quantity(last),
                "\",\"topics\":[[\"",
                vm.toString(granted),
                "\",\"",
                vm.toString(revoked),
                "\"],\"",
                vm.toString(router.GUARDIAN_ROLE()),
                "\"]}]"
            );
            string memory logs = vm.rpcJson("eth_getLogs", filter);
            (used, count) = _applyGuardianLogs(
                logs, address(router), router.GUARDIAN_ROLE(), members, active, used, count
            );
            if (last == block.number) break;
            first = last + 1;
        }
        for (uint256 i; i < used; ++i) {
            require(
                router.hasRole(router.GUARDIAN_ROLE(), members[i]) == active[i],
                "guardian history and live roles disagree"
            );
        }
        return count;
    }

    /// @dev Validate complete RPC arrays and apply each guardian event in canonical RPC order.
    function _applyGuardianLogs(
        string memory logs,
        address router,
        bytes32 role,
        address[] memory members,
        bool[] memory active,
        uint256 used,
        uint256 count
    ) internal view returns (uint256, uint256) {
        bytes memory raw = bytes(logs);
        require(
            raw.length >= 2 && raw.length <= 1_048_576 && raw[0] == "[" && raw[raw.length - 1] == "]",
            "guardian RPC did not return a complete bounded array"
        );
        uint256 index;
        while (vm.keyExistsJson(logs, string.concat("$[", vm.toString(index), "]"))) {
            require(index < 1024, "guardian event page exceeds 1024 entries");
            string memory key = string.concat("$[", vm.toString(index), "]");
            bytes32[] memory topics = vm.parseJsonBytes32Array(logs, string.concat(key, ".topics"));
            require(
                vm.parseJsonAddress(logs, string.concat(key, ".address")) == router && topics.length == 4
                    && topics[1] == role,
                "guardian event identity differs"
            );
            require(
                !vm.parseJsonBool(logs, string.concat(key, ".removed")),
                "removed guardian event is not canonical evidence"
            );
            require(
                vm.parseJsonBytes(logs, string.concat(key, ".data")).length == 0,
                "unexpected guardian event data"
            );
            bool grant = topics[0] == keccak256("RoleGranted(bytes32,address,address)");
            require(
                grant || topics[0] == keccak256("RoleRevoked(bytes32,address,address)"),
                "unexpected guardian event kind"
            );
            require(uint256(topics[2]) >> 160 == 0, "guardian address padding is invalid");
            address member = address(uint160(uint256(topics[2])));
            uint256 position;
            while (position < used && members[position] != member) ++position;
            if (position == used) {
                require(used < members.length, "guardian membership exceeds verification bound");
                members[used++] = member;
            }
            if (grant && !active[position]) {
                active[position] = true;
                ++count;
            } else if (!grant && active[position]) {
                active[position] = false;
                --count;
            }
            ++index;
        }
        return (used, count);
    }

    function _quantity(uint256 number) private pure returns (string memory) {
        bytes16 digits = "0123456789abcdef";
        bytes memory encoded = new bytes(64);
        uint256 length;
        do {
            encoded[63 - length++] = digits[number & 15];
            number >>= 4;
        } while (number != 0);
        bytes memory output = new bytes(length + 2);
        output[0] = "0";
        output[1] = "x";
        for (uint256 i; i < length; ++i) {
            output[i + 2] = encoded[64 - length + i];
        }
        return string(output);
    }

    function _expectAddress(string memory what, address found, address want) private {
        if (found == want) {
            console.log("  ok  ", what, found);
        } else {
            problems += 1;
            console.log("  BAD ", what);
            console.log("        found", found);
            console.log("        want ", want);
        }
    }

    function _expectUint(string memory what, uint256 found, uint256 want) private {
        if (found == want) {
            console.log("  ok  ", what, found);
        } else {
            problems += 1;
            console.log("  BAD ", what);
            console.log("        found", found);
            console.log("        want ", want);
        }
    }

    function _expectBytes32(string memory what, bytes32 found, bytes32 want) private {
        if (found == want) {
            console.log("  ok  ", what);
        } else {
            problems += 1;
            console.log("  BAD ", what);
            console.log("        found", vm.toString(found));
            console.log("        want ", vm.toString(want));
        }
    }

    function _expectBytes(string memory what, bytes memory found, bytes memory want) private {
        if (keccak256(found) == keccak256(want)) {
            console.log("  ok  ", what);
        } else {
            problems += 1;
            console.log("  BAD ", what);
            console.log("        found", vm.toString(found));
            console.log("        want ", vm.toString(want));
        }
    }

    function _expectString(string memory what, string memory found, string memory want) private {
        if (keccak256(bytes(found)) == keccak256(bytes(want))) {
            console.log("  ok  ", what, found);
        } else {
            problems += 1;
            console.log("  BAD ", what);
            console.log("        found", found);
            console.log("        want ", want);
        }
    }

    function _expectTrue(string memory what, bool found) private {
        if (found) {
            console.log("  ok  ", what);
        } else {
            problems += 1;
            console.log("  BAD ", what, "is false and should be true");
        }
    }

    function _expectFalse(string memory what, bool found) private {
        if (!found) {
            console.log("  ok  ", what, "is false");
        } else {
            problems += 1;
            console.log("  BAD ", what, "is true and should be false");
        }
    }
}
