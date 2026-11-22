#!/usr/bin/env node
/** Read-only rollback evidence: recorded claims never certify code/storage compatibility. */
import { execFileSync } from "node:child_process";
import { resolve } from "node:path";
import { pathToFileURL } from "node:url";
import { cliCodec, rpcClient } from "./restore-plan.mjs";
import {
  loadDeploymentProtocol,
  readBoundedText,
  validateStorageMigration,
} from "./record-evidence.mjs";

const plain = (value) =>
  value !== null && typeof value === "object" && !Array.isArray(value);
const u32 = (value) =>
  Number.isSafeInteger(value) && value >= 0 && value <= 0xffffffff;
const hash = (value) =>
  typeof value === "string" && /^[a-f0-9]{64}$/.test(value);

export async function validateRecord(record) {
  const protocol = await loadDeploymentProtocol();
  const parsed = protocol.parseDeploymentSet(record);
  const keys = Object.keys(parsed.networks);
  if (keys.length !== 1)
    throw new Error("Expected exactly one network per record");
  const key = keys[0];
  const data = parsed.networks[key];
  const raw = record.networks[key];
  if (data.family !== "stellar")
    throw new Error("Expected a Stellar deployment record");
  if (data.networkPassphrase !== protocol.chain(key).networkPassphrase)
    throw new Error("Record network passphrase does not match its chain key");
  if (data.feeBps > 100) throw new Error("Record fee exceeds protocol cap");
  return {
    key,
    data,
    migration: validateStorageMigration(raw.storageMigration),
    lifecycle: raw.status ?? "unknown",
  };
}

function authority(component, deployment) {
  if (component === "router")
    return {
      role: "router admin",
      recordedAddress: deployment.admin,
      recordedTimelockDelay: deployment.timelockDelay,
      mechanism:
        "queue_action(AdminAction::Upgrade(previous_wasm_hash)), then execute_action after the admin timelock",
      verifiedLive: false,
    };
  return {
    role: "adapter admin",
    recordedAddress: null,
    recordedTimelockDelay: null,
    mechanism:
      "adapter upgrade(wasm_hash) requires the adapter's own admin; verify its identity and deployed implementation",
    verifiedLive: false,
  };
}

export async function buildReport({
  fromRecord = null,
  toRecord,
  liveEvidence = null,
  fromPath = null,
  toPath = null,
}) {
  const to = await validateRecord(toRecord);
  if (to.lifecycle === "archived")
    throw new Error(
      "Target record is archived; inspect the active successor record",
    );
  const from = fromRecord === null ? null : await validateRecord(fromRecord);
  if (
    from &&
    (from.key !== to.key ||
      from.data.networkPassphrase !== to.data.networkPassphrase)
  )
    throw new Error("Records belong to different networks");
  if (liveEvidence !== null && liveEvidence.status !== "unavailable") {
    if (
      !plain(liveEvidence) ||
      liveEvidence.status !== "observed" ||
      liveEvidence.networkPassphrase !== to.data.networkPassphrase ||
      liveEvidence.router !== to.data.router ||
      !u32(liveEvidence.ledger) ||
      liveEvidence.ledger === 0 ||
      !hash(liveEvidence.executableHash) ||
      liveEvidence.executableHash !== to.data.wasmHashes.router ||
      !u32(liveEvidence.schemaVersion) ||
      typeof liveEvidence.migrationPending !== "boolean"
    )
      throw new Error(
        "Live evidence is not bound to the recorded network, router and executable",
      );
  }
  const live = liveEvidence?.status === "observed" ? liveEvidence : null;
  const declaredUnsupported = to.migration?.rollbackSupported === false;
  const reason = declaredUnsupported
    ? to.migration.reason
    : "Compatibility is unknown: schema versions and recorded support claims do not prove the previous executable can safely read or write current storage";
  const components = new Set([
    "router",
    ...Object.keys(to.data.wasmHashes),
    ...Object.keys(from?.data.wasmHashes ?? {}),
  ]);
  const codeHashes = [...components].map((component) => {
    const currentHash = to.data.wasmHashes[component] ?? null;
    const previousHash = from?.data.wasmHashes[component] ?? null;
    return {
      component,
      currentHash,
      previousHash,
      source: "deployment-records",
      changed:
        currentHash === null || previousHash === null
          ? null
          : currentHash !== previousHash,
    };
  });
  return {
    generatedAt: new Date().toISOString(),
    reportKind: "upgrade-rollback-feasibility",
    readOnly: true,
    autoExecutes: false,
    deployment: {
      record: toPath,
      networkKey: to.key,
      networkPassphrase: to.data.networkPassphrase,
      router: to.data.router,
      admin: to.data.admin,
      timelockDelay: to.data.timelockDelay,
      lifecycle: to.lifecycle,
      schemaVersion: live?.schemaVersion ?? to.migration?.schemaVersion ?? null,
      schemaVersionSource: live
        ? "live-observation"
        : to.migration?.schemaVersion !== null &&
            to.migration?.schemaVersion !== undefined
          ? "recorded-claim"
          : "unknown",
    },
    previousDeployment: from
      ? {
          record: fromPath,
          router: from.data.router,
          sameContract: from.data.router === to.data.router,
          schemaVersion: from.migration?.schemaVersion ?? null,
        }
      : null,
    codeHashes,
    storageMigration: {
      recorded: to.migration,
      liveObservation: liveEvidence,
      rollbackSupported: declaredUnsupported ? false : null,
      reason,
    },
    steps: codeHashes.map((entry) => ({
      component: entry.component,
      action: "review-rollback",
      feasible:
        entry.component === "router" && declaredUnsupported ? false : null,
      currentHash: entry.currentHash,
      targetHash: entry.previousHash,
      blockedReason:
        entry.component === "router" && declaredUnsupported ? reason : null,
      authority: authority(entry.component, to.data),
      notes: [
        "Verify both executable hashes, code provenance, current state and compatibility; this report authorizes no action",
        ...(entry.previousHash === null
          ? ["Previous executable hash is unknown"]
          : []),
        ...(from && from.data.router !== to.data.router
          ? [
              "Records describe different router IDs; replacing a deployment is not an in-place WASM rollback",
            ]
          : []),
      ],
    })),
    requiredReview: [
      "Previous and current code provenance and migration-specific compatibility",
      "Authenticated dispatch and adapter trust records",
      "Exact integer balances, outstanding liabilities and recipient-bound claims",
      "Replay protection, archived state and failed-operation recovery",
      "Live admin identity, timelock configuration and any pending migration",
    ],
    evmGatingNote:
      "This Stellar report provides no EVM rollback or route-activation evidence; EVM decisions require independent validation",
  };
}

