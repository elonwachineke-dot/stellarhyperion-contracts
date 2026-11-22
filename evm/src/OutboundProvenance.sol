// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    AdapterMethodUnavailable,
    AmountNotRepresentable,
    FeeTokenNotSupported,
    IntentDomainMismatch,
    IntentExpired,
    IntentNonceMismatch,
    InvalidAmount,
    InvalidDestination,
    InvalidRelayerFee,
    InvalidSignature,
    MuxedNotSupported,
    ProviderBudgetExceeded,
    RailNotConfigured,
    SlippageExceeded,
    TokenNotMapped,
    Unauthorized,
    UnknownChain,
    ZeroAddressKey
} from "./HyperionErrors.sol";
import {
    AddressKind,
    Destination,
    OutboundRecord,
    QuoteBlocker,
    RouteKind,
    RouteQuote,
    RouteQuoteV2,
    TokenConfig,
    TransferIntent
} from "./HyperionTypes.sol";
import {IRouterActionState, RouterActionValidator} from "./RouterActionValidator.sol";
import {IRailAdapter} from "./interfaces/IRailAdapter.sol";
import {AmountMath} from "./libraries/AmountMath.sol";
import {RouteMeta} from "./libraries/RouteMeta.sol";
import {StellarAddress} from "./libraries/StellarAddress.sol";

/// @title Read-only router quote inputs
/// @notice State and pure address validation queried by the immutable router support module.
interface IRouterQuoteState is IRouterActionState {
    /// @notice Whether global outbound pause is active.
    function paused() external view returns (bool);
    /// @notice Whether route outbound pause is active.
    function routePaused(RouteKind route) external view returns (bool);
    /// @notice Whether the route is enabled.
    function routeEnabled(RouteKind route) external view returns (bool);
    /// @notice The configured outbound adapter.
    function adapter(RouteKind route) external view returns (address);
    /// @notice The declared source protocol fee.
    function feeBps() external view returns (uint16);
    /// @notice Unconsumed cross-chain flow allowance.
    function flowAvailable(address token, RouteKind route) external view returns (uint256);
    /// @notice Current shared signed execution nonce.
    function intentNonce(address sender) external view returns (uint256);
    /// @notice Decode and validate the destination using the router's unchanged pure ABI.
    function checkDestination(string calldata strkey) external view returns (AddressKind, bytes32, uint64);
}

