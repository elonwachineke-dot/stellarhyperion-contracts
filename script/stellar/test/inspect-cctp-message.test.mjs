import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";
import {
  inspectCctpMessage,
  parseHex,
  MAX_MESSAGE_BYTES,
  MAX_HEX_TEXT_BYTES,
} from "../inspect-cctp-message.mjs";

function message(kind = 0) {
  const bytes = Buffer.alloc(376 + (kind === 2 ? 42 : 34), 0);
  for (const offset of [0, 148]) bytes.writeUInt32BE(1, offset);
  bytes.writeUInt32BE(1000, 140);
  bytes.writeUInt32BE(2000, 144);
  for (let i = 0; i < 32; i++) bytes[12 + i] = i + 1;
  bytes.fill(0xff, 216, 248);
  bytes[376] = 1;
  bytes[377] = kind;
  bytes.fill(0xab, 378, 410);
  if (kind === 2) bytes.fill(0xff, 410, 418);
  return bytes;
}
const SCRIPT = resolve("script/stellar/inspect-cctp-message.mjs");
const cli = (args, input = "") =>
  spawnSync(process.execPath, [SCRIPT, ...args], {
    encoding: "utf8",
    input,
    timeout: 10000,
    maxBuffer: 1048576,
  });

test("supported account, contract and muxed shapes retain full integers without certifying execution", () => {
  for (const kind of [0, 1, 2]) {
    const bytes = message(kind);
    const report = inspectCctpMessage(bytes);
    assert.equal(report.structurallyCompatible, true);
    assert.equal(report.executable, false);
    assert.equal(report.fields.nonce, bytes.subarray(12, 44).toString("hex"));
    assert.equal(report.fields.amount, ((1n << 256n) - 1n).toString());
    assert.equal(report.hook.bytes, bytes.subarray(376).toString("hex"));
    assert.equal(
      report.hook.muxedId,
      kind === 2 ? "18446744073709551615" : null,
    );
    assert.deepEqual(report.diagnostics, []);
    assert.ok(report.unverifiedExecutionChecks.includes("attestation"));
  }
});
test("unknown message, burn, hook versions and kind stay visible as known-layout observations", () => {
  for (const [offset, width, code] of [
    [0, 4, "UNSUPPORTED_MESSAGE_VERSION"],
    [148, 4, "UNSUPPORTED_BURN_VERSION"],
    [376, 1, "UNSUPPORTED_HOOK_VERSION"],
    [377, 1, "UNKNOWN_HOOK_KIND"],
  ]) {
    const bytes = message();
    if (width === 4) bytes.writeUInt32BE(99, offset);
    else bytes[offset] = 99;
    const report = inspectCctpMessage(bytes);
    assert.equal(report.executable, false);
    assert.equal(report.structurallyCompatible, false);
    assert.equal(report.rawBytes, bytes.toString("hex"));
    assert.match(report.fieldInterpretation, /unknown versions/);
    assert.equal(
      report.diagnostics.find((d) => d.code === code).offset,
      offset,
    );
  }
});
test("every truncated fixed field reports its actual byte offset and width", () => {
  for (const [name, offset, width] of [
    ["version", 0, 4],
    ["sourceDomain", 4, 4],
    ["destinationDomain", 8, 4],
    ["nonce", 12, 32],
    ["sender", 44, 32],
    ["recipient", 76, 32],
    ["destinationCaller", 108, 32],
    ["minFinalityThreshold", 140, 4],
    ["finalityThresholdExecuted", 144, 4],
    ["burnVersion", 148, 4],
    ["burnToken", 152, 32],
    ["mintRecipient", 184, 32],
    ["amount", 216, 32],
    ["messageSender", 248, 32],
    ["maxFee", 280, 32],
    ["feeExecuted", 312, 32],
    ["expirationBlock", 344, 32],
  ]) {
    const report = inspectCctpMessage(
      message().subarray(0, offset + width - 1),
    );
    const diagnostic = report.diagnostics.find((d) => d.field === name);
    assert.equal(diagnostic.offset, offset);
    assert.equal(diagnostic.availableBytes, width - 1);
    assert.equal(report.fields[name], null);
  }
});
test("truncated, oversized and mismatched hooks retain complete bounded bytes with offsets", () => {
  for (const [length, code, offset] of [
    [33, "TRUNCATED_HOOK", 376],
    [35, "INVALID_HOOK_LENGTH", 376],
    [43, "OVERSIZED_HOOK", 418],
    [42, "HOOK_KIND_LENGTH_MISMATCH", 377],
  ]) {
    const bytes = Buffer.concat([message(), Buffer.alloc(64, 0xdd)]).subarray(
      0,
      376 + length,
    );
    const report = inspectCctpMessage(bytes);
    assert.equal(report.hook.bytes, bytes.subarray(376).toString("hex"));
    assert.equal(
      report.diagnostics.find((d) => d.code === code).offset,
      offset,
    );
    assert.equal(report.structurallyCompatible, false);
  }
  const zero = message();
  zero.fill(0, 378, 410);
  assert.equal(
    inspectCctpMessage(zero).diagnostics.find((d) => d.code === "ZERO_HOOK_KEY")
      .offset,
    378,
  );
});
test("unsupported finality requirements identify header offsets", () => {
  const bytes = message();
  bytes.writeUInt32BE(999, 140);
  bytes.writeUInt32BE(2001, 144);
  const report = inspectCctpMessage(bytes);
  assert.equal(
    report.diagnostics.find((d) => d.code === "UNSUPPORTED_MIN_FINALITY")
      .offset,
    140,
  );
  assert.equal(
    report.diagnostics.find((d) => d.code === "UNSUPPORTED_EXECUTED_FINALITY")
      .offset,
    144,
  );
});
test("hex input refuses coercion, malformed syntax and decoded/text size excess", () => {
  for (const value of [null, undefined, {}, 123, "", "0x", "abc", "zz", "0x0g"])
    assert.throws(() => parseHex(value));
  assert.deepEqual(parseHex(" 0x aa\nBB "), Buffer.from("aabb", "hex"));
  assert.throws(
    () => inspectCctpMessage(Buffer.alloc(MAX_MESSAGE_BYTES + 1)),
    /exceeds/,
  );
  assert.throws(() => parseHex("aa".repeat(MAX_MESSAGE_BYTES + 1)), /exceeds/);
  assert.throws(() => parseHex(" ".repeat(MAX_HEX_TEXT_BYTES + 1)), /bounded/);
  assert.equal(
    inspectCctpMessage(Buffer.alloc(MAX_MESSAGE_BYTES)).byteLength,
    MAX_MESSAGE_BYTES,
  );
});
test("CLI rejects conflicting/missing options and bounded stdin/file excess", () => {
  for (const args of [
    ["--message"],
    ["--file"],
    ["--message", "--compact"],
    ["--message", "aa", "--message", "bb"],
    ["--file", "a", "--message", "bb"],
    ["--wat"],
  ])
    assert.notEqual(cli(args).status, 0);
  const bytes = message().toString("hex");
  const valid = cli(["--compact"], bytes);
  assert.equal(valid.status, 0, valid.stderr);
  assert.equal(JSON.parse(valid.stdout).executable, false);
  assert.notEqual(cli([], " ".repeat(MAX_HEX_TEXT_BYTES + 1)).status, 0);
  const directory = mkdtempSync(resolve(tmpdir(), "hyperion-cctp-test-"));
  try {
    const file = resolve(directory, "message.hex");
    writeFileSync(file, bytes);
    assert.equal(cli(["--file", file]).status, 0);
    writeFileSync(file, " ".repeat(MAX_HEX_TEXT_BYTES + 1));
    assert.match(cli(["--file", file]).stderr, /exceeds/);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
