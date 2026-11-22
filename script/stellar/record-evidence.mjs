/** Shared bounded record input and migration metadata validation for read-only tooling. */
import {
  closeSync,
  constants,
  fstatSync,
  lstatSync,
  mkdtempSync,
  mkdirSync,
  openSync,
  readSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createRequire } from "node:module";
import { tmpdir } from "node:os";
import { dirname, resolve, relative } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

export const MAX_RECORD_BYTES = 1048576;
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
let loaded;

/** Load the checked-out deployment validator even in jobs without generated ABI/dist files. */
export function loadDeploymentProtocol() {
  loaded ??= (async () => {
    const require = createRequire(
      resolve(ROOT, "packages/protocol/package.json"),
    );
    const ts = require("typescript");
    const sourceRoot = resolve(ROOT, "packages/protocol/src");
    const directory = mkdtempSync(
      resolve(tmpdir(), "hyperion-record-validator-"),
    );
    const visited = new Set();
    try {
      writeFileSync(resolve(directory, "package.json"), '{"type":"module"}\n');
      function compile(name) {
        if (visited.has(name)) return;
        if (
          visited.size >= 32 ||
          !/^[A-Za-z0-9_./-]+\.js$/.test(name) ||
          name.split("/").includes("..")
        )
          throw new Error("Invalid validator module dependency");
        visited.add(name);
        const input = resolve(sourceRoot, name.replace(/\.js$/, ".ts"));
        if (!lstatSync(input).isFile())
          throw new Error("Validator sources must be regular files");
        const source = readBoundedText(input);
        const output = ts.transpileModule(source, {
          compilerOptions: {
            module: ts.ModuleKind.ESNext,
            target: ts.ScriptTarget.ES2022,
          },
          reportDiagnostics: true,
        });
        if (
          output.diagnostics?.some(
            (d) => d.category === ts.DiagnosticCategory.Error,
          )
        )
          throw new Error("Validator source failed to compile");
        const filename = resolve(directory, name);
        mkdirSync(dirname(filename), { recursive: true });
        writeFileSync(filename, output.outputText);
        for (const dependency of ts.preProcessFile(output.outputText)
          .importedFiles) {
          if (!dependency.fileName.startsWith("."))
            throw new Error("Unexpected external validator dependency");
          compile(
            relative(
              directory,
              resolve(dirname(filename), dependency.fileName),
            ),
          );
        }
      }
      for (const module of ["deployments.js", "chains.js", "addresses.js"])
        compile(module);
      const modules = await Promise.all(
        ["deployments.js", "chains.js", "addresses.js"].map(
          (name) => import(pathToFileURL(resolve(directory, name)).href),
        ),
      );
      return Object.assign({}, ...modules);
    } finally {
      rmSync(directory, { recursive: true, force: true });
    }
  })();
  return loaded;
}

export function readBoundedText(pathOrFd, limit = MAX_RECORD_BYTES) {
  const own = typeof pathOrFd !== "number";
  const fd = own
    ? openSync(
        pathOrFd,
        constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK,
      )
    : pathOrFd;
  try {
    if (own && !fstatSync(fd).isFile())
      throw new Error("Input must be a regular file");
    const chunks = [];
    let length = 0;
    while (true) {
      const buffer = Buffer.alloc(Math.min(8192, limit + 1 - length));
      const count = readSync(fd, buffer, 0, buffer.length, null);
      if (count === 0) break;
      length += count;
      if (length > limit) throw new Error(`Input exceeds ${limit} bytes`);
      chunks.push(buffer.subarray(0, count));
    }
    return Buffer.concat(chunks, length).toString("utf8");
  } finally {
    if (own) closeSync(fd);
  }
}

export function validateStorageMigration(value) {
  if (value === undefined || value === null) return null;
  if (typeof value !== "object" || Array.isArray(value))
    throw new Error("storageMigration must be an object");
  if (
    Object.keys(value).some(
      (key) => !["schemaVersion", "rollbackSupported", "reason"].includes(key),
    )
  )
    throw new Error("Unknown storageMigration field");
  const schemaVersion = value.schemaVersion ?? null;
  if (
    schemaVersion !== null &&
    (!Number.isSafeInteger(schemaVersion) ||
      schemaVersion < 0 ||
      schemaVersion > 0xffffffff)
  )
    throw new Error("storageMigration.schemaVersion must be a u32 or null");
  const rollbackSupported = value.rollbackSupported ?? null;
  if (rollbackSupported !== null && typeof rollbackSupported !== "boolean")
    throw new Error("storageMigration.rollbackSupported must be boolean");
  const reason = value.reason ?? null;
  if (
    reason !== null &&
    (typeof reason !== "string" ||
      !reason.trim() ||
      reason.length > 2048 ||
      /[\u0000-\u001f\u007f]/.test(reason))
  )
    throw new Error("storageMigration.reason must be bounded non-empty text");
  if (rollbackSupported === false && reason === null)
    throw new Error("Unsupported rollback requires a reason");
  return { schemaVersion, rollbackSupported, reason };
}

export function storageMigrationFromEnv(env = process.env) {
  const version = env.HYPERION_SCHEMA_VERSION;
  const supported = env.HYPERION_ROLLBACK_SUPPORTED;
  const reason = env.HYPERION_ROLLBACK_REASON;
  if (!version && !supported && !reason) return null;
  if (version && !/^(0|[1-9][0-9]{0,9})$/.test(version))
    throw new Error("HYPERION_SCHEMA_VERSION must be an exact u32");
  if (supported && !["true", "false"].includes(supported))
    throw new Error(
      "HYPERION_ROLLBACK_SUPPORTED must be true, false, or unset",
    );
  return validateStorageMigration({
    schemaVersion: version ? Number(version) : null,
    ...(supported ? { rollbackSupported: supported === "true" } : {}),
    ...(reason ? { reason } : {}),
  });
}
