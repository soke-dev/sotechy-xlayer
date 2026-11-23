// The builder's netlists, decoded and run by the TAP-02 evaluator, against plain logic on every input
import { test } from "node:test";
import assert from "node:assert/strict";
import { Builder, ONE, ZERO, type Built } from "../src/builder.ts";
import { beat, load } from "../src/tap02.ts";

/** Every input combination of a combinational circuit → its outputs */
function truth(built: Built) {
  const c = load(built.netlist, built.nIn, built.nOut);
  assert.equal(c.nState, 0);
  const rows: { ins: number[]; outs: number[] }[] = [];
  for (let n = 0; n < 1 << built.nIn; n++) {
    const ins = Array.from({ length: built.nIn }, (_, i) => (n >> i) & 1);
    rows.push({ ins, outs: beat(c, [], ins).outputs });
  }
  return rows;
}

test("AND, OR, NOT and NAND", () => {
  const b = new Builder(2);
  const [x, y] = [b.input(0), b.input(1)];
  const built = b.build([b.and(x, y), b.or(x, y), b.not(x), b.nand(x, y)]);
  for (const { ins: [a, c], outs } of truth(built)) assert.deepEqual(outs, [a & c, a | c, 1 - a, 1 - (a & c)]);
});

test("andAll and orAll over many inputs", () => {
  const b = new Builder(5);
  const xs = [0, 1, 2, 3, 4].map((i) => b.input(i));
  const built = b.build([b.andAll(xs), b.orAll(xs)]);
  for (const { ins, outs } of truth(built)) assert.deepEqual(outs, [ins.every(Boolean) ? 1 : 0, ins.some(Boolean) ? 1 : 0]);
});

test("constants fold away", () => {
  const b = new Builder(1);
  const x = b.input(0);
  assert.equal(b.and(x, ONE), x);
  assert.equal(b.and(x, ZERO), ZERO);
  assert.equal(b.or(x, ZERO), x);
  assert.equal(b.or(x, ONE), ONE);
  assert.equal(b.not(b.not(x)), x);
  assert.equal(b.nand(x, b.not(x)), ONE);
});

test("equal gates are built once, and unused gates are dropped", () => {
  const b = new Builder(2);
  const [x, y] = [b.input(0), b.input(1)];
  assert.equal(b.nand(x, y), b.nand(y, x));
  b.or(x, y); // never used as an output
  const built = b.build([b.and(x, y)]);
  assert.equal(built.nand, 2);
});

test("an input as an output, outputs out of order", () => {
  const b = new Builder(2);
  const [x, y] = [b.input(0), b.input(1)];
  const both = b.and(x, y);
  const built = b.build([x, both, b.not(y)]);
  for (const { ins: [a, c], outs } of truth(built)) assert.deepEqual(outs, [a, a & c, 1 - c]);
});

test("a LATCH remembers until cleared", () => {
  // q' = set OR (q AND NOT clear); output q'
  const b = new Builder(2);
  const [set, clear] = [b.input(0), b.input(1)];
  const q = b.latch();
  const next = b.or(set, b.and(q, b.not(clear)));
  b.store(q, next);
  const built = b.build([next]);
  const c = load(built.netlist, built.nIn, built.nOut);
  assert.equal(c.nState, 1);
  let state = [0];
  const run = (s: number, cl: number) => {
    const r = beat(c, state, [s, cl]);
    state = r.newState;
    return r.outputs[0];
  };
  assert.equal(run(0, 0), 0);
  assert.equal(run(1, 0), 1); // set
  assert.equal(run(0, 0), 1); // remembered
  assert.equal(run(0, 1), 0); // cleared
  assert.equal(run(1, 1), 1); // set wins over clear
});

test("a LATCH without an input is refused", () => {
  const b = new Builder(1);
  const q = b.latch();
  assert.throws(() => b.build([q]), /LATCH has no input/);
});
