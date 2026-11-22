import { describe, expect, it } from "vitest";
import { readFileSync } from "node:fs";
import { runInNewContext } from "node:vm";
import ts from "typescript";
import { applyFee, convertDecimals, floorToRepresentable } from "../src/amounts.js";
import { planForwardQuote, planInverseQuote } from "../src/quotes.js";
import type { RouterSnapshot } from "../src/quotes.js";
import { RouteKind } from "../src/routes.js";
import { G_ADDR } from "./fixtures.js";

type Rational = Readonly<{ numerator: bigint; denominator: bigint }>;
interface Arithmetic {
  applyFee: typeof applyFee;
  convertDecimals: typeof convertDecimals;
  floorToRepresentable: typeof floorToRepresentable;
}
// Independent specification: fee = floor(source amount * bps / 10,000).
// Conversion floors a rational destination value; dust and representable floors use SOURCE units.
const FEE_DENOMINATOR = 10_000n;
const WORD_MAXIMUM = (1n << 256n) - 1n;
function gcd(left: bigint, right: bigint): bigint {
  let a = left;
  let b = right;
  while (b !== 0n) [a, b] = [b, a % b];
  return a === 0n ? 1n : a;
}
function rational(numerator: bigint, denominator = 1n): Rational {
  if (numerator < 0n || denominator <= 0n)
    throw new Error("Oracle requires unsigned rational values");
  const divisor = gcd(numerator, denominator);
  return { numerator: numerator / divisor, denominator: denominator / divisor };
}
function floor(value: Rational): bigint {
  return value.numerator / value.denominator;
}
function ceil(value: Rational): bigint {
  return (value.numerator + value.denominator - 1n) / value.denominator;
}
function scaled(amount: bigint, from: number, to: number): Rational {
  return rational(amount * 10n ** BigInt(to), 10n ** BigInt(from));
}
function oracleConvert(amount: bigint, from: number, to: number) {
  const converted = floor(scaled(amount, from, to));
  const representedSource = from >= to ? converted * 10n ** BigInt(from - to) : amount;
  return { converted, dust: amount - representedSource, overflow: converted > WORD_MAXIMUM };
}
function oracleFloor(amount: bigint, from: number, to: number): bigint {
  return amount - oracleConvert(amount, from, to).dust;
}
function oracleFee(amount: bigint, feeBps: number) {
  const fee = floor(rational(amount * BigInt(feeBps), FEE_DENOMINATOR));
  return { net: amount - fee, fee };
}
function corpus(): (readonly [bigint, number, number])[] {
  let state = 0x155da11n;
  const cases: (readonly [bigint, number, number])[] = [
    [1n, 7, 6],
    [9n, 7, 6],
    [10n, 7, 6],
    [11n, 7, 6],
    [10_000_001n, 7, 6],
    [WORD_MAXIMUM, 38, 0],
    [WORD_MAXIMUM, 0, 1],
    [WORD_MAXIMUM / 10n, 0, 1],
    [WORD_MAXIMUM / 10n + 1n, 0, 1],
    [0n, 0, 38],
    [WORD_MAXIMUM, 38, 38],
  ];
  for (let index = 0; index < 96; index++) {
    state = (state * 1_103_515_245n + 12_345n) & 0x7fffffffn;
    cases.push([
      (state << BigInt(index % 17)) + BigInt(index + 1),
      Number(state % 39n),
      Number((state / 39n) % 39n),
    ]);
  }
  return cases;
}
function verifyArithmetic(implementation: Arithmetic): void {
  for (const [amount, from, to] of corpus()) {
    for (const feeBps of [0, 1, 30, 100]) {
      if (amount > 0n)
        expect(implementation.applyFee(amount, feeBps)).toEqual(oracleFee(amount, feeBps));
    }
    const expected = oracleConvert(amount, from, to);
    if (expected.overflow) expect(() => implementation.convertDecimals(amount, from, to)).toThrow();
    else
      expect(implementation.convertDecimals(amount, from, to)).toEqual({
        converted: expected.converted,
        dust: expected.dust,
      });
    expect(implementation.floorToRepresentable(amount, from, to)).toBe(
      oracleFloor(amount, from, to),
    );
  }
  // A sub-unit fee is zero; these values straddle exact fee-floor boundaries.
  for (const amount of [99n, 100n, 101n, 9999n, 10_000n, 10_001n]) {
    for (const feeBps of [1, 100])
      expect(implementation.applyFee(amount, feeBps)).toEqual(oracleFee(amount, feeBps));
  }
}
function evaluateProduction(source: string): Arithmetic {
  // Evaluate the actual amounts module with only its error sink substituted. No files change.
  const context = {
    exports: {},
    require: (name: string) => {
      if (name !== "./errors.js") throw new Error("Unexpected arithmetic dependency");
      return {
        fail: (code: string): never => {
          throw new Error(code);
        },
      };
    },
  };
  const output = ts.transpileModule(source, {
    compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2022 },
  });
  runInNewContext(output.outputText, context, { timeout: 1000 });
  return context.exports as Arithmetic;
}
function snapshot(from: number, feeBps: number, headroom: bigint): RouterSnapshot {
  const all = <T>(value: T): Record<RouteKind, T> => ({
    [RouteKind.Cctp]: value,
    [RouteKind.AxelarIts]: value,
    [RouteKind.AxelarGmp]: value,
    [RouteKind.Allbridge]: value,
  });
  return {
    paused: false,
    feeBps,
    routeEnabled: all(true),
    adapterSet: all(true),
    tokenRegistered: true,
    tokenEnabled: true,
    tokenDecimals: from,
    flowAvailable: all(headroom),
    chainSupported: all(true),
  };
}
function oracleDestination(amount: bigint, from: number, to: number, bps: number): bigint {
  return oracleConvert(oracleFee(amount, bps).net, from, to).converted;
}
function oracleInverse(
  minimum: bigint,
  reserve: bigint,
  from: number,
  to: number,
  bps: number,
): bigint {
  // Required source net = ceil((minimum + reserve) * 10^from / 10^to).
  const requiredNet = ceil(scaled(minimum + reserve, to, from));
  // x - floor(x*b/10,000) >= n iff x*(10,000-b) > (n-1)*10,000.
  return floor(rational((requiredNet - 1n) * FEE_DENOMINATOR, FEE_DENOMINATOR - BigInt(bps))) + 1n;
}

