# Local Axelar GMP delivery rehearsal

The adapter fixture now includes one end-to-end rehearsal for the development-only GMP path:

1. The real router funds the real `AxelarItsAdapter`, which hands custody to the local ITS stand-in.
2. A direct callback from a stranger is rejected; an ITS callback carrying a forged source peer also fails and preserves provider custody.
3. A callback from the configured peer reaches the router with its command id and source nonce.
4. A temporarily blocked recipient produces a recipient-bound pending claim instead of losing the
   delivery; unblocking the recipient lets the claim settle once.
5. Replaying the same Axelar command id is rejected.

Run it on a local checkout with:

```sh
cd evm
forge test --match-path test/unit/AxelarItsAdapter.t.sol \
  --match-test test_authenticated_gmp_rehearsal_preserves_custody_and_parks_a_claim
```

This is development evidence only. It uses the committed local ITS and ERC-20 stand-ins, does not
provide live Axelar validation evidence, and does not open the adapter's production deployment
gate. The active deployment remains Stellar Testnet outbound ITS/CCTP.

The paid-dispatch regression separates the sender's native ITS gas payment from the router's token
protocol fee. Only the synchronous balance increase attributable to the current provider call is
refunded to that dispatch's original sender, capped at that call's original native payment. Any
provider return above that payment remains unassigned adapter custody. A late or otherwise unassigned native refund already
in the adapter stays there; this change adds no automatic attribution or withdrawal. A provider
failure after token movement restores the sender's token/native balances, treasury fee, router
nonce and outbound provenance, adapter custody, and provider metadata; removing the fault permits
a fresh successful attempt. Run these cases with:

```sh
forge test --match-contract AxelarItsAdapterTest \
  --match-test 'test_refund_delta_with_paid_real_router_keeps_unattributed_balance|test_provider_failure_rolls_back_paid_dispatch_fee_and_metadata'
```

The gas-service failure fixtures revert after mutating the local receipt. They verify first-message
binding and reverse-map rollback, preserved cumulative spend and binding on a later failed top-up,
unchanged sender/provider native balances, and a successful retry after removing the fault.
