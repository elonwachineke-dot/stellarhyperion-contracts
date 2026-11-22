# EVM transfer intents

`bridgeOutWithIntent` is a development-only relayer entrypoint. A sender signs the complete
`TransferIntent` with EIP-712; the typed value includes the token, exact amount, route, recipient,
slippage floor, provider budget, sender nonce, deadline, chain ID, and router address. The router
also binds those last two values in the EIP-712 domain, so the same signature cannot execute on a
different chain or router.

The sender must approve the router before signing. Token debit, ITS sender metadata, events,
provenance and native refunds all use the signed sender, even when another account submits the
transaction. Global and route pauses apply to signed transfers.

The relayer supplies `msg.value` and may not exceed the signed `maxProviderBudget`; any unused
provider value is refunded directly to the sender. A failed refund reverts the whole transfer,
including provider calls, both nonces, flow allowance, token movement and provenance. Signed
transfers use this direct-refund behavior; refund credits are available through the separate
`bridgeOutWithRefundCredit` entrypoint.

The normal configured protocol fee applies. The legacy `bridgeOutWithIntent` method adds no relayer fee and imposes no
relayer allowlist: anyone holding a valid intent can submit it before its deadline. The signed
provider budget is a ceiling, so submission with a smaller value may fail the adapter's funding
checks. A relayer may charge separately under an application-level agreement.

Signatures use EIP-712 domain name `HyperionRouter`, version `1`, current chain ID and router
address. The wire schema flattens the destination into `destinationChain` and
`destinationAddress`, hashing each string. All 13 typed fields are bound to the signature.
Recovery supports 65-byte `r || s || v` EOA signatures with low `s`; `v` may be 27/28 or 0/1.
ERC-1271 contract-wallet validation and 64-byte compact signatures are unsupported.

The per-sender intent nonce is consumed once, only after signature, deadline, domain, and budget
checks pass, and persists only if the whole dispatch succeeds. Tests independently construct
the typed digest, alter every signed field, reject replay and rebinding, and exercise both paid
rails, pauses and downstream/refund rollback.

This feature is development infrastructure and does not activate a live EVM rail; production
deployment still requires an independently reviewed activation and signed acceptance evidence.
The immutable helper and adapter review boundaries are described in
[EVM deployment and provenance](EVM_DEPLOYMENT_PROVENANCE.md).

## Additive signed relayer fees

`bridgeOutWithRelayerFee(intent, signature, feeToken, maxRelayerCharge)` retains the legacy
`TransferIntent` layout and `bridgeOutWithIntent` selector. Its signature instead signs the typed
`RelayerFeeIntent(bytes32 transferIntentHash,address feeToken,uint256 maxRelayerCharge)` in the
same HyperionRouter version-1 EIP-712 domain. `transferIntentHash` is the complete legacy-domain
intent digest returned by `hashTransferIntent`; the new hash helper binds that digest and both
fee fields. A legacy signature cannot authorize a fee, and both methods consume the same sender
nonce. The fee is paid exactly at the signed cap after successful dispatch, separately from its
bridged amount and minimum. The sender approves the router for the fee asset as well as the
transfer asset. Fee assets must be registered and enabled; zero charges require the zero address.
Self-paid nonzero fees, fee-on-transfer assets and unexpected sender/relayer balance changes are
refused atomically. Failed fee payment reverts the dispatch, provider effects and shared nonce.
Existing signatures, legacy calldata and zero-fee legacy behavior remain unchanged.
