# Upgrade Rollback Feasibility Reports

`script/stellar/rollback-report.mjs` compares recorded Stellar executable hashes, migration
claims, and required authority. It signs nothing, submits nothing, and executes nothing.

```sh
node script/stellar/rollback-report.mjs deployments/stellar-testnet-phase1.json --json
node script/stellar/rollback-report.mjs \
  --from deployments/archive/stellar-testnet-2026-10-01.json \
  --to deployments/stellar-testnet-phase1.json
node script/stellar/rollback-report.mjs deployments/stellar-testnet-phase1.json \
  --rpc https://soroban-testnet.stellar.org --source-account PUBLIC_G_ADDRESS
```

Records must pass the checked-out protocol deployment validator and carry exactly one Stellar
network. Inputs are limited to 1 MiB. Explicit archived targets are refused; absent lifecycle
metadata remains `unknown`. Records for different router IDs are identified as deployment
replacements rather than in-place upgrades. Missing old/new hashes and schema evidence remain
unknown; a path containing `archive` is not lifecycle evidence.

The writer accepts `HYPERION_SCHEMA_VERSION` as an exact u32, and optional
`HYPERION_ROLLBACK_SUPPORTED=true|false`. Setting `false` requires a bounded, non-empty
`HYPERION_ROLLBACK_REASON`. The resulting `storageMigration` metadata is validated separately
because the deployment parser ignores extension fields. An explicit unsupported declaration
always blocks router rollback in the report. A `true` declaration is retained as a recorded
operator claim; it does not certify feasibility.

Schema numbers alone cannot establish compatibility. The current router reports schema 3 and
supports bounded migration, but the previous executable's readers, writers, liability accounting,
claims and replay state require a migration-specific review. Adapter compatibility is also unknown.
The report lists these review obligations instead of guaranteeing that invariants survive rollback.

Optional live evidence uses the exact RPC URL and record network passphrase, plus an explicit
public G source address for `stellar contract invoke --is-view`. It checks `getNetwork`, reads
the router contract instance, invokes `get_migration_status`, and reads the instance again.
Both observations must share a closed ledger and match the recorded executable hash. Unavailable,
malformed, changed-ledger, changed-hash or wrong-network evidence stays unavailable. The bounded
RPC/CLI calls do not sign or submit a transaction. An observed schema still cannot certify rollback.

For the current implementation, router upgrades require its admin's `AdminAction::Upgrade` queue
and execution after the timelock; adapter `upgrade(wasm_hash)` requires its own admin. The report
labels recorded admin/timelock values as unverified live authority. Verify deployed code, current
authority and pending migrations, review state compatibility, and prepare an explicit recovery plan
before taking any action. No automatic upgrade, rollback or route activation is offered.

`script/stellar/verify.sh` retains its schema-3 and completed-migration gates. A successful ordinary
deployment verification is separate from proving compatibility with a previous executable.