describe("SDK arithmetic against an independent rational specification", () => {
  it("checks fee floors, source dust, destination units and uint256 widening boundaries", () => {
    verifyArithmetic({ applyFee, convertDecimals, floorToRepresentable });
  });
  it.each([
    [
      "fee denominator",
      "export const BPS_DENOMINATOR = 10_000n;",
      "export const BPS_DENOMINATOR = 9_999n;",
    ],
    [
      "fee rounded up",
      "(amount * BigInt(feeBps)) / BPS_DENOMINATOR",
      "(amount * BigInt(feeBps) + BPS_DENOMINATOR - 1n) / BPS_DENOMINATOR",
    ],
    [
      "destination rounded up",
      "converted: amount / divisor",
      "converted: (amount + divisor - 1n) / divisor",
    ],
    ["dust in wrong units", "dust: amount % divisor", "dust: (amount % divisor) * divisor"],
    [
      "floor returned in destination units",
      "return amount - (amount % divisor);",
      "return amount / divisor;",
    ],
    [
      "missing widening overflow refusal",
      "amount !== 0n && factor > MAX_UINT256 / amount",
      "false",
    ],
  ])("detects a real production mutation: %s", (_label, original, replacement) => {
    const source = readFileSync(new URL("../src/amounts.ts", import.meta.url), "utf8");
    expect(source.split(original)).toHaveLength(2);
    verifyArithmetic(evaluateProduction(source));
    expect(() => {
      verifyArithmetic(evaluateProduction(source.replace(original, replacement)));
    }).toThrow();
  });
  it("independently solves inverse plans including forwarding reserve and proves minimality", () => {
    for (const [from, to] of [
      [7, 6],
      [6, 7],
      [0, 0],
      [3, 0],
      [0, 3],
      [38, 37],
      [37, 38],
    ] as const) {
      for (const feeBps of [0, 1, 30, 100]) {
        for (const minimum of [1n, 9n, 10n, 99n, 100n, 101n, 9999n, (1n << 100n) + 1n]) {
          for (const reserve of [0n, 7n]) {
            const expectedSource = oracleInverse(minimum, reserve, from, to, feeBps);
            const state = snapshot(from, feeBps, WORD_MAXIMUM);
            const request = {
              route: RouteKind.Cctp,
              strkey: G_ADDR,
              destinationDecimals: to,
              minimumDestinationAmount: minimum,
              forwardingBudget: {
                destinationAmount: reserve,
                unit: "destination-token-base-units" as const,
              },
            };
            const inverse = planInverseQuote(request, state);
            expect(inverse.available).toBe(true);
            expect(inverse.requiredSourceAmount).toBe(expectedSource);
            const received = oracleDestination(expectedSource, from, to, feeBps) - reserve;
            expect(inverse.recipientDestinationAmount).toBe(received);
            expect(inverse.requiredDestinationAmount).toBe(minimum + reserve);
            expect(inverse.roundingOvershoot).toBe(received - minimum);
            expect(
              oracleDestination(expectedSource - 1n, from, to, feeBps) < minimum + reserve,
            ).toBe(true);
            expect(
              planForwardQuote({ ...request, amount: expectedSource }, state)
                .recipientDestinationAmount,
            ).toBe(received);
            expect(
              planForwardQuote({ ...request, amount: expectedSource }, state).meetsMinimum,
            ).toBe(true);
            expect(
              planForwardQuote({ ...request, amount: expectedSource - 1n }, state).meetsMinimum,
            ).toBe(false);
          }
        }
      }
    }
  });
  it("exhaustively compares source-unit flow ceilings with a brute-force forward oracle", () => {
    for (const [from, to] of [
      [1, 0],
      [0, 1],
      [0, 0],
    ] as const) {
      for (const feeBps of [0, 100]) {
        for (const headroom of [0n, 1n, 9n, 10n, 11n, 100n]) {
          for (const minimum of [1n, 9n, 10n, 11n, 99n, 100n, 101n]) {
            let expected: bigint | null = null;
            for (let source = 1n; source <= 200n; source++) {
              const net = oracleFloor(oracleFee(source, feeBps).net, from, to);
              if (net <= headroom && oracleDestination(source, from, to, feeBps) >= minimum + 1n) {
                expected = source;
                break;
              }
            }
            const inverse = planInverseQuote(
              {
                route: RouteKind.Cctp,
                strkey: G_ADDR,
                destinationDecimals: to,
                minimumDestinationAmount: minimum,
                forwardingBudget: { destinationAmount: 1n, unit: "destination-token-base-units" },
              },
              snapshot(from, feeBps, headroom),
            );
            expect(inverse.requiredSourceAmount).toBe(expected);
            expect(inverse.available).toBe(expected !== null);
          }
        }
      }
    }
  });
});
