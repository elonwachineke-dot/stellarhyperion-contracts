// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    InvalidAmount,
    RecoveryExceedsSurplus,
    TimelockAlreadyExecuted,
    TimelockExpired,
    TimelockNotQueued,
    TimelockNotReady,
    TokenRecoveryForbidden,
    Unauthorized
} from "../../src/HyperionErrors.sol";
import {Origin, OutboundRequest, QueuedTokenRecovery, RouteKind} from "../../src/HyperionTypes.sol";
import {IHyperionRouter} from "../../src/interfaces/IHyperionRouter.sol";
import {ITokenRecoveryManager} from "../../src/interfaces/ITokenRecoveryManager.sol";
import {Fixture} from "../Fixture.sol";
import {FeeOnTransferToken} from "../mocks/HostileCallers.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin/token/ERC20/IERC20.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";

contract RecoveryCallbackToken is ERC20 {
    IHyperionRouter private target;
    uint64 private settlementClaim;
    OutboundRequest private dispatchRequest;
    bool public dispatchReentrySucceeded;
    bool public settlementReentrySucceeded;
    bool public recoveryReentrySucceeded;
    bytes public dispatchReentryData;
    bytes public settlementReentryData;
    bytes public recoveryReentryData;

    constructor() ERC20("Recovery callback", "RCB") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setTarget(IHyperionRouter router, uint64 claimId, OutboundRequest calldata request) external {
        target = router;
        settlementClaim = claimId;
        dispatchRequest = request;
        IERC20(request.token).approve(address(router), type(uint256).max);
    }

    function dispatchOutsideRecovery() external returns (uint64) {
        return target.bridgeOut(dispatchRequest);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        OutboundRequest memory request = dispatchRequest;
        (dispatchReentrySucceeded, dispatchReentryData) =
            address(target).call(abi.encodeCall(IHyperionRouter.bridgeOut, (request)));
        (settlementReentrySucceeded, settlementReentryData) =
            address(target).call(abi.encodeCall(IHyperionRouter.settleClaim, (settlementClaim)));
        (recoveryReentrySucceeded, recoveryReentryData) = address(target)
            .call(abi.encodeCall(IHyperionRouter.completeTokenRecovery, (address(this), to, amount)));
        return super.transfer(to, amount);
    }
}

