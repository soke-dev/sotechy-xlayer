// Our TAP-02 port against TapeOut's official test vectors (spec/vectors.json)
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { beat, decode, encode, fromHex, IllFormed, load, pack, toHex, unpack, type Circuit } from "../src/tap02.ts";

interface Ref { cpu: string; id: number; nIn: number; nOut: number; netlist: string }
const vectors = JSON.parse(readFileSync(new URL("../../spec/vectors.json", import.meta.url), "utf8"));

/** Resolves REF targets from a vector's `refs` list, the way a registered processor would */
const resolver = (refs: Ref[]) => (cpu: string, cid: bigint): Circuit | null => {
  const r = refs.find((x) => x.cpu.toLowerCase() === cpu && BigInt(x.id) === cid);
  return r ? load(fromHex(r.netlist), r.nIn, r.nOut) : null;
};

test("vector format is the one this port implements", () => {
  assert.equal(vectors.format, "tap-netlist-vectors/1");
});

for (const v of vectors.valid) {
  test(`valid: ${v.name}`, () => {
    const c = load(fromHex(v.netlist), v.nIn, v.nOut, resolver(v.refs));
    assert.equal(c.nState, v.nState);
    // Decoding then encoding gives back the same bytes
    assert.equal(toHex(encode(decode(fromHex(v.netlist), v.nIn))), v.netlist.toLowerCase());
    for (const row of v.truthTable ?? []) {
      const out = beat(c, [], unpack(fromHex(row.inputs), v.nIn)).outputs;
      assert.equal(toHex(pack(out)).slice(2), row.outputs, `inputs ${row.inputs}`);
    }
    for (const b of v.beats ?? []) {
      const r = beat(c, unpack(fromHex(b.state), c.nState), unpack(fromHex(b.inputs), v.nIn));
      assert.equal(toHex(pack(r.newState)).slice(2), b.newState, `state ${b.state} inputs ${b.inputs}: new state`);
      assert.equal(toHex(pack(r.outputs)).slice(2), b.outputs, `state ${b.state} inputs ${b.inputs}: outputs`);
    }
  });
}

for (const v of vectors.illFormed) {
  test(`ill-formed is rejected: ${v.name}`, () => {
    assert.throws(() => load(fromHex(v.netlist), v.nIn, v.nOut, resolver(v.refs ?? [])), (e: unknown) => {
      assert.ok(e instanceof IllFormed, `expected IllFormed, got ${e}`);
      assert.equal((e as Error).message, v.reason);
      return true;
    });
  });
}

test("packing edge cases read inputs the way the contracts do", () => {
  const nand = vectors.valid.find((x: { name: string }) => x.name === vectors.packingEdgeCases.circuit);
  const c = load(fromHex(nand.netlist), nand.nIn, nand.nOut);
  for (const k of vectors.packingEdgeCases.cases) {
    const out = beat(c, [], unpack(fromHex(k.inputs), c.nIn)).outputs;
    assert.equal(toHex(pack(out)).slice(2), k.outputs, k.case);
  }
});
