// netlists.json, which the contracts and deploy scripts read, must match what the builders make today
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { CIRCUITS } from "../src/circuits.ts";
import { toHex } from "../src/tap02.ts";

const file = JSON.parse(readFileSync(new URL("../netlists.json", import.meta.url), "utf8"));

test("netlists.json is up to date (run: npm run build)", () => {
  assert.equal(file.circuits.length, CIRCUITS.length);
  for (const c of CIRCUITS) {
    const saved = file.circuits.find((x: { key: string }) => x.key === c.key);
    assert.ok(saved, `${c.key} is missing`);
    const b = c.build();
    assert.equal(saved.netlist, toHex(b.netlist), `${c.key} netlist`);
    assert.deepEqual([saved.nIn, saved.nOut, saved.nand, saved.latch], [b.nIn, b.nOut, b.nand, b.latch], `${c.key} shape`);
    assert.deepEqual(saved.inputs, [...c.inputs], `${c.key} pinout`);
  }
});
