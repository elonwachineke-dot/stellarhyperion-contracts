// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    ActionKind,
    AdminAction,
    ClaimSettlementResult,
    ClaimSettlementStatus,
    Origin,
    RouteKind
} from "../../src/HyperionTypes.sol";
import {Fixture} from "../Fixture.sol";
import {VmSafe} from "forge-std/Vm.sol";

abstract contract RouterGasBudgetFixture is Fixture {
    uint256 internal constant GAS_TOLERANCE_BPS = 2500;
    uint256 internal constant DELIVERY_AMOUNT = 500e6;

    function setUp() public virtual override {
        super.setUp();
        usdc.mint(railReceiver, 1_000_000e6);
        vm.prank(railReceiver);
        usdc.approve(address(router), type(uint256).max);
    }

    /// @dev Clear setup/previous-call access warmth without changing contract state.
    function _coolRouterContracts() internal {
        address provenance =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(router), hex"01")))));
        vm.cool(address(router));
        vm.cool(address(usdc));
        vm.cool(address(recoveryManager));
        vm.cool(provenance);
    }

    function _deliver(address recipient, uint64 nonce) internal returns (uint64 claimId, uint256 gasUsed) {
        Origin memory origin = Origin({
            chain: STELLAR,
            nonce: nonce,
            messageId: keccak256(abi.encode("gas-budget-message", nonce)),
            sender: keccak256(abi.encode("gas-budget-sender", nonce))
        });
        vm.prank(railReceiver);
        uint256 gasBefore = gasleft();
        claimId = router.bridgeIn(RouteKind.Cctp, address(usdc), DELIVERY_AMOUNT, recipient, origin);
        gasUsed = gasBefore - gasleft();
    }

    function _settle(uint64[] memory claimIds)
        internal
        returns (ClaimSettlementResult[] memory results, uint256 gasUsed)
    {
        uint256 gasBefore = gasleft();
        results = router.settleClaims(claimIds);
        gasUsed = gasBefore - gasleft();
    }

    function _claimRange(uint64 first, uint256 count) internal pure returns (uint64[] memory claimIds) {
        claimIds = new uint64[](count);
        for (uint64 i; i < count; ++i) {
            claimIds[i] = first + i;
        }
    }

    function _assertSettled(ClaimSettlementResult[] memory results, ClaimSettlementStatus expected)
        internal
        pure
    {
        for (uint256 i; i < results.length; ++i) {
            assertEq(uint8(results[i].status), uint8(expected));
        }
    }

    function _report(string memory caseName, uint256 gasUsed, uint256 baseline) internal {
        uint256 budget = baseline + (baseline * GAS_TOLERANCE_BPS / 10_000);
        emit log_named_uint(string.concat("HYPERION_GAS case=", caseName), gasUsed);
        emit log_named_uint(string.concat("HYPERION_GAS_BUDGET case=", caseName), budget);
        // Coverage instruments a different profile; production ceilings apply to tests and snapshots.
        if (!vm.isContext(VmSafe.ForgeContext.Coverage)) {
            assertLe(gasUsed, budget, string.concat(caseName, " exceeded its gas budget"));
        }
    }
}