contract RouterRecoveryTest is Fixture {
    uint64 private constant SOURCE_NONCE = 42;
    uint256 private constant DELIVERY_AMOUNT = 500e6;

    function test_registered_tokens_cannot_be_recovered_and_only_admin_can_queue() public {
        MockERC20 extra = new MockERC20("Extra", "EXT", USDC_DECIMALS);
        extra.mint(address(router), 100);

        vm.expectRevert(Unauthorized.selector);
        vm.prank(stranger);
        recoveryManager.queueTokenRecovery(address(extra), bob, 1);

        vm.expectRevert(TokenRecoveryForbidden.selector);
        vm.prank(admin);
        recoveryManager.queueTokenRecovery(address(usdc), bob, 1);
        assertEq(recoveryManager.tokenRecoveryCount(), 0);

        _setTokenEnabled(address(usdc), false);
        vm.expectRevert(TokenRecoveryForbidden.selector);
        vm.prank(admin);
        recoveryManager.queueTokenRecovery(address(usdc), bob, 1);
    }

    function test_recovery_is_timelocked_observable_and_cancellable_by_guardian() public {
        MockERC20 extra = new MockERC20("Extra", "EXT", USDC_DECIMALS);
        extra.mint(address(router), 100);

        vm.expectEmit(true, true, true, true, address(recoveryManager));
        emit ITokenRecoveryManager.TokenRecoveryQueued(
            1,
            address(extra),
            bob,
            50,
            uint64(block.timestamp) + TIMELOCK,
            uint64(block.timestamp) + TIMELOCK + 7 days
        );
        vm.prank(admin);
        uint64 id = recoveryManager.queueTokenRecovery(address(extra), bob, 50);

        QueuedTokenRecovery memory recovery = recoveryManager.queuedTokenRecovery(id);
        assertEq(recovery.id, id);
        assertEq(recovery.token, address(extra));
        assertEq(recovery.recipient, bob);
        assertEq(recovery.amount, 50);
        assertFalse(recovery.executed);
        assertFalse(recovery.cancelled);

        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(TimelockNotReady.selector, recovery.eta));
        recoveryManager.executeTokenRecovery(id);

        vm.expectEmit(true, true, false, true, address(recoveryManager));
        emit ITokenRecoveryManager.TokenRecoveryCancelled(id, guardian);
        vm.prank(guardian);
        recoveryManager.cancelTokenRecovery(id);
        assertTrue(recoveryManager.queuedTokenRecovery(id).cancelled);

        vm.warp(recovery.eta);
        vm.expectRevert(TimelockNotQueued.selector);
        vm.prank(admin);
        recoveryManager.executeTokenRecovery(id);
        assertEq(extra.balanceOf(address(router)), 100);
        assertEq(extra.balanceOf(bob), 0);
    }

    function test_claim_liability_is_reserved_from_recovery_and_remains_settleable() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        token.configure(bob, 0, false, false);
        token.mint(railReceiver, DELIVERY_AMOUNT * 2);
        vm.prank(railReceiver);
        token.approve(address(router), type(uint256).max);
        token.setBlocked(bob, true);

        vm.prank(railReceiver);
        uint64 claimId = router.bridgeIn(
            RouteKind.Cctp, address(token), DELIVERY_AMOUNT, bob, _origin(keccak256("recovery liability"))
        );
        assertEq(claimId, 1);
        assertEq(recoveryManager.claimLiability(address(token)), DELIVERY_AMOUNT);

        uint256 accidentalSurplus = 25e6;
        token.mint(address(router), accidentalSurplus);
        vm.expectRevert(RecoveryExceedsSurplus.selector);
        vm.prank(admin);
        recoveryManager.queueTokenRecovery(address(token), stranger, accidentalSurplus + 1);

        vm.prank(admin);
        uint64 recoveryId = recoveryManager.queueTokenRecovery(address(token), stranger, accidentalSurplus);
        vm.warp(recoveryManager.queuedTokenRecovery(recoveryId).eta);
        vm.prank(admin);
        recoveryManager.executeTokenRecovery(recoveryId);

        assertEq(token.balanceOf(address(router)), DELIVERY_AMOUNT);
        assertEq(token.balanceOf(stranger), accidentalSurplus);
        assertEq(recoveryManager.claimLiability(address(token)), DELIVERY_AMOUNT);

        token.setBlocked(bob, false);
        router.settleClaim(claimId);
        assertEq(token.balanceOf(bob), DELIVERY_AMOUNT);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(recoveryManager.claimLiability(address(token)), 0);
    }

    function test_hostile_token_callbacks_cannot_reenter_protected_router_operations() public {
        usdc.mint(railReceiver, DELIVERY_AMOUNT);
        vm.prank(railReceiver);
        usdc.approve(address(router), type(uint256).max);
        usdc.setBlocked(bob, true);
        vm.prank(railReceiver);
        uint64 claimId = router.bridgeIn(
            RouteKind.Cctp, address(usdc), DELIVERY_AMOUNT, bob, _origin(keccak256("callback claim"))
        );
        usdc.setBlocked(bob, false);

        RecoveryCallbackToken token = new RecoveryCallbackToken();
        usdc.mint(address(token), 10e6);
        token.setTarget(IHyperionRouter(address(router)), claimId, _usdcRequest(1e6));
        token.mint(address(router), 100);

        vm.prank(admin);
        uint64 id = recoveryManager.queueTokenRecovery(address(token), bob, 40);
        vm.warp(recoveryManager.queuedTokenRecovery(id).eta);
        vm.expectEmit(true, true, true, true, address(recoveryManager));
        emit ITokenRecoveryManager.TokenRecovered(id, address(token), bob, 40);
        vm.prank(admin);
        recoveryManager.executeTokenRecovery(id);

        assertFalse(token.dispatchReentrySucceeded());
        assertFalse(token.settlementReentrySucceeded());
        assertFalse(token.recoveryReentrySucceeded());
        bytes memory guardError =
            abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(token.dispatchReentryData(), guardError);
        assertEq(token.settlementReentryData(), guardError);
        assertEq(token.recoveryReentryData(), guardError);
        assertFalse(router.pendingClaim(claimId).settled);
        assertEq(recoveryManager.claimLiability(address(usdc)), DELIVERY_AMOUNT);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(usdc.balanceOf(address(token)), 10e6);
        assertEq(token.balanceOf(address(router)), 60);
        assertEq(token.balanceOf(bob), 40);
        assertTrue(recoveryManager.queuedTokenRecovery(id).executed);

        router.settleClaim(claimId);
        assertEq(usdc.balanceOf(bob), DELIVERY_AMOUNT);
        assertEq(recoveryManager.claimLiability(address(usdc)), 0);
        token.dispatchOutsideRecovery();
        assertEq(usdc.balanceOf(address(token)), 9e6);
    }

    function test_only_router_can_change_claim_liabilities() public {
        vm.expectRevert(Unauthorized.selector);
        recoveryManager.recordClaim(address(usdc), 1);
        vm.expectRevert(Unauthorized.selector);
        recoveryManager.releaseClaim(address(usdc), 1);
        assertEq(recoveryManager.claimLiability(address(usdc)), 0);
    }

    function test_execution_requires_admin_and_cannot_repeat() public {
        MockERC20 extra = new MockERC20("Extra", "EXT", USDC_DECIMALS);
        extra.mint(address(router), 100);
        vm.prank(admin);
        uint64 id = recoveryManager.queueTokenRecovery(address(extra), bob, 40);
        vm.warp(recoveryManager.queuedTokenRecovery(id).eta);

        vm.expectRevert(Unauthorized.selector);
        vm.prank(stranger);
        recoveryManager.executeTokenRecovery(id);
        assertFalse(recoveryManager.queuedTokenRecovery(id).executed);
        assertEq(extra.balanceOf(address(router)), 100);

        vm.prank(admin);
        recoveryManager.executeTokenRecovery(id);
        vm.expectRevert(TimelockAlreadyExecuted.selector);
        vm.prank(admin);
        recoveryManager.executeTokenRecovery(id);
        assertEq(extra.balanceOf(bob), 40);
        assertEq(extra.balanceOf(address(router)), 60);
    }

    function test_expired_recovery_cannot_move_custody() public {
        MockERC20 extra = new MockERC20("Extra", "EXT", USDC_DECIMALS);
        extra.mint(address(router), 100);
        vm.prank(admin);
        uint64 id = recoveryManager.queueTokenRecovery(address(extra), bob, 40);
        uint64 expiresAt = recoveryManager.queuedTokenRecovery(id).expiresAt;
        vm.warp(uint256(expiresAt) + 1);
        vm.expectRevert(abi.encodeWithSelector(TimelockExpired.selector, expiresAt));
        vm.prank(admin);
        recoveryManager.executeTokenRecovery(id);
        assertFalse(recoveryManager.queuedTokenRecovery(id).executed);
        assertEq(extra.balanceOf(address(router)), 100);
        assertEq(extra.balanceOf(bob), 0);
    }

    function test_registration_after_queue_prevents_recovery_execution() public {
        MockERC20 extra = new MockERC20("Extra", "EXT", USDC_DECIMALS);
        extra.mint(address(router), 100);
        vm.prank(admin);
        uint64 id = recoveryManager.queueTokenRecovery(address(extra), bob, 40);
        _registerToken(address(extra), USDC_DECIMALS, FLOW_LIMIT);
        vm.expectRevert(TokenRecoveryForbidden.selector);
        vm.prank(admin);
        recoveryManager.executeTokenRecovery(id);
        assertFalse(recoveryManager.queuedTokenRecovery(id).executed);
        assertEq(extra.balanceOf(address(router)), 100);
        assertEq(extra.balanceOf(bob), 0);
    }

    function test_competing_proposals_cannot_recover_more_than_current_surplus() public {
        MockERC20 extra = new MockERC20("Extra", "EXT", USDC_DECIMALS);
        extra.mint(address(router), 100);
        vm.startPrank(admin);
        uint64 first = recoveryManager.queueTokenRecovery(address(extra), bob, 60);
        uint64 second = recoveryManager.queueTokenRecovery(address(extra), stranger, 60);
        vm.stopPrank();
        vm.warp(recoveryManager.queuedTokenRecovery(first).eta);
        vm.prank(admin);
        recoveryManager.executeTokenRecovery(first);
        vm.expectRevert(RecoveryExceedsSurplus.selector);
        vm.prank(admin);
        recoveryManager.executeTokenRecovery(second);
        assertFalse(recoveryManager.queuedTokenRecovery(second).executed);
        assertEq(extra.balanceOf(address(router)), 40);
        assertEq(extra.balanceOf(stranger), 0);
    }

    function test_inexact_recovery_rolls_back_proposal_and_all_token_balances_then_retries() public {
        FeeOnTransferToken token = new FeeOnTransferToken();
        token.mint(address(router), 100);
        token.configure(bob, 500, false, false);
        vm.prank(admin);
        uint64 id = recoveryManager.queueTokenRecovery(address(token), bob, 40);
        vm.warp(recoveryManager.queuedTokenRecovery(id).eta);
        vm.expectRevert(InvalidAmount.selector);
        vm.prank(admin);
        recoveryManager.executeTokenRecovery(id);
        assertFalse(recoveryManager.queuedTokenRecovery(id).executed);
        assertEq(token.balanceOf(address(router)), 100);
        assertEq(token.balanceOf(bob), 0);
        assertEq(token.balanceOf(address(0xdead)), 0);

        token.configure(bob, 0, false, false);
        vm.prank(admin);
        recoveryManager.executeTokenRecovery(id);
        assertTrue(recoveryManager.queuedTokenRecovery(id).executed);
        assertEq(token.balanceOf(address(router)), 60);
        assertEq(token.balanceOf(bob), 40);
    }

    function _origin(bytes32 messageId) private pure returns (Origin memory) {
        return Origin({
            chain: STELLAR,
            nonce: SOURCE_NONCE,
            messageId: messageId,
            sender: keccak256(abi.encodePacked(C_ADDR))
        });
    }
}
