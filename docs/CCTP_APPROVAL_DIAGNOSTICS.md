# CCTP approval diagnostics

Both Soroban burn entrypoints (`dispatch` and paid `dispatch_from`) and EVM `dispatch` approve exactly the requested token amount immediately before calling Circle. Soroban approvals expire in the current ledger. Each entrypoint reads back the opened allowance, clears it after the burn, and requires the observed residual allowance to be zero. A failed read, failed approval, inconsistent opened amount or nonzero cleanup aborts the transaction. Inconsistent allowance amounts use the existing `InvalidAmount` error. There is no standing approval between successful burns.

The read-only `audit_allowance(token)` and EVM `auditAllowance()` / `auditAllowance(token)` inspect the adapter's allowance to its configured messenger. They require no administrator authorization and never approve, revoke, move tokens, change fee policy or reconcile state. The version-1 result reports expected allowance zero and these stable findings:

| Finding            | Value | Interpretation                                                                      |
| ------------------ | ----- | ----------------------------------------------------------------------------------- |
| Clean              | 0     | A readable allowance equals zero.                                                   |
| UnexpectedResidual | 1     | A readable allowance is positive.                                                   |
| Unavailable        | 2     | The read failed, its return was malformed, or the token reported an invalid amount. |

For `Unavailable`, allowance zero is a placeholder and `is_clean` / `isClean` is false. Consumers must inspect the finding before treating the numeric value as a measurement. EVM accepts only exactly 32 return bytes and preserves the entire uint256 value. Soroban preserves nonnegative i128 values. The protocol package's `auditCctpAllowance` accepts a bigint reading or null for a failed read, with the same findings and uint256 bounds. Negative values are unavailable, never residual or clean.

`ApprovalAudited` records the preexisting and final allowance for successful burns, including paid forwarding. Its final allowance is always zero and cleanliness is true; failed transactions do not produce committed lifecycle events. A residual audit remains observational. Operators investigate the token/provider and choose a separately authorized recovery action; the auditor never clears a finding itself.

Existing dispatch signatures, burn parameters, storage keys, and error numbers remain unchanged. Finality is lane-specific on Soroban: missing policy entries default to finalized threshold 2000, and fast threshold 1000 requires explicit lane configuration and a nonzero fee budget. The legacy global fee setter rejects weaker thresholds. The EVM development adapter remains finalized-only and reports its policy through `quoteFinalityPolicy` and `FinalityPolicyUsed`. See [CCTP finality policy](./CCTP_FINALITY_POLICY.md) for compatibility and migration details.

These checks do not authorize deployment or replace Circle's attestation verification. Activation and upgrade rehearsal remain subject to the existing testnet gates. The hostile fixtures test messenger failure after token movement and record mutation, inconsistent approvals, failed/nonzero cleanup, unchanged source balances and router fees/flow/nonce, and retry after the fault is removed. They do not claim production Circle integration.

## Inbound compatibility and migration

Inbound CCTP is a separately commissioned boundary, not activation of the active Stellar Testnet outbound route. A receiving adapter must verify CCTP wire version, destination domain, source-domain lane, remote peer sender, TokenMessenger recipient, burn version, burn token, mint recipient, exact minted amount and hook shape before router delivery. The full 32-byte CCTP nonce remains the replay identity; a u64 display nonce is informational only.

The EVM receiver keeps the four-argument constructor. The owner explicitly sets the mutable `messageTransmitter` and commissions `setInboundLane(sourceDomain, chain, tokenMessenger, peer, burnToken)`. The header sender must match Circle's remote TokenMessenger; `burn.messageSender` must independently match the remote Hyperion adapter, and the remote burn-token word may differ from local USDC. Inbound identities are fixed once per source domain. Replacing them requires a separately reviewed fresh adapter deployment; outbound peer rotation neither replaces inbound identities nor grants inbound overlap. `setInboundLaneEnabled` controls inbound independently of `setLaneEnabled`.

The EVM finalized-only receiver accepts minimum finality 2000, executed finality at least 2000, zero max/executed provider fees, a positive amount within uint128, and an unexpired destination block when expiration is present. The header destination caller must be zero or the receiving adapter. Before routing it requires Circle's `receiveMessage` to return true and mint exactly the attested amount. The router receives only an exact temporary allowance; successful delivery clears it and preserves preexisting adapter custody. Provider failure, false or malformed return, inconsistent mint, reentry, or router failure rolls back minting and replay state. Failed recipient payouts instead park a fixed-recipient claim, preserving the accepted message's replay protection.

This adds inbound storage and a reentrancy guard to a nonupgradeable EVM adapter. Existing deployments do not acquire this layout or inbound behavior automatically. Changing the mutable transmitter also changes the attestation trust boundary: review its code, local domain, interface and provider configuration before commissioning or replacing it. The deployment script commissions only outbound routing. Existing outbound lane storage and dispatch signatures do not establish valid inbound trust.

Provider upgrades must preserve the CCTP v2 offsets and exact uint256/i128 amount conversion documented in `hyperion-core::cctp`. Any provider change that alters those offsets, recipient semantics, replay nonce identity or transmitter interface requires a wire-format fixture, parity test and deployment migration. It must not silently reuse the active outbound lane as authorization for inbound receipt.

On Soroban, commission two distinct source identities before inbound use: `set_peer_messenger`
binds the CCTP header sender to Circle's remote TokenMessenger; `set_remote_sender` binds
`burn.messageSender` to the remote Hyperion adapter. The existing delayed TokenMessenger rotation
and historical overlap window continue to apply to the header. Neither source identity is
inferred from `link_domain` or outbound destination-caller configuration. Existing receiving
installations must explicitly commission the burn sender; outgoing-only lanes remain usable.

Before router delivery, the receiving adapter validates the mapped burn token, supported minimum
finality and actual finality, non-expired destination ledger, positive amount, fee bounds and an
exact mint delta of `burn.amount - burn.feeExecuted`. A provider under-mint or over-mint rolls back
custody and replay state. Fees are read from the attested wire fields, not independently asserted
provider output. Circle still verifies attestations; local native provider fixtures establish the
adapter's boundaries and rollback behavior rather than production Circle cryptography.