contract RouterGasBudgetTest is RouterGasBudgetFixture {
    uint256 private constant GOVERNANCE_ACTIONS = 16;
    uint256 private constant CLAIM_GROWTH = 32;

    uint256 private constant QUEUE_COLD_BASELINE = 120_000;
    uint256 private constant QUEUE_WARM_BASELINE = 117_000;
    uint256 private constant INBOUND_NORMAL_COLD_BASELINE = 118_000;
    uint256 private constant INBOUND_NORMAL_WARM_BASELINE = 99_000;
    uint256 private constant INBOUND_PARKED_COLD_BASELINE = 288_000;
    uint256 private constant INBOUND_PARKED_WARM_BASELINE = 254_000;

    function test_governanceQueueGasBudgetAtGrowingActionCount() public {
        uint64[] memory ids = new uint64[](GOVERNANCE_ACTIONS);
        _coolRouterContracts();
        for (uint256 i; i < GOVERNANCE_ACTIONS; ++i) {
            AdminAction memory action = _empty(ActionKind.SetFeeBps);
            action.amount = 20 + i;
            uint256 gasUsed;
            (ids[i], gasUsed) = _queue(action);
            if (i == 0) _report("governance.queue.cold_first_new_record", gasUsed, QUEUE_COLD_BASELINE);
            if (i == GOVERNANCE_ACTIONS - 1) {
                _report("governance.queue.warm_after_16_actions", gasUsed, QUEUE_WARM_BASELINE);
            }
        }
    }

    function test_inboundGasBudgetsAtGrowingClaimCount() public {
        _coolRouterContracts();
        (uint64 normalClaim, uint256 gasUsed) = _deliver(bob, 1);
        assertEq(normalClaim, 0);
        _report("inbound.normal.cold_first", gasUsed, INBOUND_NORMAL_COLD_BASELINE);

        (normalClaim, gasUsed) = _deliver(bob, 2);
        assertEq(normalClaim, 0);
        _report("inbound.normal.shared_storage_warm", gasUsed, INBOUND_NORMAL_WARM_BASELINE);

        usdc.setBlocked(bob, true);
        _coolRouterContracts();
        for (uint64 i; i < CLAIM_GROWTH; ++i) {
            uint64 claimId;
            (claimId, gasUsed) = _deliver(bob, i + 3);
            assertEq(claimId, i + 1);
            if (i == 0) _report("inbound.parked.cold_first_claim", gasUsed, INBOUND_PARKED_COLD_BASELINE);
            if (i == CLAIM_GROWTH - 1) {
                _report("inbound.parked.warm_after_32_claims", gasUsed, INBOUND_PARKED_WARM_BASELINE);
            }
        }

        assertEq(router.claimCount(), CLAIM_GROWTH);
        assertEq(recoveryManager.claimLiability(address(usdc)), CLAIM_GROWTH * DELIVERY_AMOUNT);
        assertEq(usdc.balanceOf(address(router)), CLAIM_GROWTH * DELIVERY_AMOUNT);
    }

    function _queue(AdminAction memory action) private returns (uint64 id, uint256 gasUsed) {
        vm.prank(admin);
        uint256 gasBefore = gasleft();
        id = router.queueAction(action);
        gasUsed = gasBefore - gasleft();
    }
}

contract RouterGovernanceExecutionGasBudgetTest is RouterGasBudgetFixture {
    uint256 private constant GOVERNANCE_ACTIONS = 16;
    uint256 private constant EXECUTE_COLD_BASELINE = 64_000;
    uint256 private constant EXECUTE_WARM_BASELINE = 61_000;
    uint64[] private actionIds;

    /// @dev Mature proposals before the measured test, preserving their original packed storage.
    function setUp() public override {
        super.setUp();
        for (uint256 i; i < GOVERNANCE_ACTIONS; ++i) {
            AdminAction memory action = _empty(ActionKind.SetFeeBps);
            action.amount = 20 + i;
            vm.prank(admin);
            actionIds.push(router.queueAction(action));
        }
        vm.warp(block.timestamp + TIMELOCK + 1);
        assertEq(router.feeBps(), FEE_BPS);
    }

    function test_governanceExecutionColdAndWarmGasBudgetsWithPersistedActions() public {
        _coolRouterContracts();
        uint256 coldGas;
        uint256 warmGas;
        for (uint256 i; i < GOVERNANCE_ACTIONS; ++i) {
            uint256 gasUsed = _execute(actionIds[i]);
            if (i == 0) {
                coldGas = gasUsed;
                _report("governance.execute.cold_first_record", gasUsed, EXECUTE_COLD_BASELINE);
            }
            if (i == GOVERNANCE_ACTIONS - 1) {
                warmGas = gasUsed;
                _report("governance.execute.warm_after_16_actions", gasUsed, EXECUTE_WARM_BASELINE);
            }
        }
        assertLt(warmGas, coldGas, "shared storage warmth must reduce execution gas");
        assertEq(router.feeBps(), 20 + GOVERNANCE_ACTIONS - 1);
    }

    function _execute(uint64 id) private returns (uint256 gasUsed) {
        vm.prank(admin);
        uint256 gasBefore = gasleft();
        router.executeAction(id);
        gasUsed = gasBefore - gasleft();
    }
}