export function validateRpcUrl(value) {
  if (typeof value !== "string" || value.length > 4096)
    throw new Error("RPC URL must be bounded text");
  const endpoint = new URL(value);
  if (
    endpoint.username ||
    endpoint.password ||
    endpoint.hash ||
    endpoint.search ||
    (endpoint.protocol !== "https:" &&
      !(
        endpoint.protocol === "http:" &&
        ["localhost", "127.0.0.1", "[::1]"].includes(endpoint.hostname)
      ))
  )
    throw new Error(
      "Use an HTTPS or loopback RPC URL without credentials, query or fragment",
    );
  return endpoint.href;
}

/** Read a network/executable-bound schema observation. No signatures or submitted transactions. */
export async function fetchLiveEvidence(
  record,
  url,
  sourceAccount,
  dependencies = {},
) {
  const endpoint = validateRpcUrl(url);
  const selected = await validateRecord(record);
  const protocol = await loadDeploymentProtocol();
  if (
    typeof sourceAccount !== "string" ||
    !sourceAccount.startsWith("G") ||
    !protocol.isStellarAddress(sourceAccount)
  )
    throw new Error(
      "--source-account requires an explicit public Stellar G address",
    );
  const rpc = dependencies.rpc ?? rpcClient(endpoint);
  const codec = dependencies.codec ?? cliCodec;
  const invoke =
    dependencies.invoke ??
    ((args) =>
      execFileSync("stellar", args, {
        encoding: "utf8",
        timeout: 20000,
        maxBuffer: 32768,
        stdio: ["ignore", "pipe", "ignore"],
      }));
  try {
    const network = await rpc("getNetwork", {});
    if (network.passphrase !== selected.data.networkPassphrase)
      throw new Error("RPC network does not match record");
    const key = codec.encode("LedgerKey", {
      contract_data: {
        contract: selected.data.router,
        key: "ledger_key_contract_instance",
        durability: "persistent",
      },
    });
    async function executable() {
      const response = await rpc("getLedgerEntries", { keys: [key] });
      if (
        !u32(response.latestLedger) ||
        response.latestLedger === 0 ||
        !Array.isArray(response.entries) ||
        response.entries.length !== 1 ||
        response.entries[0].key !== key
      )
        throw new Error("Current executable evidence is unavailable");
      const data = codec.decode(
        "LedgerEntryData",
        response.entries[0].xdr,
      )?.contract_data;
      const wasm = data?.val?.contract_instance?.executable?.wasm;
      if (
        data?.contract !== selected.data.router ||
        data?.key !== "ledger_key_contract_instance" ||
        data?.durability !== "persistent" ||
        !hash(wasm) ||
        wasm !== selected.data.wasmHashes.router
      )
        throw new Error("Live executable does not match the record");
      return { hash: wasm, ledger: response.latestLedger };
    }
    const before = await executable();
    const text = await invoke([
      "contract",
      "invoke",
      "--id",
      selected.data.router,
      "--rpc-url",
      endpoint,
      "--network-passphrase",
      selected.data.networkPassphrase,
      "--source-account",
      sourceAccount,
      "--is-view",
      "--",
      "get_migration_status",
    ]);
    if (typeof text !== "string" || Buffer.byteLength(text) > 32768)
      throw new Error("Migration response exceeds limit");
    const status = JSON.parse(text);
    if (
      !plain(status) ||
      !u32(status.current_version) ||
      !u32(status.target_version) ||
      typeof status.migration_pending !== "boolean"
    )
      throw new Error("Invalid migration status");
    for (const name of [
      "migrated_transfers",
      "migrated_claims",
      "total_transfers",
      "total_claims",
    ]) {
      const count = status[name];
      if (
        (typeof count === "number" && !Number.isSafeInteger(count)) ||
        !["number", "string"].includes(typeof count) ||
        !/^(0|[1-9][0-9]{0,19})$/.test(String(count)) ||
        BigInt(count) > 18446744073709551615n
      )
        throw new Error("Invalid exact migration count");
    }
    if (
      status.target_version < status.current_version ||
      BigInt(status.migrated_transfers) > BigInt(status.total_transfers) ||
      BigInt(status.migrated_claims) > BigInt(status.total_claims)
    )
      throw new Error("Inconsistent migration status");
    const after = await executable();
    if (before.hash !== after.hash || before.ledger !== after.ledger)
      throw new Error(
        "Ledger changed during schema observation; retry for consistent evidence",
      );
    return {
      status: "observed",
      endpoint,
      networkPassphrase: network.passphrase,
      router: selected.data.router,
      executableHash: after.hash,
      ledger: after.ledger,
      schemaVersion: status.current_version,
      migrationPending: status.migration_pending,
      migration: status,
    };
  } catch (error) {
    return {
      status: "unavailable",
      reason: error.message,
      schemaVersion: null,
      executableHash: null,
    };
  }
}

