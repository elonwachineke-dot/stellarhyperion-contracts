// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    FeeTokenNotSupported,
    IntentDomainMismatch,
    IntentExpired,
    IntentNonceMismatch,
    InvalidRelayerFee,
    InvalidSignature,
    ProviderBudgetExceeded,
    RefundFailed,
    RouteIsPaused
} from "../../src/HyperionErrors.sol";
import {HyperionRouter} from "../../src/HyperionRouter.sol";
import {OutboundRecord, OutboundRequest, RouteKind, TransferIntent} from "../../src/HyperionTypes.sol";
import {Fixture} from "../Fixture.sol";
import {MockRailAdapter} from "../mocks/MockRailAdapter.sol";
import {ERC20} from "openzeppelin/token/ERC20/ERC20.sol";
import {Pausable} from "openzeppelin/utils/Pausable.sol";

contract IntentRefundReenter {
    HyperionRouter private immutable TARGET;

    constructor(HyperionRouter target) {
        TARGET = target;
    }

    receive() external payable {
        _reenter();
    }

    function _reenter() private {
        OutboundRequest memory request;
        TARGET.bridgeOutBounded(request, 0);
    }
}

/// @notice A local fee asset that models both extra sender debit and false successful transfer.
contract RelayerSkewAsset is ERC20 {
    bool public phantom;
    bool public tax;

    constructor(address holder) ERC20("Fee", "FEE") {
        _mint(holder, 10 ether);
    }

    function setMode(bool phantom_, bool tax_) external {
        phantom = phantom_;
        tax = tax_;
    }

    function transferFrom(address from, address to, uint256 amount) public override returns (bool) {
        if (phantom) return true;
        return super.transferFrom(from, to, amount);
    }

    function _update(address from, address to, uint256 amount) internal override {
        if (tax && from != address(0) && to != address(0)) super._update(from, address(0), 1);
        super._update(from, to, amount);
    }
}

