# CCTP remote-messenger rotation with overlap controls

Soroban Circle header TokenMessenger replacement uses `propose_peer_rotation` / `apply_peer_rotation` / `cancel_peer_rotation` (or `propose_messenger_rotation` / `apply_messenger_rotation` / `cancel_messenger_rotation` for the local TokenMessenger). EVM `proposePeerRotation` / `applyPeerRotation` / `cancelPeerRotation` rotates only the outbound destination mint recipient; it does not rotate inbound trust. The minimum timelock delay is 3,600 seconds (1 hour). Proposals do not alter active routing trust until applied at or after the recorded eta. A proposal must be cancelled before a replacement proposal can be submitted.

## Acceptance windows and historical-message handling

Soroban Circle header TokenMessenger replacement introduces a historical-message acceptance window (default 86,400 seconds / 24 hours). The following table describes Soroban inbound header trust. The independently commissioned remote Hyperion burn sender must still match; overlap does not authorize arbitrary burn senders.

| Messenger / Lane state     | Inbound: active peer         | Inbound: retired peer (old)  | Inbound: unauthorized peer | Outbound dispatch  |
| -------------------------- | ---------------------------- | ---------------------------- | -------------------------- | ------------------ |
| Enabled, rotation pending  | Accepted with normal checks  | N/A                          | Refused                    | Uses active route  |
| Enabled, overlap window    | Accepted with normal checks  | Accepted (in-flight overlap) | Refused                    | Uses active route  |
| Enabled, overlap expired   | Accepted with normal checks  | Refused (expired)            | Refused                    | Uses active route  |
| Emergency disabled         | Refused                      | Refused                      | Refused                    | Refused            |
| Unlinked / unmapped        | Refused                      | Refused                      | Refused                    | Refused            |

### Inbound custody protection
Messages from unauthorized peers never acquire inbound custody. During normal operation, only the active peer messenger is trusted. During the acceptance window following an applied rotation, in-flight messages signed against the retired peer messenger are accepted so that transfers crossing the network before cutover settle cleanly into their recipient accounts or claims without stranding funds. Once the acceptance window elapses, old messages are rejected with `OldMessengerExpired`.

### Emergency-disable controls
Soroban `set_domain_disabled` halts both outbound burns and inbound custody immediately. EVM `setLaneEnabled` controls outbound only; `setInboundLaneEnabled(sourceDomain, enabled)` independently controls inbound receipt. Applying or cancelling a rotation never re-enables a disabled domain or lane. Emergency disable preserves funds in place while an upstream fault or provider upgrade anomaly is investigated.

## EVM inbound identity replacement

EVM `setInboundLane` independently commissions a source domain's Circle TokenMessenger header sender,
remote Hyperion burn sender and remote burn token once. Outbound rotation and its historical peer
record do not change these checks. There is no EVM inbound overlap or in-place identity replacement;
a replacement requires a separately reviewed fresh adapter deployment and router receiver migration.
Accepted fixed-recipient claims remain in the router and can settle after inbound disable or replacement.

## Provider upgrade compatibility & message boundaries
Provider upgrades must adhere to explicit message-boundary guarantees:
- Exact positive integer amounts (`i128` on Soroban, `uint256` on EVM) without overflow, truncation, or floating-point conversions.
- Authenticated rail dispatch: only the authorized router caller may invoke burn dispatch.
- Replay protection: Circle 32-byte nonces are validated on inbound; router replay protection guards prevent double-crediting.
- Recipient-bound claims: mint recipients and hook payloads cannot be mutated in flight. Parked claims in the router remain payable to their recorded recipient regardless of peer rotation or domain disablement.
- Allowance lifecycle: TokenMessenger consumes approvals via `transfer_from`. Dispatch opens the allowance for the exact amount and ledger sequence, then closes it to zero.

## Active deployment gating
The active deployment remains Stellar Testnet outbound ITS/CCTP. EVM contracts, inbound CCTP forwarding, and live peer migrations remain development paths until independently validated under existing testnet and deployment gates. No production activation or deployment is authorized by these APIs or this document.
