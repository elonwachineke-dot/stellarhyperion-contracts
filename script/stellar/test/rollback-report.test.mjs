import { test } from "node:test";
import { createServer } from "node:http";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import { tmpdir } from "node:os";
import { spawnSync } from "node:child_process";
import {
  buildReport,
  fetchLiveEvidence,
  parseArgs,
  validateRecord,
  validateRpcUrl,
} from "../rollback-report.mjs";
import { cliCodec } from "../restore-plan.mjs";
import { validateStorageMigration } from "../record-evidence.mjs";

const ACTIVE = resolve("deployments/stellar-testnet-phase1.json");
const ARCHIVED = resolve("deployments/archive/stellar-testnet-2026-10-01.json");
const SCRIPT = resolve("script/stellar/rollback-report.mjs");
const original = JSON.parse(readFileSync(ACTIVE, "utf8"));
const record = () => structuredClone(original);
const data = (value) => value.networks["stellar-testnet"];
const cli = (args) =>
  spawnSync(process.execPath, [SCRIPT, ...args], {
    encoding: "utf8",
    timeout: 15000,
    maxBuffer: 1048576,
  });
const status = {
  current_version: 3,
  target_version: 3,
  migration_pending: false,
  migrated_transfers: "0",
  migrated_claims: "0",
  total_transfers: "0",
  total_claims: "0",
};

function liveFixture(options = {}) {
  let reads = 0;
  let invocations = 0;
  const calls = [];
  const router = data(original).router;
  const wasm = data(original).wasmHashes.router;
  const encoded = cliCodec.encode("LedgerEntryData", {
    contract_data: {
      ext: "v0",
      contract: router,
      key: "ledger_key_contract_instance",
      durability: "persistent",
      val: { contract_instance: { executable: { wasm }, storage: null } },
    },
  });
  return {
    get invocations() {
      return invocations;
    },
    calls,
    rpc: async (method, params) => {
      if (method === "getNetwork")
        return {
          passphrase: options.wrongNetwork
            ? "wrong"
            : data(original).networkPassphrase,
        };
      assert.equal(method, "getLedgerEntries");
      reads++;
      return {
        latestLedger: options.changedLedger && reads > 1 ? 101 : 100,
        entries: options.missing
          ? []
          : [
              {
                key: options.wrongKey ? "wrong" : params.keys[0],
                xdr: encoded,
              },
            ],
      };
    },
    codec: {
      encode: cliCodec.encode,
      decode: (type, text) => {
        const result = cliCodec.decode(type, text);
        if (options.wrongHash)
          result.contract_data.val.contract_instance.executable.wasm =
            "f".repeat(64);
        if (options.wrongContract) result.contract_data.contract = "wrong";
        return result;
      },
    },
    invoke: async (args) => {
      invocations++;
      calls.push(args);
      return JSON.stringify(options.status ?? status);
    },
  };
}