contract RouterTransferIntentTest is Fixture {
    uint256 private ownerKey;

    function setUp() public override {
        (alice, ownerKey) = makeAddrAndKey("intent-owner");
        super.setUp();
        vm.deal(stranger, 10 ether);
    }

    function test_independentTypedDigestAndRelayedSenderProvenanceOnBothRails() public {
        for (uint256 i; i < 2; ++i) {
            TransferIntent memory intent = _intent();
            intent.route = RouteKind(i);
            MockRailAdapter rail = i == 0 ? cctpRail : itsRail;
            rail.setRefund(0.1 ether);
            assertEq(router.hashTransferIntent(intent), _digest(intent, block.chainid, address(router)));
            bytes memory signature = _sign(intent);
            uint256 senderBefore = usdc.balanceOf(alice);
            uint256 refundBefore = alice.balance;
            vm.prank(stranger);
            uint64 nonce = router.bridgeOutWithIntent{value: 0.2 ether}(intent, signature);
            assertEq(usdc.balanceOf(alice), senderBefore - 1000e6);
            assertEq(usdc.balanceOf(stranger), 0);
            assertEq(alice.balance, refundBefore + 0.1 ether);
            assertEq(router.intentNonce(alice), i + 1);
            OutboundRecord memory record = router.outboundRecord(nonce);
            assertEq(record.sender, alice);
            assertEq(record.adapter, address(rail));
            assertEq(record.grossAmount, 1000e6);
            assertEq(record.netAmount, 999e6);
            if (i == 1) assertEq(rail.lastCall().sender, alice);
        }
    }

    function test_everyAlteredTypedFieldIsRejectedBeforeAnyDebit() public {
        for (uint256 field; field < 13; ++field) {
            TransferIntent memory intent = _intent();
            bytes memory signature = _sign(intent);
            bytes memory expected = abi.encodeWithSelector(InvalidSignature.selector);
            if (field == 0) {
                intent.sender = bob;
            } else if (field == 1) {
                intent.token = stranger;
            } else if (field == 2) {
                ++intent.amount;
            } else if (field == 3) {
                intent.route = RouteKind.AxelarIts;
            } else if (field == 4) {
                intent.destination.chain = "stellar-testnet";
            } else if (field == 5) {
                intent.destination.strkey = C_ADDR;
            } else if (field == 6) {
                ++intent.destinationDecimals;
            } else if (field == 7) {
                ++intent.minDestinationAmount;
            } else if (field == 8) {
                ++intent.maxProviderBudget;
            } else if (field == 9) {
                ++intent.nonce;
                expected = abi.encodeWithSelector(IntentNonceMismatch.selector, 0, 1);
            } else if (field == 10) {
                ++intent.deadline;
            } else if (field == 11) {
                ++intent.chainId;
                expected = abi.encodeWithSelector(IntentDomainMismatch.selector);
            } else {
                intent.router = stranger;
                expected = abi.encodeWithSelector(IntentDomainMismatch.selector);
            }
            vm.prank(stranger);
            vm.expectRevert(expected);
            router.bridgeOutWithIntent(intent, signature);
            assertEq(router.intentNonce(alice), 0, "altered field cannot consume sender nonce");
            assertEq(router.outboundNonce(), 0);
            assertEq(usdc.balanceOf(alice), 10_000_000e6);
        }
    }

    function test_chainAndRouterDomainCannotBeReboundEvenWhenTypedFieldsMatch() public {
        TransferIntent memory intent = _intent();
        bytes memory signature = _sign(intent);
        vm.chainId(block.chainid + 1);
        intent.chainId = block.chainid;
        vm.expectRevert(InvalidSignature.selector);
        router.bridgeOutWithIntent(intent, signature);
        HyperionRouter other = _freshRouter();
        intent.router = address(other);
        vm.expectRevert(InvalidSignature.selector);
        other.bridgeOutWithIntent(intent, signature);
    }

    function test_replayExpiryAndExcessProviderBudgetCannotConsumeState() public {
        TransferIntent memory intent = _intent();
        bytes memory signature = _sign(intent);
        vm.prank(stranger);
        vm.expectRevert(ProviderBudgetExceeded.selector);
        router.bridgeOutWithIntent{value: intent.maxProviderBudget + 1}(intent, signature);
        assertEq(router.intentNonce(alice), 0);
        vm.warp(intent.deadline + 1);
        vm.expectRevert(abi.encodeWithSelector(IntentExpired.selector, intent.deadline));
        router.bridgeOutWithIntent(intent, signature);
        intent = _intent();
        signature = _sign(intent);
        router.bridgeOutWithIntent(intent, signature);
        vm.expectRevert(abi.encodeWithSelector(IntentNonceMismatch.selector, 1, 0));
        router.bridgeOutWithIntent(intent, signature);
        assertEq(router.outboundNonce(), 1);
    }

    function test_globalAndRoutePauseBlockSignedDispatch() public {
        TransferIntent memory intent = _intent();
        bytes memory signature = _sign(intent);
        vm.prank(guardian);
        router.pause();
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.bridgeOutWithIntent(intent, signature);
        vm.prank(admin);
        router.unpause();
        vm.prank(guardian);
        router.pauseRoute(RouteKind.Cctp);
        vm.expectRevert(abi.encodeWithSelector(RouteIsPaused.selector, RouteKind.Cctp));
        router.bridgeOutWithIntent(intent, signature);
        assertEq(router.intentNonce(alice), 0);
    }

    function test_downstreamAndReentrantRefundFailureRollBackNonceFlowAndRecord() public {
        TransferIntent memory intent = _intent();
        bytes memory signature = _sign(intent);
        uint256 availableBefore = router.flowAvailable(address(usdc), RouteKind.Cctp);
        cctpRail.setDispatchReverts(true);
        vm.expectRevert(MockRailAdapter.Rejected.selector);
        router.bridgeOutWithIntent(intent, signature);
        _assertRollback(availableBefore);
        cctpRail.setDispatchReverts(false);
        cctpRail.setRefund(0.1 ether);
        IntentRefundReenter hostile = new IntentRefundReenter(router);
        vm.etch(alice, address(hostile).code);
        vm.prank(stranger);
        vm.expectRevert(RefundFailed.selector);
        router.bridgeOutWithIntent{value: 0.2 ether}(intent, signature);
        _assertRollback(availableBefore);
        vm.etch(alice, "");
        vm.prank(stranger);
        router.bridgeOutWithIntent{value: 0.2 ether}(intent, signature);
        assertEq(router.intentNonce(alice), 1);
    }

    function test_signatureLengthRecoveryAndMalleabilityAreRejected() public {
        TransferIntent memory intent = _intent();
        bytes32 digest = _digest(intent, block.chainid, address(router));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, digest);
        bytes[4] memory bad = [
            abi.encodePacked(r, s),
            abi.encodePacked(r, s, uint8(29)),
            abi.encodePacked(bytes32(0), bytes32(0), uint8(27)),
            abi.encodePacked(
                r,
                bytes32(0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141 - uint256(s)),
                uint8(v == 27 ? 28 : 27)
            )
        ];
        for (uint256 i; i < bad.length; ++i) {
            vm.expectRevert(InvalidSignature.selector);
            router.bridgeOutWithIntent(intent, bad[i]);
        }
        // The documented 0/1 recovery-byte normalization remains supported.
        router.bridgeOutWithIntent(intent, abi.encodePacked(r, s, uint8(v - 27)));
        assertEq(router.intentNonce(alice), 1);
    }

    function test_feeTypedDigestAndExactSeparatePaymentOnBothRails() public {
        for (uint256 i; i < 2; ++i) {
            TransferIntent memory intent = _intent();
            intent.route = RouteKind(i);
            intent.minDestinationAmount = 999e7;
            bytes32 digest = _feeDigest(intent, address(usdc), 3e6);
            assertEq(router.hashTransferIntentWithRelayerFee(intent, address(usdc), 3e6), digest);
            uint256 before = usdc.balanceOf(alice);
            vm.prank(stranger);
            uint64 nonce = router.bridgeOutWithRelayerFee(
                intent, _feeSign(intent, address(usdc), 3e6), address(usdc), 3e6
            );
            assertEq(usdc.balanceOf(alice), before - 1003e6);
            assertEq(usdc.balanceOf(stranger), (i + 1) * 3e6);
            assertEq(router.outboundRecord(nonce).netAmount, 999e6);
            assertEq(router.intentNonce(alice), i + 1);
        }
    }

    function test_feeAssetAndCapCannotBeSubstituted() public {
        TransferIntent memory intent = _intent();
        bytes memory signature = _feeSign(intent, address(usdc), 3e6);
        vm.prank(stranger);
        vm.expectRevert(InvalidSignature.selector);
        router.bridgeOutWithRelayerFee(intent, signature, address(usdc), 3e6 + 1);
        vm.prank(stranger);
        vm.expectRevert(InvalidSignature.selector);
        router.bridgeOutWithRelayerFee(intent, signature, bob, 3e6);
        assertEq(router.intentNonce(alice), 0);
        assertEq(router.outboundNonce(), 0);
    }

    function test_feeSignatureCannotMutateInnerTransferMinimum() public {
        TransferIntent memory intent = _intent();
        bytes memory signature = _feeSign(intent, address(usdc), 3e6);
        intent.minDestinationAmount = 1;
        vm.prank(stranger);
        vm.expectRevert(InvalidSignature.selector);
        router.bridgeOutWithRelayerFee(intent, signature, address(usdc), 3e6);
        assertEq(router.outboundNonce(), 0);
    }

    function test_feeAndLegacyAuthorizationCannotBeInterchangedAndShareNonce() public {
        TransferIntent memory intent = _intent();
        bytes memory legacy = _sign(intent);
        bytes memory fee = _feeSign(intent, address(0), 0);
        vm.prank(stranger);
        vm.expectRevert(InvalidSignature.selector);
        router.bridgeOutWithRelayerFee(intent, legacy, address(0), 0);
        vm.prank(stranger);
        vm.expectRevert(InvalidSignature.selector);
        router.bridgeOutWithIntent(intent, fee);
        vm.prank(stranger);
        router.bridgeOutWithRelayerFee(intent, fee, address(0), 0);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IntentNonceMismatch.selector, 1, 0));
        router.bridgeOutWithIntent(intent, legacy);
        assertEq(router.outboundNonce(), 1);
    }

    function test_feeTokensUnregisteredDisabledAndNoncanonicalZeroAreRejectedBeforeDebit() public {
        TransferIntent memory intent = _intent();
        bytes memory missing = _feeSign(intent, bob, 1);
        vm.prank(stranger);
        vm.expectRevert(FeeTokenNotSupported.selector);
        router.bridgeOutWithRelayerFee(intent, missing, bob, 1);
        bytes memory zero = _feeSign(intent, address(usdc), 0);
        vm.prank(stranger);
        vm.expectRevert(InvalidRelayerFee.selector);
        router.bridgeOutWithRelayerFee(intent, zero, address(usdc), 0);
        _setTokenEnabled(address(usdc), false);
        intent = _intent();
        bytes memory disabled = _feeSign(intent, address(usdc), 1);
        vm.prank(stranger);
        vm.expectRevert(FeeTokenNotSupported.selector);
        router.bridgeOutWithRelayerFee(intent, disabled, address(usdc), 1);
        assertEq(router.intentNonce(alice), 0);
        assertEq(router.outboundNonce(), 0);
    }

    function test_feePaymentFailureRollsBackCompletedProviderCallAndAllNonceFlowState() public {
        TransferIntent memory intent = _intent();
        bytes memory signature = _feeSign(intent, address(usdc), 3e6);
        uint256 flow = router.flowAvailable(address(usdc), RouteKind.Cctp);
        usdc.setBlocked(stranger, true);
        vm.prank(stranger);
        vm.expectRevert();
        router.bridgeOutWithRelayerFee(intent, signature, address(usdc), 3e6);
        _assertRollback(flow);
        assertEq(usdc.balanceOf(stranger), 0);
        usdc.setBlocked(stranger, false);
        vm.prank(stranger);
        router.bridgeOutWithRelayerFee(intent, signature, address(usdc), 3e6);
        assertEq(usdc.balanceOf(stranger), 3e6);
        assertEq(cctpRail.callCount(), 1);
    }

    function test_feeStillEnforcesPauseExpiryAndProviderBudget() public {
        TransferIntent memory intent = _intent();
        bytes memory signature = _feeSign(intent, address(usdc), 3e6);
        vm.prank(stranger);
        vm.expectRevert(ProviderBudgetExceeded.selector);
        router.bridgeOutWithRelayerFee{value: intent.maxProviderBudget + 1}(
            intent, signature, address(usdc), 3e6
        );
        vm.prank(guardian);
        router.pause();
        vm.prank(stranger);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        router.bridgeOutWithRelayerFee(intent, signature, address(usdc), 3e6);
        vm.prank(admin);
        router.unpause();
        vm.warp(intent.deadline + 1);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(IntentExpired.selector, intent.deadline));
        router.bridgeOutWithRelayerFee(intent, signature, address(usdc), 3e6);
        assertEq(router.intentNonce(alice), 0);
    }

    function test_nonzeroSelfPaidFeeCannotPassExactDebitAndCreditRequirements() public {
        TransferIntent memory intent = _intent();
        bytes memory signature = _feeSign(intent, address(usdc), 3e6);
        vm.prank(alice);
        vm.expectRevert(InvalidRelayerFee.selector);
        router.bridgeOutWithRelayerFee(intent, signature, address(usdc), 3e6);
        assertEq(router.outboundNonce(), 0);
    }

    function test_extraSenderDebitAndPhantomFeeTransferRevertProviderAndBalances() public {
        RelayerSkewAsset fee = new RelayerSkewAsset(alice);
        _registerToken(address(fee), 18, type(uint128).max);
        vm.prank(alice);
        fee.approve(address(router), type(uint256).max);
        TransferIntent memory intent = _intent();
        bytes memory signature = _feeSign(intent, address(fee), 1 ether);
        uint256 flow = router.flowAvailable(address(usdc), RouteKind.Cctp);
        for (uint256 i; i < 2; ++i) {
            fee.setMode(i == 0, i == 1);
            vm.prank(stranger);
            vm.expectRevert(InvalidRelayerFee.selector);
            router.bridgeOutWithRelayerFee(intent, signature, address(fee), 1 ether);
            _assertRollback(flow);
            assertEq(fee.balanceOf(alice), 10 ether);
            assertEq(fee.balanceOf(stranger), 0);
        }
        fee.setMode(false, false);
        vm.prank(stranger);
        router.bridgeOutWithRelayerFee(intent, signature, address(fee), 1 ether);
        assertEq(fee.balanceOf(alice), 9 ether);
        assertEq(fee.balanceOf(stranger), 1 ether);
        assertEq(router.outboundRecord(1).netAmount, 999e6);
    }

    function _feeSign(TransferIntent memory intent, address feeToken, uint256 charge)
        private
        view
        returns (bytes memory)
    {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _feeDigest(intent, feeToken, charge));
        return abi.encodePacked(r, s, v);
    }

    function _feeDigest(TransferIntent memory intent, address feeToken, uint256 charge)
        private
        view
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("HyperionRouter"),
                keccak256("1"),
                block.chainid,
                address(router)
            )
        );
        bytes32 body = keccak256(
            abi.encode(
                keccak256(
                    "RelayerFeeIntent(bytes32 transferIntentHash,address feeToken,uint256 maxRelayerCharge)"
                ),
                _digest(intent, block.chainid, address(router)),
                feeToken,
                charge
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, body));
    }

    function _assertRollback(uint256 availableBefore) private view {
        assertEq(router.intentNonce(alice), 0);
        assertEq(router.outboundNonce(), 0);
        assertEq(router.outboundRecord(1).nonce, 0);
        assertEq(router.flowAvailable(address(usdc), RouteKind.Cctp), availableBefore);
        assertEq(usdc.balanceOf(alice), 10_000_000e6);
        assertEq(usdc.balanceOf(treasury), 0);
        assertEq(cctpRail.callCount(), 0);
    }

    function _intent() private view returns (TransferIntent memory intent) {
        OutboundRequest memory request = _usdcRequest(1000e6);
        intent = TransferIntent({
            sender: alice,
            token: request.token,
            amount: request.amount,
            route: request.route,
            destination: request.destination,
            destinationDecimals: request.destinationDecimals,
            minDestinationAmount: 0,
            maxProviderBudget: 0.5 ether,
            nonce: router.intentNonce(alice),
            deadline: block.timestamp + 1 hours,
            chainId: block.chainid,
            router: address(router)
        });
    }

    function _sign(TransferIntent memory intent) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(ownerKey, _digest(intent, block.chainid, address(router)));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Independent flat EIP-712 wire schema, not the router's hash helper.
    function _digest(TransferIntent memory intent, uint256 chainId, address verifyingContract)
        private
        pure
        returns (bytes32)
    {
        bytes32 domain = keccak256(
            abi.encode(
                keccak256(
                    "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
                ),
                keccak256("HyperionRouter"),
                keccak256("1"),
                chainId,
                verifyingContract
            )
        );
        bytes32 body = keccak256(
            abi.encode(
                keccak256(
                    "TransferIntent(address sender,address token,uint256 amount,uint8 route,"
                    "string destinationChain,string destinationAddress,uint8 destinationDecimals,"
                    "uint256 minDestinationAmount,uint256 maxProviderBudget,uint256 nonce,"
                    "uint256 deadline,uint256 chainId,address router)"
                ),
                intent.sender,
                intent.token,
                intent.amount,
                intent.route,
                keccak256(bytes(intent.destination.chain)),
                keccak256(bytes(intent.destination.strkey)),
                intent.destinationDecimals,
                intent.minDestinationAmount,
                intent.maxProviderBudget,
                intent.nonce,
                intent.deadline,
                intent.chainId,
                intent.router
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", domain, body));
    }
}
