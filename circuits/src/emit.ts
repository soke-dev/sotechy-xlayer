// Writes the circuits to circuits/netlists.json: the exact bytes to tape out, with pinouts and gate counts.
// The contracts' tests and the deploy scripts read this file. Run: node src/emit.ts
import { writeFileSync } from "node:fs";
import { CIRCUITS } from "./circuits.ts";
import { toHex } from "./tap02.ts";

const out = CIRCUITS.map((c) => {
  const b = c.build();
  return {
    key: c.key,
    title: c.title,
    nIn: b.nIn,
    nOut: b.nOut,
    nState: "state" in c ? c.state.length : 0,
    nand: b.nand,
    latch: b.latch,
    inputs: c.inputs,
    outputs: c.outputs,
    netlist: toHex(b.netlist),
  };
});

writeFileSync(new URL("../netlists.json", import.meta.url), JSON.stringify({ format: "tap-netlist/1", circuits: out }, null, 2) + "\n");
for (const c of out) console.log(`${c.title}: ${c.nIn} in, ${c.nOut} out, ${c.nand} NAND, ${c.latch} LATCH, ${(c.netlist.length - 2) / 2} bytes`);