export function parseArgs(args) {
  const options = {
    fromPath: null,
    toPath: null,
    rpcUrl: null,
    sourceAccount: null,
    json: false,
  };
  const names = {
    "--from": "fromPath",
    "--to": "toPath",
    "--rpc": "rpcUrl",
    "--source-account": "sourceAccount",
  };
  for (let i = 0; i < args.length; i++) {
    const arg = args[i];
    if (arg === "--json") {
      if (options.json) throw new Error("Duplicate --json");
      options.json = true;
    } else if (names[arg]) {
      const value = args[++i];
      if (
        !value ||
        value.startsWith("--") ||
        value.length > 4096 ||
        options[names[arg]] !== null
      )
        throw new Error(`Missing or duplicate ${arg}`);
      options[names[arg]] = value;
    } else if (arg.startsWith("-") || options.toPath !== null)
      throw new Error("Unknown option or conflicting record paths");
    else options.toPath = arg;
  }
  if (
    !options.toPath ||
    (options.sourceAccount !== null && options.rpcUrl === null) ||
    (options.rpcUrl !== null && options.sourceAccount === null)
  )
    throw new Error(
      "Usage: rollback-report.mjs RECORD [--from RECORD] [--json] [--rpc URL --source-account PUBLIC_G_ADDRESS]",
    );
  return options;
}

export function renderReport(report) {
  return [
    "Upgrade Rollback Feasibility Report",
    "Read-only: true   Auto-executes: false",
    `Network: ${report.deployment.networkKey}`,
    `Router: ${report.deployment.router}`,
    `Lifecycle: ${report.deployment.lifecycle}`,
    `Schema: ${report.deployment.schemaVersion ?? "unknown"} (${report.deployment.schemaVersionSource})`,
    `Rollback: ${report.storageMigration.rollbackSupported === false ? "UNSUPPORTED (recorded)" : "UNKNOWN"}`,
    report.storageMigration.reason,
    ...report.codeHashes.map(
      (entry) =>
        `${entry.component}: previous ${entry.previousHash ?? "unknown"}; current ${entry.currentHash ?? "unknown"} (recorded)`,
    ),
    ...report.steps.map(
      (step) =>
        `${step.component} authority: ${step.authority.role}; ${step.authority.mechanism}`,
    ),
    ...(report.storageMigration.liveObservation
      ? [
          `Live evidence: ${JSON.stringify(report.storageMigration.liveObservation)}`,
        ]
      : []),
    `Required review: ${report.requiredReview.join("; ")}`,
  ].join("\n");
}

export async function runCli(args = process.argv.slice(2)) {
  const options = parseArgs(args);
  const toRecord = JSON.parse(readBoundedText(resolve(options.toPath)));
  const fromRecord =
    options.fromPath === null
      ? null
      : JSON.parse(readBoundedText(resolve(options.fromPath)));
  const liveEvidence =
    options.rpcUrl === null
      ? null
      : await fetchLiveEvidence(
          toRecord,
          options.rpcUrl,
          options.sourceAccount,
        );
  const report = await buildReport({
    ...options,
    toRecord,
    fromRecord,
    liveEvidence,
  });
  process.stdout.write(
    `${options.json ? JSON.stringify(report, null, 2) : renderReport(report)}\n`,
  );
  return report;
}

if (
  process.argv[1] &&
  pathToFileURL(resolve(process.argv[1])).href === import.meta.url
) {
  runCli().catch((error) => {
    process.stderr.write(`failed: ${error.message}\n`);
    process.exitCode = 1;
  });
}
