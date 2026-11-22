// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    AlreadyConfigured,
    ClaimAlreadySettled,
    InvalidAmount,
    MalformedMessage,
    NotMintRecipient,
    RailNotConfigured,
    ReplayedMessage,
    TokenNotMapped,
    UnexpectedRailContract,
    UnsupportedMessageVersion,
    WrongDomain
} from "../../src/HyperionErrors.sol";
import {PendingClaim, RouteKind} from "../../src/HyperionTypes.sol";
import {CctpAdapter} from "../../src/adapters/CctpAdapter.sol";
import {ReentrancyGuard} from "openzeppelin/utils/ReentrancyGuard.sol";

import {Fixture} from "../Fixture.sol";
import {MockMessageTransmitter} from "../mocks/MockMessageTransmitter.sol";
import {MockTokenMessenger} from "../mocks/MockTokenMessenger.sol";

contract CctpInboundBoundaryTest is Fixture {
    CctpAdapter private receiver;
    MockMessageTransmitter private transmitter;
    MockTokenMessenger private messenger;
    bytes32 private constant REMOTE_MESSENGER = keccak256("remote Circle messenger");
    bytes32 private constant REMOTE_ADAPTER = keccak256("remote Hyperion adapter");
    bytes32 private constant REMOTE_TOKEN = keccak256("source USDC identity");
    uint256 private constant AMOUNT = 100e6;

    function setUp() public override {
        super.setUp();
        messenger = new MockTokenMessenger();
        transmitter = new MockMessageTransmitter(address(usdc), 1);
        receiver = new CctpAdapter(address(router), address(messenger), address(usdc), admin);
        vm.startPrank(admin);
        receiver.setMessageTransmitter(address(transmitter));
        receiver.setLane(STELLAR, 27, REMOTE_ADAPTER);
        receiver.setInboundLane(27, STELLAR, REMOTE_MESSENGER, REMOTE_ADAPTER, REMOTE_TOKEN);
        vm.stopPrank();
        _setRailReceiver(RouteKind.Cctp, address(receiver));
    }

    function _message(bytes32 nonce) private view returns (bytes memory) {
        bytes memory header = abi.encodePacked(
            uint32(1),
            uint32(27),
            uint32(1),
            nonce,
            REMOTE_MESSENGER,
            bytes32(uint256(uint160(address(messenger)))),
            bytes32(0),
            uint32(2000),
            uint32(2000)
        );
        bytes memory burn = abi.encodePacked(
            uint32(1),
            REMOTE_TOKEN,
            bytes32(uint256(uint160(address(receiver)))),
            AMOUNT,
            REMOTE_ADAPTER,
            uint256(0),
            uint256(0),
            uint256(0)
        );
        return bytes.concat(header, burn, abi.encodePacked(uint8(1), bytes20(bob), uint64(42)));
    }

    function _replace(bytes memory message, uint256 offset, bytes memory value)
        private
        pure
        returns (bytes memory)
    {
        for (uint256 i; i < value.length; ++i) {
            message[offset + i] = value[i];
        }
        return message;
    }

    function _fieldError(uint256 offset) private pure returns (bytes4) {
        if (offset == 0 || offset == 148) return UnsupportedMessageVersion.selector;
        if (offset == 4) return RailNotConfigured.selector;
        if (offset == 8) return WrongDomain.selector;
        if (offset == 140 || offset == 144 || offset == 344) return MalformedMessage.selector;
        if (offset == 152) return TokenNotMapped.selector;
        if (offset == 184) return NotMintRecipient.selector;
        if (offset == 216 || offset == 280 || offset == 312) return InvalidAmount.selector;
        return UnexpectedRailContract.selector;
    }

    function test_all_provider_fields_and_hook_fail_before_mint() public {
        uint256[16] memory offsets =
            [uint256(0), 4, 8, 44, 76, 108, 140, 144, 148, 152, 184, 216, 248, 280, 312, 344];
        // A provider sentinel ensures every malformed field fails at Hyperion's boundary.
        transmitter.setShouldRevert(true);
        for (uint256 i; i < offsets.length; ++i) {
            uint256 offset = offsets[i];
            bytes memory value;
            if (offset == 0 || offset == 148) value = abi.encodePacked(uint32(2));
            else if (offset == 4 || offset == 8) value = abi.encodePacked(uint32(99));
            else if (offset == 140 || offset == 144) value = abi.encodePacked(uint32(1000));
            else if (offset == 216) value = abi.encodePacked(uint256(0));
            else if (offset == 344) value = abi.encodePacked(block.number);
            else value = abi.encodePacked(bytes32(uint256(1)));
            bytes memory malformed = _replace(_message(bytes32(i + 1)), offset, value);
            vm.expectRevert(_fieldError(offset));
            receiver.receiveMessage(malformed, hex"51");
            assertEq(transmitter.calls(), 0, "validation must precede the provider call");
        }
        bytes memory zeroRecipient = _replace(_message(bytes32(uint256(99))), 377, new bytes(20));
        vm.expectRevert();
        receiver.receiveMessage(zeroRecipient, hex"51");
        bytes memory invalidVersion = _replace(_message(bytes32(uint256(99))), 376, hex"02");
        vm.expectRevert();
        receiver.receiveMessage(invalidVersion, hex"51");
        bytes memory valid = _message(bytes32(uint256(99)));
        bytes memory truncated = new bytes(valid.length - 1);
        for (uint256 i; i < truncated.length; ++i) {
            truncated[i] = valid[i];
        }
        vm.expectRevert();
        receiver.receiveMessage(truncated, hex"51");
        vm.expectRevert();
        receiver.receiveMessage(abi.encodePacked(valid, uint8(0)), hex"51");
        bytes memory excessive = _replace(valid, 216, abi.encodePacked(uint256(type(uint128).max) + 1));
        vm.expectRevert();
        receiver.receiveMessage(excessive, hex"51");
        assertEq(transmitter.calls(), 0);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(router.claimCount(), 0);
    }

    function test_adapter_destination_caller_and_existing_custody_are_preserved() public {
        bytes32 nonce = keccak256("adapter destination caller");
        bytes memory message =
            _replace(_message(nonce), 108, abi.encodePacked(bytes32(uint256(uint160(address(receiver))))));
        usdc.mint(address(receiver), 19);
        receiver.receiveMessage(message, hex"51");
        assertEq(usdc.balanceOf(bob), AMOUNT);
        assertEq(usdc.balanceOf(address(receiver)), 19);
        assertEq(usdc.allowance(address(receiver), address(router)), 0);
    }

    function test_failed_provider_mint_recovery_is_atomic_and_retries() public {
        for (uint8 mode = 1; mode <= 8; ++mode) {
            if (mode == 6) continue;
            bytes memory message = _message(bytes32(uint256(mode)));
            uint256 beforeBalance = usdc.balanceOf(bob);
            uint256 beforeCalls = transmitter.calls();
            transmitter.setFault(mode);
            vm.expectRevert();
            receiver.receiveMessage(message, hex"51");
            assertEq(transmitter.calls(), beforeCalls);
            assertEq(usdc.balanceOf(bob), beforeBalance);
            assertEq(usdc.balanceOf(address(receiver)), 0);
            assertEq(usdc.allowance(address(receiver), address(router)), 0);
            assertEq(router.claimCount(), 0);
            transmitter.setFault(0);
            receiver.receiveMessage(message, hex"51");
            assertEq(usdc.balanceOf(bob), beforeBalance + AMOUNT);
        }
    }

    function test_router_pull_failure_restores_provider_and_replay_then_retries() public {
        bytes32 nonce = keccak256("router pull failure");
        bytes memory message = _message(nonce);
        usdc.setBlocked(address(router), true);
        vm.expectRevert();
        receiver.receiveMessage(message, hex"51");
        assertEq(transmitter.calls(), 0);
        assertFalse(transmitter.processed(nonce));
        assertFalse(router.processed(keccak256(abi.encode(RouteKind.Cctp, nonce))));
        assertEq(usdc.balanceOf(address(receiver)), 0);
        assertEq(usdc.balanceOf(address(router)), 0);
        assertEq(usdc.allowance(address(receiver), address(router)), 0);
        usdc.setBlocked(address(router), false);
        receiver.receiveMessage(message, hex"51");
        assertEq(usdc.balanceOf(bob), AMOUNT);
    }

    function test_reentrant_provider_cannot_repeat_receive() public {
        transmitter.setFault(6);
        bytes memory message = _message(keccak256("reentrant provider"));
        receiver.receiveMessage(message, hex"51");
        assertTrue(transmitter.reentryRejected());
        assertEq(transmitter.reentryError(), ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        assertEq(transmitter.calls(), 1);
        assertEq(usdc.balanceOf(bob), AMOUNT);
        vm.expectRevert(ReplayedMessage.selector);
        receiver.receiveMessage(message, hex"51");
    }

    function test_full_nonce_replay_identity_preserves_identical_display_nonce() public {
        bytes32 first = bytes32((uint256(1) << 200) | 7);
        bytes32 second = bytes32((uint256(2) << 200) | 7);
        receiver.receiveMessage(_message(first), hex"51");
        receiver.receiveMessage(_message(second), hex"51");
        assertEq(usdc.balanceOf(bob), 2 * AMOUNT);
        assertTrue(router.processed(keccak256(abi.encode(RouteKind.Cctp, first))));
        assertTrue(router.processed(keccak256(abi.encode(RouteKind.Cctp, second))));
        vm.expectRevert(ReplayedMessage.selector);
        receiver.receiveMessage(_message(first), hex"51");
    }

    function test_outbound_lane_never_commissions_or_toggles_inbound_trust() public {
        CctpAdapter fresh = new CctpAdapter(address(router), address(messenger), address(usdc), admin);
        vm.startPrank(admin);
        fresh.setMessageTransmitter(address(transmitter));
        fresh.setLane(STELLAR, 27, REMOTE_ADAPTER);
        receiver.setLaneEnabled(STELLAR, false);
        vm.stopPrank();
        vm.expectRevert(RailNotConfigured.selector);
        fresh.receiveMessage(_message(bytes32(uint256(1))), hex"51");
        receiver.receiveMessage(_message(bytes32(uint256(1))), hex"51");
        vm.prank(admin);
        receiver.setInboundLaneEnabled(27, false);
        vm.expectRevert(RailNotConfigured.selector);
        receiver.receiveMessage(_message(bytes32(uint256(2))), hex"51");
        vm.prank(admin);
        receiver.setInboundLaneEnabled(27, true);
        receiver.receiveMessage(_message(bytes32(uint256(2))), hex"51");
        vm.prank(admin);
        vm.expectRevert(AlreadyConfigured.selector);
        receiver.setInboundLane(27, STELLAR, REMOTE_ADAPTER, REMOTE_MESSENGER, REMOTE_TOKEN);
    }

    function test_accepted_claim_survives_domain_disable_and_settles_once() public {
        usdc.setBlocked(bob, true);
        bytes32 nonce = keccak256("fixed recipient claim");
        uint64 claimId = receiver.receiveMessage(_message(nonce), hex"51");
        PendingClaim memory claim = router.pendingClaim(claimId);
        assertEq(claim.recipient, bob);
        assertEq(claim.amount, AMOUNT);
        assertEq(claim.sourceNonce, 42);
        assertEq(claim.sourceChain, STELLAR);
        assertEq(uint8(claim.route), uint8(RouteKind.Cctp));
        assertTrue(router.processed(keccak256(abi.encode(RouteKind.Cctp, nonce))));
        assertEq(usdc.balanceOf(address(router)), AMOUNT);
        vm.prank(admin);
        receiver.setInboundLaneEnabled(27, false);
        usdc.setBlocked(bob, false);
        router.settleClaim(claimId);
        assertTrue(router.pendingClaim(claimId).settled);
        assertEq(usdc.balanceOf(bob), AMOUNT);
        vm.expectRevert(ClaimAlreadySettled.selector);
        router.settleClaim(claimId);
        assertEq(usdc.balanceOf(bob), AMOUNT);
    }
}
