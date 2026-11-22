import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { buildRecord } from "../write-record.mjs";
import { storageMigrationFromEnv } from "../record-evidence.mjs";
import { buildReport } from "../rollback-report.mjs";
const original = JSON.parse(
  readFileSync("deployments/stellar-testnet-phase1.json", "utf8"),
);
const data = original.networks["stellar-testnet"];
function env() {
  return {
    STELLAR_NETWORK: "testnet",
    HYPERION_ASSET: `USDC:${data.tokens.USDC.issuer}`,
    HYPERION_ROUTER: data.router,
    HYPERION_CCTP: data.adapters.cctp,
    HYPERION_AXELAR: data.adapters["axelar-its"],
    HYPERION_SAC: data.tokens.USDC.sacId,
    HYPERION_TOKEN_FLOW_LIMIT: "100000000",
    HYPERION_TREASURY: data.treasury,
    HYPERION_ADMIN: data.admin,
    HYPERION_GUARDIAN: data.guardian,
    HYPERION_FEE_BPS: "30",
    HYPERION_FLOW_WINDOW_LEDGERS: "720",
    HYPERION_TIMELOCK_DELAY: "3600",
    HYPERION_DEPLOYER: data.admin,
    HYPERION_PEER_CHAIN: "sepolia",
    ROUTER_HASH: data.wasmHashes.router,
    HYPERION_ROUTER_LEDGER: "100",
  };
}
test("writer records validated unsupported metadata consumed by the real report", async () => {
  const values = {
    ...env(),
    HYPERION_SCHEMA_VERSION: "3",
    HYPERION_ROLLBACK_SUPPORTED: "false",
    HYPERION_ROLLBACK_REASON: "Reviewed incompatible liability migration",
  };
  const record = await buildRecord(values);
  assert.equal(
    record.networks["stellar-testnet"].storageMigration.rollbackSupported,
    false,
  );
  const report = await buildReport({ toRecord: record });
  assert.equal(report.storageMigration.rollbackSupported, false);
  assert.equal(report.storageMigration.reason, values.HYPERION_ROLLBACK_REASON);
});
test("migration environment integers and booleans are exact and bounded", () => {
  assert.equal(storageMigrationFromEnv({}), null);
  for (const value of [
    "-1",
    "1.5",
    "1e3",
    "4294967296",
    "9007199254740993",
    " 3",
    "03",
  ])
    assert.throws(() =>
      storageMigrationFromEnv({ HYPERION_SCHEMA_VERSION: value }),
    );
  assert.throws(
    () => storageMigrationFromEnv({ HYPERION_ROLLBACK_SUPPORTED: "false" }),
    /reason/,
  );
  assert.throws(() =>
    storageMigrationFromEnv({ HYPERION_ROLLBACK_SUPPORTED: "yes" }),
  );
  assert.equal(
    storageMigrationFromEnv({ HYPERION_SCHEMA_VERSION: "4294967295" })
      .schemaVersion,
    0xffffffff,
  );
});
test("writer rejects unsupported networks, malformed IDs and unbounded extension queues", async () => {
  for (const changes of [
    { STELLAR_NETWORK: "futurenet" },
    { HYPERION_FEE_BPS: "101" },
    { HYPERION_ROUTER_LEDGER: "4294967296" },
    { HYPERION_TIMELOCK_DELAY: "1e3" },
    { HYPERION_ROUTER: "C".repeat(56) },
    { QUEUE_IDS_JSON: "[1.5]" },
    { QUEUE_WHAT_JSON: "{}" },
    { QUEUE_WHAT_JSON: JSON.stringify(Array(129).fill("a")) },
    { QUEUE_IDS_JSON: " ".repeat(65537) },
  ])
    await assert.rejects(buildRecord({ ...env(), ...changes }));
});
test("archived writer record uses parser lifecycle fields and retains a valid successor contract", async () => {
  const successor = data.adapters.cctp;
  const record = await buildRecord({
    ...env(),
    HYPERION_STATUS: "archived",
    HYPERION_SUCCESSOR_ROUTER: successor,
    HYPERION_ARCHIVE_REASON: "Replaced deployment",
  });
  const archived = record.networks["stellar-testnet"];
  assert.equal(archived.status, "archived");
  assert.equal(archived.reason, "Replaced deployment");
  assert.equal(archived.successorRouter, successor);
  await assert.rejects(buildReport({ toRecord: record }), /archived/);
});
test("writer live ledger query checks RPC network and exact ledger bounds", async () => {
  const values = env();
  delete values.HYPERION_ROUTER_LEDGER;
  for (const sequence of [0, 1.5, 2 ** 53, 0x100000000, "100"])
    await assert.rejects(
      buildRecord(values, {
        rpc: async (method) =>
          method === "getNetwork"
            ? { passphrase: data.networkPassphrase }
            : { sequence },
      }),
      /ledger/,
    );
  await assert.rejects(
    buildRecord(values, { rpc: async () => ({ passphrase: "wrong" }) }),
    /network/,
  );
  const record = await buildRecord(values, {
    rpc: async (method) =>
      method === "getNetwork"
        ? { passphrase: data.networkPassphrase }
        : { sequence: 100 },
  });
  assert.equal(record.networks["stellar-testnet"].deployedAt.ledger, 100);
});