contract RouterSettlementGasBudgetTest is RouterGasBudgetFixture {
    uint256 private constant CLAIM_GROWTH = 32;
    uint256 private constant HOSTILE_CLAIMS = 4;
    uint256 private constant SETTLEMENT_BATCH = 10;
    uint256 private constant SETTLEMENT_NORMAL_COLD_BASELINE = 360_000;
    uint256 private constant SETTLEMENT_NORMAL_WARM_BASELINE = 330_000;
    uint256 private constant SETTLEMENT_HOSTILE_COLD_BASELINE = 116_000;
    uint256 private constant SETTLEMENT_HOSTILE_WARM_BASELINE = 113_000;

    /// @dev Persist claims before the measured test, preserving realistic original SSTORE values.
    function setUp() public override {
        super.setUp();
        usdc.setBlocked(bob, true);
        usdc.setBlocked(alice, true);
        for (uint64 i; i < CLAIM_GROWTH + HOSTILE_CLAIMS; ++i) {
            (uint64 claimId,) = _deliver(i < CLAIM_GROWTH ? bob : alice, i + 1);
            assertEq(claimId, i + 1);
        }
        usdc.setBlocked(bob, false);
        // Both normal batches begin with a nonzero recipient balance.
        usdc.mint(bob, 1);
        assertEq(router.claimCount(), CLAIM_GROWTH + HOSTILE_CLAIMS);
        assertEq(
            recoveryManager.claimLiability(address(usdc)), (CLAIM_GROWTH + HOSTILE_CLAIMS) * DELIVERY_AMOUNT
        );
        assertEq(usdc.balanceOf(address(router)), (CLAIM_GROWTH + HOSTILE_CLAIMS) * DELIVERY_AMOUNT);
    }

    function test_normalSettlementColdAndWarmGasBudgetsWithPersistedClaims() public {
        uint64[] memory firstBatch = _claimRange(1, SETTLEMENT_BATCH);
        uint64[] memory secondBatch = _claimRange(11, SETTLEMENT_BATCH);
        // Untouched second-batch records stay cold while first-batch shared state becomes warm.
        _coolRouterContracts();
        (ClaimSettlementResult[] memory results, uint256 coldGas) = _settle(firstBatch);
        _assertSettled(results, ClaimSettlementStatus.Settled);
        _report("settlement.normal.cold_claims_batch_10", coldGas, SETTLEMENT_NORMAL_COLD_BASELINE);

        uint256 warmGas;
        (results, warmGas) = _settle(secondBatch);
        _assertSettled(results, ClaimSettlementStatus.Settled);
        _report("settlement.normal.warm_shared_storage_batch_10", warmGas, SETTLEMENT_NORMAL_WARM_BASELINE);
        assertLt(warmGas, coldGas, "shared storage warmth must reduce otherwise equal batches");
        assertEq(usdc.balanceOf(bob), 1 + 2 * SETTLEMENT_BATCH * DELIVERY_AMOUNT);
        assertEq(
            recoveryManager.claimLiability(address(usdc)),
            (CLAIM_GROWTH + HOSTILE_CLAIMS - 2 * SETTLEMENT_BATCH) * DELIVERY_AMOUNT
        );
    }

    function test_hostileSettlementColdAndWarmGasBudgetsWithPersistedClaims() public {
        uint64[] memory firstBatch = _claimRange(33, 2);
        uint64[] memory secondBatch = _claimRange(35, 2);
        _coolRouterContracts();
        (ClaimSettlementResult[] memory results, uint256 coldGas) = _settle(firstBatch);
        _assertSettled(results, ClaimSettlementStatus.RecipientRestricted);
        _report("settlement.hostile.cold_claims_batch_2", coldGas, SETTLEMENT_HOSTILE_COLD_BASELINE);

        uint256 warmGas;
        (results, warmGas) = _settle(secondBatch);
        _assertSettled(results, ClaimSettlementStatus.RecipientRestricted);
        _report("settlement.hostile.warm_shared_storage_batch_2", warmGas, SETTLEMENT_HOSTILE_WARM_BASELINE);
        assertLt(warmGas, coldGas, "shared storage warmth must reduce otherwise equal batches");
        assertEq(usdc.balanceOf(alice), 10_000_000e6);
        assertEq(
            recoveryManager.claimLiability(address(usdc)), (CLAIM_GROWTH + HOSTILE_CLAIMS) * DELIVERY_AMOUNT
        );
        for (uint64 id = 33; id <= 36; ++id) {
            assertFalse(router.pendingClaim(id).settled);
        }
    }
}