/// @title Append-only provenance owned by the router that deploys it
/// @notice Separates historical storage from the router's dispatch runtime without introducing
/// an upgrade, administrator or independent writer. A reverted router transaction reverts writes here.
/// The inherited action validator is read-only and uses the same immutable router binding.
contract OutboundProvenance is RouterActionValidator {
    mapping(uint64 nonce => OutboundRecord record) private _records;

    bytes32 private constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");
    bytes32 private constant TRANSFER_INTENT_TYPEHASH = keccak256(
        "TransferIntent(address sender,address token,uint256 amount,uint8 route,"
        "string destinationChain,string destinationAddress,uint8 destinationDecimals,"
        "uint256 minDestinationAmount,uint256 maxProviderBudget,uint256 nonce,"
        "uint256 deadline,uint256 chainId,address router)"
    );
    bytes32 private constant _EIP712_NAME_HASH = keccak256("HyperionRouter");
    bytes32 private constant _EIP712_VERSION_HASH = keccak256("1");

    /// @notice Parse the unchanged Stellar address format without accessing router state.
    function checkDestination(string calldata strkey) external pure returns (AddressKind, bytes32, uint64) {
        return StellarAddress.parse(strkey);
    }

    /// @notice Preserve router dispatch refusal selectors and reject unknown provider failures.
    function rethrowAdapterFailure(bytes calldata failure) external pure {
        if (failure.length < 4) revert AdapterMethodUnavailable();
        bytes4 code = bytes4(failure[:4]);
        if (code == Unauthorized.selector) revert Unauthorized();
        if (code == InvalidAmount.selector) revert InvalidAmount();
        if (code == TokenNotMapped.selector) revert TokenNotMapped();
        if (code == UnknownChain.selector) revert UnknownChain();
        if (code == RailNotConfigured.selector) revert RailNotConfigured();
        if (code == InvalidDestination.selector) revert InvalidDestination();
        if (code == ZeroAddressKey.selector) revert ZeroAddressKey();
        if (code == MuxedNotSupported.selector) revert MuxedNotSupported();
        revert AdapterMethodUnavailable();
    }

    /// @notice Compute exact outbound amounts using the router's unchanged fee and rounding rules.
    function outboundAmounts(
        uint256 amount,
        uint16 feeBps,
        uint8 sourceDecimals,
        uint8 destinationDecimals,
        uint256 minimum
    ) external pure returns (uint256 fee, uint256 net) {
        uint256 netRaw;
        (netRaw, fee) = AmountMath.applyFee(amount, feeBps);
        net = AmountMath.floorToRepresentable(netRaw, sourceDecimals, destinationDecimals);
        if (net == 0) revert AmountNotRepresentable();
        uint256 landing = AmountMath.convertDecimalsExact(net, sourceDecimals, destinationDecimals);
        if (landing < minimum) revert SlippageExceeded(minimum, landing);
    }

    /// @notice Quote all four rails in their unchanged enum order.
    function quoteAll(
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) external view returns (RouteQuote[] memory quotes) {
        quotes = new RouteQuote[](4);
        for (uint256 i = 0; i < 4; ++i) {
            quotes[i] = quote(RouteKind(i), token, amount, destination, destinationDecimals);
        }
    }

    /// @notice Commit exactly one successful source dispatch; records cannot be replaced.
    function commit(OutboundRecord calldata record) external {
        if (msg.sender != ROUTER) revert Unauthorized();
        if (record.nonce == 0 || _records[record.nonce].nonce != 0) revert InvalidAmount();
        _records[record.nonce] = record;
    }

    /// @notice Return the committed transfer or the zero-valued record for a missing nonce.
    function outboundRecord(uint64 nonce) external view returns (OutboundRecord memory) {
        return _records[nonce];
    }

    /// @notice Recover a canonical typed signature without changing any router state.
    function recoverTransferIntent(TransferIntent calldata intent, bytes calldata signature)
        external
        view
        returns (address)
    {
        return _recover(hashTransferIntent(intent), signature);
    }

    /// @notice Hash the exact typed intent in the creating router's current chain domain.
    function hashTransferIntent(TransferIntent calldata intent) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                TRANSFER_INTENT_TYPEHASH,
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
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    /// @notice Hash an additive fee authorization without changing legacy typed intent identities.
    function hashTransferIntentWithRelayerFee(
        TransferIntent calldata intent,
        address feeToken,
        uint256 charge
    ) public view returns (bytes32) {
        bytes32 structHash = keccak256(
            abi.encode(
                keccak256(
                    "RelayerFeeIntent(bytes32 transferIntentHash,address feeToken,uint256 maxRelayerCharge)"
                ),
                hashTransferIntent(intent),
                feeToken,
                charge
            )
        );
        return keccak256(abi.encodePacked("\x19\x01", _domainSeparator(), structHash));
    }

    /// @notice Read-only admission for both signed entrypoints; the router consumes the shared nonce.
    function validateTransferIntent(
        TransferIntent calldata intent,
        bytes calldata signature,
        uint256 providerPayment,
        address feeToken,
        uint256 charge,
        bool feeSigned,
        address relayer
    ) external view {
        if (intent.router != ROUTER || intent.chainId != block.chainid) {
            revert IntentDomainMismatch();
        }
        if (intent.deadline < block.timestamp) revert IntentExpired(intent.deadline);
        uint256 expectedNonce = IRouterQuoteState(ROUTER).intentNonce(intent.sender);
        if (intent.nonce != expectedNonce) revert IntentNonceMismatch(expectedNonce, intent.nonce);
        if (providerPayment > intent.maxProviderBudget) revert ProviderBudgetExceeded();
        bytes32 digest = feeSigned
            ? hashTransferIntentWithRelayerFee(intent, feeToken, charge)
            : hashTransferIntent(intent);
        if (_recover(digest, signature) != intent.sender) revert InvalidSignature();
        if (charge == 0) {
            if (feeToken != address(0)) revert InvalidRelayerFee();
        } else {
            if (!feeSigned || relayer == intent.sender) revert InvalidRelayerFee();
            TokenConfig memory config = IRouterQuoteState(ROUTER).tokenConfig(feeToken);
            if (feeToken == address(0) || !config.registered || !config.enabled) {
                revert FeeTokenNotSupported();
            }
        }
    }

    function _domainSeparator() private view returns (bytes32) {
        return keccak256(
            abi.encode(EIP712_DOMAIN_TYPEHASH, _EIP712_NAME_HASH, _EIP712_VERSION_HASH, block.chainid, ROUTER)
        );
    }

    function _recover(bytes32 digest, bytes calldata signature) private pure returns (address signer) {
        if (signature.length != 65) revert InvalidSignature();
        bytes32 r = bytes32(signature[:32]);
        bytes32 s = bytes32(signature[32:64]);
        uint8 v = uint8(signature[64]);
        if (v < 27) v += 27;
        if (
            (v != 27 && v != 28)
                || uint256(s) > 0x7fffffffffffffffffffffffffffffff5d576e7357a4501ddfe92f46681b20a0
        ) revert InvalidSignature();
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) revert InvalidSignature();
    }

    /// @notice The half of a quote that the amount has nothing to do with: whether the rail is
    /// open, whether it recognises the chain, and whether it can deliver to this kind of address.
    /// @dev Split out from `quote` because the two halves fail for unrelated reasons, and a
    /// ladder read interleaved with arithmetic is a ladder somebody reorders without noticing.
    /// @param route The rail being priced.
    /// @param destination Where the transfer is headed.
    /// @return The first reason this rail cannot carry the transfer, or `None`.
    function _quoteRailBlocker(RouteKind route, Destination calldata destination)
        private
        view
        returns (QuoteBlocker)
    {
        IRouterQuoteState target = IRouterQuoteState(ROUTER);
        if (target.paused() || target.routePaused(route)) return QuoteBlocker.Paused;
        if (!target.routeEnabled(route)) return QuoteBlocker.RouteDisabled;

        address adapterAddress = target.adapter(route);
        if (adapterAddress == address(0)) return QuoteBlocker.AdapterNotSet;

        AddressKind kind;
        // A bad strkey is a typo, not an exception. The app has to put something on the screen,
        // and a bare revert gives it nothing to say.
        try target.checkDestination(destination.strkey) returns (AddressKind parsed, bytes32, uint64) {
            kind = parsed;
        } catch {
            return QuoteBlocker.InvalidDestination;
        }
        if (kind == AddressKind.MuxedAccount && !RouteMeta.carriesPayload(route)) {
            return QuoteBlocker.MuxedNotSupported;
        }

        try IRailAdapter(adapterAddress).supportsChain(destination.chain) returns (bool ok) {
            if (!ok) return QuoteBlocker.ChainNotSupported;
        } catch {
            return QuoteBlocker.ChainNotSupported;
        }

        return QuoteBlocker.None;
    }

    /// @notice Quote exact prospective debit from the creating router's current live state.
    function quote(
        RouteKind route,
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) public view returns (RouteQuote memory) {
        IRouterQuoteState target = IRouterQuoteState(ROUTER);
        RouteQuote memory q;
        q.route = route;
        q.grossAmount = amount;
        q.waitsOnAttestation = RouteMeta.waitsOnAttestation(route);
        q.isCanonical = RouteMeta.isCanonical(route);

        QuoteBlocker blocker = _quoteRailBlocker(route, destination);
        if (blocker != QuoteBlocker.None) return _blocked(q, blocker);

        TokenConfig memory cfg = target.tokenConfig(token);
        if (!cfg.registered) return _blocked(q, QuoteBlocker.TokenNotRegistered);
        if (!cfg.enabled) return _blocked(q, QuoteBlocker.TokenDisabled);

        if (amount == 0) return _blocked(q, QuoteBlocker.AmountTooSmall);

        // Nothing past this is a transfer anybody is attempting, and the arithmetic below would
        // panic rather than answer. Promising never to revert is the whole value of this
        // function: it is what lets an app render four rows without wrapping each one in a try,
        // so even the absurd question gets a reason back. The bound is chosen so that the fee
        // multiply and a widening of up to thirty eight decimal places both stay inside a word.
        if (amount > type(uint128).max) return _blocked(q, QuoteBlocker.NotRepresentable);

        uint256 fee = (amount * target.feeBps()) / AmountMath.BPS_DENOMINATOR;
        uint256 netRaw = amount - fee;
        // Only reachable if `MAX_FEE_BPS` were ever raised to ten thousand, the same way the
        // matching guard in `AmountMath.applyFee` is. Kept for the same reason: the invariant
        // worth stating is "a transfer always delivers something", not "today's constants
        // happen to make that true".
        if (netRaw == 0) return _blocked(q, QuoteBlocker.AmountTooSmall);
        if (cfg.decimals > AmountMath.MAX_DECIMALS || destinationDecimals > AmountMath.MAX_DECIMALS) {
            return _blocked(q, QuoteBlocker.NotRepresentable);
        }

        uint256 net = AmountMath.floorToRepresentable(netRaw, cfg.decimals, destinationDecimals);
        if (net == 0) return _blocked(q, QuoteBlocker.NotRepresentable);

        uint256 headroom = target.flowAvailable(token, route);
        q.flowAvailable = headroom;
        if (net > headroom) return _blocked(q, QuoteBlocker.FlowLimitExceeded);

        (uint256 landing,) = AmountMath.convertDecimals(net, cfg.decimals, destinationDecimals);
        q.available = true;
        q.reason = QuoteBlocker.None;
        q.fee = fee;
        q.netAmount = net;
        q.grossAmount = fee + net;
        q.destinationAmount = landing;
        return q;
    }

    function _blocked(RouteQuote memory q, QuoteBlocker reason) private pure returns (RouteQuote memory) {
        q.available = false;
        q.reason = reason;
        return q;
    }

    /// @notice Quote exact debit and source dust in the additive V2 schema.
    /// @notice Quote prospective debit without changing the legacy result schema.
    /// @dev Unavailable quotes never imply a debit occurred.
    function quoteV2(
        RouteKind route,
        address token,
        uint256 amount,
        Destination calldata destination,
        uint8 destinationDecimals
    ) public view returns (RouteQuoteV2 memory v) {
        IRouterQuoteState target = IRouterQuoteState(ROUTER);
        v.quote = quote(route, token, amount, destination, destinationDecimals);
        v.requestedAmount = amount;
        TokenConfig memory cfg = target.tokenConfig(token);
        if (
            !cfg.registered || amount == 0 || amount > type(uint128).max
                || cfg.decimals > AmountMath.MAX_DECIMALS || destinationDecimals > AmountMath.MAX_DECIMALS
        ) return v;
        v.fee = (amount * target.feeBps()) / AmountMath.BPS_DENOMINATOR;
        v.netAmount = AmountMath.floorToRepresentable(amount - v.fee, cfg.decimals, destinationDecimals);
        v.retainedDust = amount - v.fee - v.netAmount;
        v.actualDebit = v.fee + v.netAmount;
        v.breakdownKnown = true;
    }
}
