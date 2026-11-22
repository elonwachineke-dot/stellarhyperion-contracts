/**
 * The contract interface capability snapshots, checked across all three implementations.
 *
 * `testdata/capabilities/*.cap` is the reviewed record of each contract surface's public methods
 * and the routes it advertises. This file is the cross-language half of the check: each contract
 * crate's own suite compares its surface to the same file, and this suite proves that the Rust,
 * the Solidity and the TypeScript agree with each other and with the compiled ABIs.
 *
 * Two things it is deliberately strict about:
 *
 * - A paid entry point that disappears must be acknowledged (`removed-paid-method`) in the same
 *   change, because the app decides whether it can offer a paid transfer by looking for it.
 * - A `gated` surface is recorded but not activated. The active deployment is Stellar Testnet
 *   outbound ITS/CCTP; recording an EVM method here never turns it on.
 *
 * The failure cases below run against local fixture strings, so the rules stay tested even when
 * the real snapshots are stable.
 */
import { readFileSync, readdirSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";

import { hyperionRouterAbi } from "../src/abi/router.js";
import { cctpAdapterAbi } from "../src/abi/cctpAdapter.js";
import { axelarItsAdapterAbi } from "../src/abi/axelarItsAdapter.js";
import { tokenRecoveryManagerAbi } from "../src/abi/tokenRecoveryManager.js";
import { ROUTE_KINDS, ROUTE_SLUGS } from "../src/routes.js";

const here = dirname(fileURLToPath(import.meta.url));
const packageRoot = resolve(here, "..");
const repoRoot = resolve(packageRoot, "..", "..");
const capsDir = join(repoRoot, "testdata", "capabilities");

const ROUTE_ORDER: string[] = ROUTE_KINDS.map((kind) => ROUTE_SLUGS[kind]);
const STATUSES = new Set(["active", "gated"]);
const DIRECTIVES = new Set([
  "surface",
  "contract",
  "status",
  "method",
  "route",
  "paid-route",
  "paid-method",
  "removed-paid-method",
]);

interface Entry {
  directive: string;
  value: string;
  detail: string;
}

interface Snapshot {
  file: string;
  surface: string;
  contract: string;
  status: string;
  methods: string[];
  routes: string[];
  paidRoutes: string[];
  paidMethods: string[];
  removed: Entry[];
}

function read(path: string): string {
  return readFileSync(path, "utf8");
}

/** Parse the line oriented grammar documented in `soroban/test-support/capability.rs`. */
function parse(snapshot: string): Entry[] {
  const entries: Entry[] = [];
  for (const raw of snapshot.split("\n")) {
    const line = raw.trim();
    if (line.length === 0 || line.startsWith("#")) continue;
    const space = line.search(/\s/);
    const directive = space === -1 ? line : line.slice(0, space);
    const rest = space === -1 ? "" : line.slice(space).trimStart();
    const split = rest.search(/\s/);
    const value = split === -1 ? rest : rest.slice(0, split);
    const detail = split === -1 ? "" : rest.slice(split).trimStart();
    entries.push({ directive, value, detail });
  }
  return entries;
}

function single(entries: Entry[], directive: string, where: string): string {
  const found = entries.filter((entry) => entry.directive === directive);
  if (found.length !== 1) {
    throw new Error(
      `${where}: expected exactly one \`${directive}\`, found ${String(found.length)}`,
    );
  }
  return found[0]!.value;
}

function values(entries: Entry[], directive: string): string[] {
  return entries.filter((entry) => entry.directive === directive).map((entry) => entry.value);
}

function expectUnique(list: string[], directive: string, where: string): void {
  const seen = new Set<string>();
  for (const value of list) {
    if (seen.has(value)) throw new Error(`${where}: duplicate \`${directive} ${value}\``);
    seen.add(value);
  }
}

function expectSorted(list: string[], directive: string, where: string): void {
  const sorted = [...list].sort();
  if (JSON.stringify(sorted) !== JSON.stringify(list)) {
    throw new Error(`${where}: \`${directive}\` lines must be sorted`);
  }
}

/** The history is the memory that makes a silent paid-method removal impossible. */
function historyFor(history: string, surface: string): string[] {
  return parse(history)
    .filter((entry) => entry.directive === "paid-method" && entry.value === surface)
    .map((entry) => entry.detail);
}

function validate(
  snapshot: string,
  expected: { file: string; surface: string; contract: string },
  history: string,
): Snapshot {
  const where = expected.file;
  const entries = parse(snapshot);
  for (const entry of entries) {
    if (!DIRECTIVES.has(entry.directive)) {
      throw new Error(`${where}: unknown capability directive \`${entry.directive}\``);
    }
  }
  const surface = single(entries, "surface", where);
  const contract = single(entries, "contract", where);
  const status = single(entries, "status", where);
  if (surface !== expected.surface) {
    throw new Error(`${where}: surface is \`${surface}\`, expected \`${expected.surface}\``);
  }
  if (contract !== expected.contract) {
    throw new Error(`${where}: contract is \`${contract}\`, expected \`${expected.contract}\``);
  }
  if (!STATUSES.has(status))
    throw new Error(`${where}: status \`${status}\` is not active or gated`);

  const methods = values(entries, "method");
  if (methods.length === 0) throw new Error(`${where}: a surface must declare its methods`);
  expectUnique(methods, "method", where);
  expectSorted(methods, "method", where);

  const routes = values(entries, "route");
  expectUnique(routes, "route", where);
  let lastRoute = -1;
  for (const route of routes) {
    const position = ROUTE_ORDER.indexOf(route);
    if (position === -1) throw new Error(`${where}: \`route ${route}\` is not a protocol slug`);
    if (position <= lastRoute) {
      throw new Error(`${where}: \`route\` lines must follow RouteKind order`);
    }
    lastRoute = position;
  }

  const paidRoutes = values(entries, "paid-route");
  expectUnique(paidRoutes, "paid-route", where);
  for (const route of paidRoutes) {
    if (!ROUTE_ORDER.includes(route)) {
      throw new Error(`${where}: \`paid-route ${route}\` is not a protocol slug`);
    }
  }
  const paidPositions = paidRoutes.map((route) => ROUTE_ORDER.indexOf(route));
  if (JSON.stringify([...paidPositions].sort((a, b) => a - b)) !== JSON.stringify(paidPositions)) {
    throw new Error(`${where}: \`paid-route\` lines must follow RouteKind order`);
  }
  for (const route of paidRoutes) {
    if (!routes.includes(route)) {
      throw new Error(`${where}: \`paid-route ${route}\` is not one of the surface's routes`);
    }
  }

  const paidMethods = values(entries, "paid-method");
  expectUnique(paidMethods, "paid-method", where);
  expectSorted(paidMethods, "paid-method", where);
  for (const method of paidMethods) {
    if (!methods.includes(method)) {
      throw new Error(`${where}: \`paid-method ${method}\` is not one of the surface's methods`);
    }
  }

  const removed = entries.filter((entry) => entry.directive === "removed-paid-method");
  expectUnique(
    removed.map((entry) => entry.value),
    "removed-paid-method",
    where,
  );
  for (const entry of removed) {
    if (entry.value.length === 0) throw new Error(`${where}: removed-paid-method needs a name`);
    if (methods.includes(entry.value)) {
      throw new Error(`${where}: \`removed-paid-method ${entry.value}\` is still callable`);
    }
    if (!entry.detail.startsWith("acknowledged=")) {
      throw new Error(`${where}: \`removed-paid-method ${entry.value}\` needs acknowledged=<ref>`);
    }
    if (!entry.detail.includes("reason=")) {
      throw new Error(`${where}: \`removed-paid-method ${entry.value}\` needs reason=`);
    }
  }

  const memory = historyFor(history, surface);
  const removedNames = removed.map((entry) => entry.value);
  for (const name of memory) {
    if (!methods.includes(name) && !removedNames.includes(name)) {
      throw new Error(
        `${where}: paid method ${name} is gone and has no removed-paid-method acknowledgement`,
      );
    }
  }
  for (const name of paidMethods) {
    if (!memory.includes(name)) {
      throw new Error(`${where}: paid method ${name} is missing from paid-method-history.txt`);
    }
  }
  for (const name of removedNames) {
    if (!memory.includes(name)) {
      throw new Error(`${where}: \`removed-paid-method ${name}\` was never a paid method`);
    }
  }

  return {
    file: where,
    surface,
    contract,
    status,
    methods,
    routes,
    paidRoutes,
    paidMethods,
    removed,
  };
}

/** The `pub fn` names inside `#[contractimpl] impl <contract>`, ignoring comments and strings. */
function rustContractMethods(source: string, contract: string): string[] {
  const attribute = source.indexOf("#[contractimpl]");
  if (attribute === -1) throw new Error(`${contract} source has no #[contractimpl] block`);
  const header = source.indexOf(`impl ${contract} {`, attribute);
  if (header === -1) throw new Error(`no \`impl ${contract}\` after #[contractimpl]`);
  const open = source.indexOf("{", header);
  let depth = 0;
  let end = -1;
  let lineComment = false;
  let blockComment = false;
  let inString = false;
  let previous = "";
  for (let index = open; index < source.length; index += 1) {
    const character = source[index]!;
    if (lineComment) {
      if (character === "\n") lineComment = false;
    } else if (blockComment) {
      if (previous === "*" && character === "/") blockComment = false;
    } else if (inString) {
      if (character === '"' && previous !== "\\") inString = false;
    } else if (previous === "/" && character === "/") {
      lineComment = true;
    } else if (previous === "/" && character === "*") {
      blockComment = true;
    } else if (character === '"') {
      inString = true;
    } else if (character === "{") {
      depth += 1;
    } else if (character === "}") {
      depth -= 1;
      if (depth === 0) {
        end = index;
        break;
      }
    }
    previous = character;
  }
  if (end === -1) throw new Error(`unbalanced braces in the ${contract} impl block`);
  const methods: string[] = [];
  for (const line of source.slice(open, end + 1).split("\n")) {
    const match = /^\s*pub fn\s+([a-z_][a-z0-9_]*)\s*\(/.exec(line);
    if (match && !methods.includes(match[1]!)) methods.push(match[1]!);
  }
  return methods.sort();
}

const RUST_VARIANT_TO_SLUG: Record<string, string> = {
  Cctp: "cctp",
  AxelarIts: "axelar-its",
  AxelarGmp: "axelar-gmp",
  Allbridge: "allbridge",
};

/** Every `RouteKind::X` a contract module names is a route it can handle. */
function rustAdvertisedRoutes(source: string): string[] {
  const variants = new Set<string>();
  for (const match of source.matchAll(/RouteKind::([A-Za-z0-9]+)/g)) variants.add(match[1]!);
  return [...variants].map((variant) => {
    const slug = RUST_VARIANT_TO_SLUG[variant];
    if (!slug) throw new Error(`unknown RouteKind variant ${variant} in the contract source`);
    return slug;
  });
}

/** The body of `supports_paid_route`, which is what the app reads before offering gas. */
function rustPaidRouteAdvertisement(source: string): string[] {
  const start = source.indexOf("pub fn supports_paid_route");
  if (start === -1) throw new Error("the router no longer exports supports_paid_route");
  const body = source.slice(start, source.indexOf("\n    }", start));
  return rustAdvertisedRoutes(body);
}

interface SurfaceCase {
  file: string;
  surface: string;
  contract: string;
  status: "active" | "gated";
  kind: "rust" | "evm";
  source?: string;
  abi?: readonly { type: string; name?: string; stateMutability?: string }[];
}

const SURFACES: SurfaceCase[] = [
  {
    file: "soroban-router.cap",
    surface: "soroban/router",
    contract: "HyperionRouter",
    status: "active",
    kind: "rust",
    source: join(repoRoot, "soroban", "crates", "hyperion-router", "src", "lib.rs"),
  },
  {
    file: "soroban-cctp-adapter.cap",
    surface: "soroban/cctp-adapter",
    contract: "CctpAdapter",
    status: "active",
    kind: "rust",
    source: join(repoRoot, "soroban", "crates", "hyperion-adapter-cctp", "src", "lib.rs"),
  },
  {
    file: "soroban-axelar-adapter.cap",
    surface: "soroban/axelar-adapter",
    contract: "AxelarAdapter",
    status: "active",
    kind: "rust",
    source: join(repoRoot, "soroban", "crates", "hyperion-adapter-axelar", "src", "lib.rs"),
  },
  {
    file: "soroban-allbridge-adapter.cap",
    surface: "soroban/allbridge-adapter",
    contract: "AllbridgeAdapter",
    status: "gated",
    kind: "rust",
    source: join(repoRoot, "soroban", "crates", "hyperion-adapter-allbridge", "src", "lib.rs"),
  },
  {
    file: "evm-router.cap",
    surface: "evm/router",
    contract: "HyperionRouter",
    status: "gated",
    kind: "evm",
    abi: hyperionRouterAbi,
  },
  {
    file: "evm-cctp-adapter.cap",
    surface: "evm/cctp-adapter",
    contract: "CctpAdapter",
    status: "gated",
    kind: "evm",
    abi: cctpAdapterAbi,
  },
  {
    file: "evm-axelar-adapter.cap",
    surface: "evm/axelar-adapter",
    contract: "AxelarItsAdapter",
    status: "gated",
    kind: "evm",
    abi: axelarItsAdapterAbi,
  },
  {
    file: "evm-token-recovery-manager.cap",
    surface: "evm/token-recovery-manager",
    contract: "TokenRecoveryManager",
    status: "gated",
    kind: "evm",
    abi: tokenRecoveryManagerAbi,
  },
];

const HISTORY = read(join(capsDir, "paid-method-history.txt"));

function load(c: SurfaceCase): Snapshot {
  return validate(read(join(capsDir, c.file)), c, HISTORY);
}

function abiNames(abi: readonly { type: string; name?: string }[]): string[] {
  return [
    ...new Set(abi.filter((item) => item.type === "function").map((item) => item.name!)),
  ].sort();
}

describe("the contract interface capability snapshots", () => {
  it("has one file per declared surface and no orphans", () => {
    const files = readdirSync(capsDir)
      .filter((name) => name.endsWith(".cap"))
      .sort();
    expect(files).toEqual(SURFACES.map((c) => c.file).sort());
    expect(new Set(SURFACES.map((c) => c.surface)).size).toBe(SURFACES.length);
    // Router and adapter surfaces are recorded separately, never merged into one file.
    expect(SURFACES.filter((c) => c.file.endsWith("router.cap"))).toHaveLength(2);
    expect(SURFACES.filter((c) => c.surface.includes("adapter"))).toHaveLength(5);
  });

  for (const surface of SURFACES) {
    it(`validates ${surface.file} and matches its local implementation`, () => {
      const snapshot = load(surface);
      expect(snapshot.status).toBe(surface.status);
      if (surface.kind === "rust") {
        const source = read(surface.source!);
        expect(snapshot.methods).toEqual(rustContractMethods(source, surface.contract));
        expect(snapshot.routes.sort()).toEqual(rustAdvertisedRoutes(source).sort());
      } else {
        const names = abiNames(surface.abi!);
        // The EVM snapshot is the full compiled ABI: additions and removals both require review.
        expect(snapshot.methods).toEqual(names);
      }
    });
  }

  it("keeps the router's advertised paid routes equal to what the app can call", () => {
    const router = load(SURFACES.find((c) => c.file === "soroban-router.cap")!);
    const source = read(join(repoRoot, "soroban", "crates", "hyperion-router", "src", "lib.rs"));
    expect(rustPaidRouteAdvertisement(source).sort()).toEqual([...router.paidRoutes].sort());
    // Every advertised paid route has a paid entry point and vice versa.
    expect(router.paidMethods.length).toBeGreaterThan(0);
  });

  it("marks every development surface gated and the active deployment active", () => {
    for (const c of SURFACES) {
      const snapshot = load(c);
      if (c.surface.startsWith("evm/") || c.surface.endsWith("allbridge-adapter")) {
        expect(snapshot.status, `${c.surface} is development only`).toBe("gated");
      } else {
        expect(snapshot.status, `${c.surface} is the active testnet deployment`).toBe("active");
      }
    }
  });

  it("only marks a method as paid when the local entry point actually accepts payment", () => {
    const router = load(SURFACES.find((c) => c.file === "evm-router.cap")!);
    const cctp = load(SURFACES.find((c) => c.file === "evm-cctp-adapter.cap")!);
    const axelar = load(SURFACES.find((c) => c.file === "evm-axelar-adapter.cap")!);
    for (const [snapshot, abi] of [
      [router, hyperionRouterAbi],
      [cctp, cctpAdapterAbi],
      [axelar, axelarItsAdapterAbi],
    ] as const) {
      const payable = abiNames(
        abi.filter((item) => (item as { stateMutability?: string }).stateMutability === "payable"),
      );
      // Every method the snapshot calls paid must actually accept a provider payment. The
      // converse is not required: a manual gas top-up is payable without being a paid dispatch
      // entry point, and the snapshot does not advertise it as one.
      for (const method of snapshot.paidMethods) {
        expect(payable, `${snapshot.surface}: ${method} is marked paid but not payable`).toContain(
          method,
        );
      }
    }
  });
});

describe("the capability acknowledgement rules", () => {
  const base = {
    file: "fixture.cap",
    surface: "test/router",
    contract: "Test",
  };
  const history = "paid-method test/router paid_gone\n";
  const withRemoval = (line: string): string =>
    [
      "surface test/router",
      "contract Test",
      "status gated",
      "method plain",
      "route cctp",
      "paid-route cctp",
      line,
      "",
    ].join("\n");

  it("refuses a paid method that disappears without an acknowledgement", () => {
    const snapshot = [
      "surface test/router",
      "contract Test",
      "status gated",
      "method plain",
      "route cctp",
      "paid-route cctp",
      "",
    ].join("\n");
    expect(() => validate(snapshot, base, history)).toThrow(/no removed-paid-method/);
  });

  it("accepts an acknowledged removal with a reference and a reason", () => {
    const parsed = validate(
      withRemoval('removed-paid-method paid_gone acknowledged=issue-157 reason="superseded"'),
      base,
      history,
    );
    expect(parsed.removed.map((entry) => entry.value)).toEqual(["paid_gone"]);
  });

  it("refuses an acknowledgement that is still callable", () => {
    const snapshot = withRemoval(
      'removed-paid-method paid_gone acknowledged=issue-157 reason="still here"',
    ).replace("method plain", "method paid_gone\nmethod plain");
    expect(() => validate(snapshot, base, history)).toThrow(/still callable/);
  });

  it("refuses an acknowledgement without a compatibility reference", () => {
    expect(() =>
      validate(withRemoval("removed-paid-method paid_gone reason=gone"), base, history),
    ).toThrow(/needs acknowledged=/);
  });

  it("refuses a paid method that is absent from the history", () => {
    const snapshot = withRemoval("paid-method paid_gone").replace(
      "method plain",
      "method paid_gone\nmethod plain",
    );
    expect(() => validate(snapshot, base, "")).toThrow(/missing from paid-method-history/);
  });

  it("refuses a route slug that is not a protocol route", () => {
    const snapshot = withRemoval("").replace("route cctp", "route teleport");
    expect(() => validate(snapshot, base, history)).toThrow(/not a protocol slug/);
  });

  it("refuses duplicate or unsorted methods", () => {
    const duplicate = withRemoval("").replace("method plain", "method plain\nmethod plain");
    expect(() => validate(duplicate, base, history)).toThrow(/duplicate/);
    const unsorted = withRemoval("").replace("method plain", "method zed\nmethod alpha");
    expect(() => validate(unsorted, base, history)).toThrow(/sorted/);
  });
});
