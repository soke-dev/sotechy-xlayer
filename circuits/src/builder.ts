/**
 * Builds TapeOut netlists from logic. Every gate is a NAND (plus LATCH for memory), so the helpers below
 * spell AND, OR and NOT in NANDs, fold constants, reuse identical gates, and drop gates no output needs.
 *
 * Signals are numbered as in TAP-02 §2: 0 and 1 are the constants, then the inputs, then one signal per
 * element. The outputs of a circuit are its last nOut signals, so build() makes sure they come last.
 */
import { encode, LATCH, NAND, type Element } from "./tap02.ts";

export type Sig = number;

export const ZERO: Sig = 0;
export const ONE: Sig = 1;

interface Gate {
  op: typeof NAND | typeof LATCH;
  ins: Sig[];
}

export interface Built {
  nIn: number;
  nOut: number;
  netlist: Uint8Array;
  nand: number;
  latch: number;
}

export class Builder {
  readonly nIn: number;
  /** gates in creation order; gate k produces signal 2 + nIn + k */
  private gates: Gate[] = [];
  /** NAND(a, b) already built, so equal gates are shared */
  private seen = new Map<string, Sig>();
  /** x → NOT x, both ways, so NOT NOT x is x */
  private negation = new Map<Sig, Sig>();
  /** LATCHes whose input isn't wired yet */
  private openLatches = new Set<Sig>();

  constructor(nIn: number) {
    this.nIn = nIn;
  }

  input(i: number): Sig {
    if (i < 0 || i >= this.nIn) throw new Error(`no input ${i}`);
    return 2 + i;
  }

  private add(g: Gate): Sig {
    this.gates.push(g);
    return 2 + this.nIn + this.gates.length - 1;
  }

  nand(a: Sig, b: Sig): Sig {
    if (a === ZERO || b === ZERO) return ONE;
    if (a === ONE) return this.not(b);
    if (b === ONE) return this.not(a);
    if (a === b) return this.not(a);
    if (this.negation.get(a) === b) return ONE; // NAND(x, NOT x) = 1
    return this.rawNand(a, b);
  }

  private rawNand(a: Sig, b: Sig): Sig {
    const key = a < b ? `${a},${b}` : `${b},${a}`;
    const hit = this.seen.get(key);
    if (hit !== undefined) return hit;
    const s = this.add({ op: NAND, ins: a < b ? [a, b] : [b, a] });
    this.seen.set(key, s);
    return s;
  }

  not(a: Sig): Sig {
    if (a === ZERO) return ONE;
    if (a === ONE) return ZERO;
    const known = this.negation.get(a);
    if (known !== undefined) return known;
    const s = this.rawNand(a, a);
    this.negation.set(a, s);
    this.negation.set(s, a);
    return s;
  }

  and(a: Sig, b: Sig): Sig {
    return this.not(this.nand(a, b));
  }

  or(a: Sig, b: Sig): Sig {
    return this.nand(this.not(a), this.not(b));
  }

  andAll(xs: Sig[]): Sig {
    return xs.reduce((acc, x) => this.and(acc, x), ONE);
  }

  orAll(xs: Sig[]): Sig {
    return xs.reduce((acc, x) => this.or(acc, x), ZERO);
  }

  /** A memory bit. Its output is the value stored at the previous beat; wire what it stores with `store`. */
  latch(): Sig {
    const s = this.add({ op: LATCH, ins: [-1] });
    this.openLatches.add(s);
    return s;
  }

  store(latch: Sig, d: Sig) {
    if (!this.openLatches.delete(latch)) throw new Error(`signal ${latch} isn't an unwired LATCH`);
    this.gates[latch - 2 - this.nIn].ins = [d];
  }

  /** The netlist with these outputs, in order, as its last signals; unused gates are left out */
  build(outputs: Sig[]): Built {
    if (this.openLatches.size) throw new Error("a LATCH has no input");
    if (outputs.length === 0) throw new Error("a circuit needs at least one output");
    const first = 2 + this.nIn;
    const gateOf = (s: Sig) => (s >= first ? this.gates[s - first] : undefined);

    // Keep only the gates the outputs depend on (through LATCH inputs too)
    const keep = new Set<Sig>();
    const visit = (s: Sig) => {
      if (s < first || keep.has(s)) return;
      keep.add(s);
      gateOf(s)!.ins.forEach(visit);
    };
    outputs.forEach(visit);
    const order = [...keep].sort((a, b) => a - b);

    // Renumber the kept gates: they follow the inputs, in their original order
    const map = new Map<Sig, Sig>([[ZERO, ZERO], [ONE, ONE]]);
    for (let i = 0; i < this.nIn; i++) map.set(2 + i, 2 + i);
    order.forEach((s, i) => map.set(s, first + i));
    const rec = (op: number, ins: Sig[]): Element => ({ op, ins, nOut: 1, firstOut: 0 });
    const records: Element[] = order.map((s) => rec(gateOf(s)!.op, gateOf(s)!.ins.map((x) => map.get(x)!)));

    // The outputs must be the last signals, in order. Unless they already are, add them at the end: a NAND
    // output is made once more by the same NAND (one gate); a LATCH, an input or a constant goes through
    // NOT twice (two gates).
    const inPlace = order.length >= outputs.length && order.slice(-outputs.length).every((s, i) => s === outputs[i]);
    if (!inPlace) {
      for (const o of outputs) {
        const g = gateOf(o);
        if (g && g.op === NAND) records.push(rec(NAND, g.ins.map((x) => map.get(x)!)));
        else {
          const m = map.get(o)!;
          records.push(rec(NAND, [m, m]));
          const notO = first + records.length - 1;
          records.push(rec(NAND, [notO, notO]));
        }
      }
    }
    const nand = records.filter((r) => r.op === NAND).length;
    const latch = records.filter((r) => r.op === LATCH).length;
    return { nIn: this.nIn, nOut: outputs.length, netlist: encode(records), nand, latch };
  }
}