test("schema versions 0, 1, 2, 3 and future versions never certify compatibility", async () => {
  for (const schemaVersion of [0, 1, 2, 3, 99]) {
    const current = record();
    data(current).storageMigration = { schemaVersion, rollbackSupported: true };
    const report = await buildReport({ toRecord: current });
    assert.equal(report.storageMigration.rollbackSupported, null);
    assert.equal(report.storageMigration.recorded.rollbackSupported, true);
    assert.equal(report.deployment.schemaVersion, schemaVersion);
    assert.equal(report.deployment.schemaVersionSource, "recorded-claim");
    assert.ok(report.steps.every((step) => step.feasible === null));
    assert.equal(report.autoExecutes, false);
  }
});
test("explicit unsupported migration reason takes precedence over recorded/live schema", async () => {
  const current = record();
  data(current).storageMigration = {
    schemaVersion: 1,
    rollbackSupported: false,
    reason: "One-way liability migration reviewed in incident 134",
  };
  const live = await fetchLiveEvidence(
    current,
    "https://example.com/rpc",
    data(current).admin,
    liveFixture(),
  );
  const report = await buildReport({ toRecord: current, liveEvidence: live });
  assert.equal(report.deployment.schemaVersion, 3);
  assert.equal(report.storageMigration.rollbackSupported, false);
  assert.equal(
    report.storageMigration.reason,
    data(current).storageMigration.reason,
  );
  assert.equal(
    report.steps.find((step) => step.component === "router").feasible,
    false,
  );
  assert.equal(
    report.steps.find((step) => step.component === "adapter-cctp").feasible,
    null,
  );
});
test("missing evidence stays unknown; comparisons preserve old/new hashes and router identity", async () => {
  const from = JSON.parse(readFileSync(ARCHIVED, "utf8"));
  const current = record();
  const report = await buildReport({ fromRecord: from, toRecord: current });
  assert.equal(report.deployment.lifecycle, "unknown");
  assert.equal(report.deployment.schemaVersion, null);
  assert.equal(report.previousDeployment.sameContract, false);
  const router = report.codeHashes.find(
    (entry) => entry.component === "router",
  );
  assert.equal(router.currentHash, data(current).wasmHashes.router);
  assert.equal(router.previousHash, data(from).wasmHashes.router);
  assert.equal(router.changed, true);
  delete data(current).wasmHashes.router;
  const missing = await buildReport({ toRecord: current });
  assert.equal(
    missing.codeHashes.find((entry) => entry.component === "router")
      .currentHash,
    null,
  );
  assert.equal(
    missing.codeHashes.find((entry) => entry.component === "router").changed,
    null,
  );
  assert.ok(
    missing.steps.every(
      (step) =>
        step.authority.role &&
        step.authority.mechanism &&
        !step.authority.verifiedLive,
    ),
  );
  assert.ok(missing.requiredReview.some((text) => /Replay/.test(text)));
});
test("validator rejects invalid schemas, StrKey checksums, hashes, lifecycle and network mismatch", async () => {
  for (const alter of [
    (r) => (r.schemaVersion = 99),
    (r) => (data(r).router = "C".repeat(56)),
    (r) => (data(r).wasmHashes.router = "xyz"),
    (r) => (data(r).networkPassphrase = "wrong"),
    (r) => (data(r).status = "typo"),
    (r) => (data(r).feeBps = 101),
    (r) => (data(r).storageMigration = { schemaVersion: 2 ** 53 }),
    (r) => (data(r).storageMigration = { rollbackSupported: false }),
  ]) {
    const current = record();
    alter(current);
    await assert.rejects(validateRecord(current));
  }
  const archived = record();
  data(archived).status = "archived";
  data(archived).archivedAt = "2026-11-20T00:00:00.000Z";
  await assert.rejects(buildReport({ toRecord: archived }), /archived/);
  const wrongNetwork = record();
  wrongNetwork.networks.stellar = wrongNetwork.networks["stellar-testnet"];
  delete wrongNetwork.networks["stellar-testnet"];
  wrongNetwork.networks.stellar.networkPassphrase =
    "Public Global Stellar Network ; September 2015";
  await assert.rejects(
    buildReport({ toRecord: original, fromRecord: wrongNetwork }),
    /different networks/,
  );
});
test("migration extension validation refuses malformed, unbounded or unsupported-without-reason claims", () => {
  for (const value of [
    [],
    "3",
    { schemaVersion: -1 },
    { schemaVersion: 0x100000000 },
    { schemaVersion: 1.5 },
    { rollbackSupported: "false" },
    { rollbackSupported: false },
    { rollbackSupported: false, reason: " " },
    { reason: "x".repeat(2049) },
    { reason: "line\nbreak" },
    { typo: true },
  ])
    assert.throws(() => validateStorageMigration(value));
});
test("live evidence uses exact requested endpoint/passphrase/public source and read-only invocation", async () => {
  const fixture = liveFixture();
  const evidence = await fetchLiveEvidence(
    original,
    "https://example.com/custom-rpc",
    data(original).admin,
    fixture,
  );
  assert.equal(evidence.status, "observed");
  assert.equal(evidence.executableHash, data(original).wasmHashes.router);
  assert.equal(evidence.ledger, 100);
  const args = fixture.calls[0];
  assert.equal(
    args[args.indexOf("--rpc-url") + 1],
    "https://example.com/custom-rpc",
  );
  assert.equal(
    args[args.indexOf("--network-passphrase") + 1],
    data(original).networkPassphrase,
  );
  assert.equal(
    args[args.indexOf("--source-account") + 1],
    data(original).admin,
  );
  assert.ok(args.includes("--is-view"));
  assert.ok(!args.includes("--network"));
  const report = await buildReport({
    toRecord: original,
    liveEvidence: evidence,
  });
  assert.equal(report.storageMigration.rollbackSupported, null);
  await assert.rejects(
    buildReport({
      toRecord: original,
      liveEvidence: { ...evidence, executableHash: "e".repeat(64) },
    }),
    /bound/,
  );
});
test("wrong network/identity/hash, absent state, malformed counts and concurrent ledger changes remain unavailable", async () => {
  for (const options of [
    { wrongNetwork: true },
    { wrongHash: true },
    { wrongContract: true },
    { wrongKey: true },
    { missing: true },
    { changedLedger: true },
    { status: { ...status, current_version: 2 ** 53 } },
    { status: { ...status, migration_pending: "false" } },
    { status: { ...status, total_transfers: 2 ** 60 } },
    { status: { ...status, total_transfers: "18446744073709551616" } },
    { status: { ...status, migrated_claims: "1" } },
  ]) {
    const fixture = liveFixture(options);
    const evidence = await fetchLiveEvidence(
      original,
      "https://example.com/rpc",
      data(original).admin,
      fixture,
    );
    assert.equal(evidence.status, "unavailable");
    assert.equal(evidence.schemaVersion, null);
    if (options.wrongNetwork || options.wrongHash || options.missing)
      assert.equal(fixture.invocations, 0);
  }
  await assert.rejects(
    fetchLiveEvidence(original, "https://example.com", "S".repeat(56)),
    /public/,
  );
});
test("CLI paths/options and RPC URLs reject ambiguity and credentials", () => {
  for (const args of [
    [],
    ["--to"],
    [ACTIVE, "--to", ACTIVE],
    ["--from", ACTIVE],
    [ACTIVE, "--rpc", "https://example.com"],
    [ACTIVE, "--rpc", "--json"],
    [ACTIVE, "--source-account", data(original).admin],
    [ACTIVE, "--wat"],
  ])
    assert.throws(() => parseArgs(args));
  for (const url of [
    "http://localhost.evil/rpc",
    "http://example.com",
    "https://user:pass@example.com",
    "https://example.com/?token=private",
    "https://example.com/#a",
  ])
    assert.throws(() => validateRpcUrl(url));
  assert.equal(
    validateRpcUrl("http://127.0.0.1:8000"),
    "http://127.0.0.1:8000/",
  );
});
test("CLI emits real report JSON/human text and refuses invalid/oversized files", () => {
  const result = cli([ACTIVE, "--json"]);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(
    JSON.parse(result.stdout).storageMigration.rollbackSupported,
    null,
  );
  const text = cli([ACTIVE]);
  assert.equal(text.status, 0, text.stderr);
  assert.match(text.stdout, /Read-only: true/);
  const directory = mkdtempSync(resolve(tmpdir(), "hyperion-rollback-test-"));
  try {
    const file = resolve(directory, "record.json");
    const current = record();
    data(current).status = "archived";
    data(current).archivedAt = "2026-11-20T00:00:00.000Z";
    writeFileSync(file, JSON.stringify(current));
    assert.match(cli([file]).stderr, /archived/);
    writeFileSync(file, " ".repeat(1048577));
    assert.match(cli([file]).stderr, /exceeds/);
    writeFileSync(file, "{bad}");
    assert.notEqual(cli([file]).status, 0);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});

test("real RPC transport rejects oversized bodies, redirects and malformed responses", async () => {
  const server = createServer((request, response) => {
    if (request.url === "/redirect") {
      response.writeHead(302, { location: "/malformed" });
      response.end();
    } else if (request.url === "/oversized") {
      response.writeHead(200, { "content-type": "application/json" });
      response.end(" ".repeat(1048577));
    } else {
      response.writeHead(200, { "content-type": "application/json" });
      response.end("{malformed}");
    }
  });
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  try {
    const endpoint = `http://127.0.0.1:${server.address().port}`;
    for (const path of ["/oversized", "/redirect", "/malformed"]) {
      const evidence = await fetchLiveEvidence(
        original,
        endpoint + path,
        data(original).admin,
      );
      assert.equal(evidence.status, "unavailable");
      assert.equal(evidence.schemaVersion, null);
      if (path === "/oversized") assert.match(evidence.reason, /exceeds 1MiB/);
    }
  } finally {
    server.closeAllConnections();
    await new Promise((resolve) => server.close(resolve));
  }
});
