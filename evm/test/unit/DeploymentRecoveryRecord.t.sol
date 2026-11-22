// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Verify} from "../../script/Verify.s.sol";
import {HyperionRouter} from "../../src/HyperionRouter.sol";
import {TokenRecoveryManager} from "../../src/TokenRecoveryManager.sol";
import {Fixture} from "../Fixture.sol";

contract RecoveryRecordVerificationHarness is Verify {
    function verifyChildren(string calldata record, HyperionRouter router) external {
        problems = 0;
        _verifyProvenance(record, router);
        _verifyRecoveryManager(record, router);
        require(problems == 0, "deployment child record differs");
    }
}

contract DeploymentRecoveryRecordTest is Fixture {
    RecoveryRecordVerificationHarness private verifier;
    address private provenance;
    address private manager;

    function setUp() public override {
        super.setUp();
        verifier = new RecoveryRecordVerificationHarness();
        provenance = vm.computeCreateAddress(address(router), 1);
        manager = address(recoveryManager);
    }

    function test_complete_record_matches_both_real_deployed_children() public {
        verifier.verifyChildren(_record(manager, manager.codehash), router);
    }

    function test_new_router_cannot_omit_both_recovery_fields() public {
        string memory record = string.concat(_provenanceFields(), "}");
        vm.expectRevert("record lacks required token recovery manager");
        verifier.verifyChildren(record, router);
    }

    function test_partial_manager_record_is_rejected() public {
        string memory onlyAddress =
            string.concat(_provenanceFields(), ",\"recoveryManager\":\"", vm.toString(manager), "\"}");
        string memory onlyCodeHash = string.concat(
            _provenanceFields(), ",\"recoveryManagerCodeHash\":\"", vm.toString(manager.codehash), "\"}"
        );
        vm.expectRevert("record has incomplete token recovery manager fields");
        verifier.verifyChildren(onlyAddress, router);
        vm.expectRevert("record has incomplete token recovery manager fields");
        verifier.verifyChildren(onlyCodeHash, router);
    }

    function test_wrong_address_and_stale_runtime_hash_fail_verification() public {
        string memory wrongAddress = _record(stranger, manager.codehash);
        string memory wrongHash = _record(manager, bytes32(0));
        vm.expectRevert("deployment child record differs");
        verifier.verifyChildren(wrongAddress, router);
        vm.expectRevert("deployment child record differs");
        verifier.verifyChildren(wrongHash, router);
    }

    function test_matching_runtime_hash_cannot_hide_wrong_router_binding() public {
        TokenRecoveryManager wrongBinding = new TokenRecoveryManager(stranger);
        vm.etch(manager, address(wrongBinding).code);
        string memory record = _record(manager, manager.codehash);
        vm.expectRevert("deployment child record differs");
        verifier.verifyChildren(record, router);
    }

    function test_legacy_absence_is_allowed_only_when_the_recovery_child_is_absent() public {
        vm.etch(manager, hex"");
        verifier.verifyChildren(string.concat(_provenanceFields(), "}"), router);
    }

    function test_legacy_absence_still_requires_the_existing_provenance_record() public {
        vm.etch(manager, hex"");
        vm.expectRevert();
        verifier.verifyChildren("{}", router);
    }

    function _record(address recordedManager, bytes32 codeHash) private view returns (string memory) {
        return string.concat(
            _provenanceFields(),
            ",\"recoveryManager\":\"",
            vm.toString(recordedManager),
            "\",\"recoveryManagerCodeHash\":\"",
            vm.toString(codeHash),
            "\"}"
        );
    }

    function _provenanceFields() private view returns (string memory) {
        return string.concat(
            "{\"provenanceStore\":\"",
            vm.toString(provenance),
            "\",\"provenanceStoreCodeHash\":\"",
            vm.toString(provenance.codehash),
            "\""
        );
    }
}
