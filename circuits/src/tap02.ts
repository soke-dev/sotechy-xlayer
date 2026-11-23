/**
 * TapeOut circuit netlists (TAP-02, spec/TAP-02.md) in TypeScript: decoding, encoding, the well-formedness
 * check, one beat of evaluation and bit packing. A line-by-line port of TapeOut's reference implementation
 * (spec/reference.py), checked against the official test vectors in spec/vectors.json.
 *
 * It's kept separate from the circuit builder: the tests decode the encoded bytes and evaluate those, so a
 * builder bug can't hide behind an evaluator that shares its data structures.
 */

export const NAND = 0x00;
export const LATCH = 0x01;
export const REF = 0x02;

const MAX_SIGNALS = 1 << 24;
const MAX_PINS = 1 << 16;
const MAX_GATES = 2 ** 32 - 1;

export class IllFormed extends Error {}

export interface Element {
  op: number;
  /** NAND: [a, b]; LATCH: [d]; REF: its input signals */
  ins: number[];
  /** REF only: the processor's address, lowercase 0x-hex */
  cpu?: string;
  /** REF only: the circuit id */
  cid?: bigint;
  /** how many signals this element produces */
  nOut: number;
  /** index of the first signal this element produces */
  firstOut: number;
}

export interface Circuit {
  nIn: number;
  nOut: number;
  elements: Element[];
  nSignals: number;
  /** REF targets, keyed `${cpu}:${cid}` */
  subs: Map<string, Circuit>;
  nState: number;
  nGates: number;
  /** each element's first state bit */
  stateBase: number[];
}

/** Resolves a REF target to its circuit, or null when it isn't a circuit of a registered processor */
export type Resolve = (cpu: string, cid: bigint) => Circuit | null;

export const fromHex = (hex: string): Uint8Array => {
  const h = hex.startsWith("0x") ? hex.slice(2) : hex;
  const out = new Uint8Array(h.length / 2);
  for (let i = 0; i < out.length; i++) out[i] = parseInt(h.slice(2 * i, 2 * i + 2), 16);
  return out;
};

export const toHex = (bytes: Uint8Array): string => "0x" + Array.from(bytes, (b) => b.toString(16).padStart(2, "0")).join("");

export function decode(data: Uint8Array, nIn: number): Element[] {
  let p = 0;
  let next = 2 + nIn;
  const els: Element[] = [];
  const take = (k: number) => {
    if (p + k > data.length) throw new IllFormed(`truncated record at byte ${p}`);
    const b = data.subarray(p, p + k);
    p += k;
    return b;
  };
  const u24 = () => {
    const b = take(3);
    return (b[0] << 16) | (b[1] << 8) | b[2];
  };
  while (p < data.length) {
    const op = take(1)[0];
    let e: Element;
    if (op === NAND) e = { op, ins: [u24(), u24()], nOut: 1, firstOut: 0 };
    else if (op === LATCH) e = { op, ins: [u24()], nOut: 1, firstOut: 0 };
    else if (op === REF) {
      const cpu = toHex(take(20));
      const cid = BigInt(toHex(take(8)));
      const ni = take(1)[0];
      const no = take(1)[0];
      const ins = Array.from({ length: ni }, u24);
      e = { op, ins, cpu, cid, nOut: no, firstOut: 0 };
    } else throw new IllFormed(`unknown opcode 0x${op.toString(16).padStart(2, "0")} at byte ${p - 1}`);
    e.firstOut = next;
    next += e.nOut;
    els.push(e);
  }
  return els;
}

export function encode(els: Element[]): Uint8Array {
  const out: number[] = [];
  const u24 = (s: number) => out.push((s >> 16) & 0xff, (s >> 8) & 0xff, s & 0xff);
  for (const e of els) {
    out.push(e.op);
    if (e.op === REF) {
      out.push(...fromHex(e.cpu!));
      out.push(...fromHex(e.cid!.toString(16).padStart(16, "0")));
      out.push(e.ins.length, e.nOut);
    }
    for (const s of e.ins) u24(s);
  }
  return Uint8Array.from(out);
}

/** Decodes and checks well-formedness (TAP-02 §3) */
export function load(data: Uint8Array, nIn: number, nOut: number, resolve?: Resolve): Circuit {
  const els = decode(data, nIn);
  const nSig = 2 + nIn + els.reduce((n, e) => n + e.nOut, 0);
  if (nSig > MAX_SIGNALS) throw new IllFormed("more than 2^24 signals");
  if (!(nIn >= 0 && nIn <= MAX_PINS && nOut >= 1 && nOut <= MAX_PINS)) throw new IllFormed("nIn/nOut out of range");
  if (nSig - 2 - nIn < nOut) throw new IllFormed("too few signals for outputs");
  const c: Circuit = { nIn, nOut, elements: els, nSignals: nSig, subs: new Map(), nState: 0, nGates: 0, stateBase: [] };
  for (const e of els) {
    for (const s of e.ins) {
      const limit = e.op === LATCH ? nSig : e.firstOut;
      if (s >= limit) throw new IllFormed(`signal ${s} referenced by element at ${e.firstOut} is not available`);
    }
    c.stateBase.push(c.nState);
    if (e.op === LATCH) c.nState += 1;
    else if (e.op === REF) {
      if (!resolve) throw new IllFormed("REF without a resolver");
      const sub = resolve(e.cpu!, e.cid!);
      if (!sub) throw new IllFormed("REF target is not a circuit of a registered processor");
      if (sub.nIn !== e.ins.length || sub.nOut !== e.nOut) throw new IllFormed("REF arity does not match the target circuit");
      if (sub.nState > MAX_SIGNALS) throw new IllFormed("REF size");
      c.subs.set(`${e.cpu}:${e.cid}`, sub);
      c.nState += sub.nState;
      c.nGates += sub.nGates;
    }
  }
  c.nGates += els.filter((e) => e.op !== REF).length;
  if (c.nState > MAX_SIGNALS || c.nGates > MAX_GATES) throw new IllFormed("size overflow");
  return c;
}

/** One beat (TAP-02 §4): (state, inputs) → (newState, outputs), as bit arrays */
export function beat(c: Circuit, state: number[], inputs: number[]): { newState: number[]; outputs: number[] } {
  if (state.length !== c.nState || inputs.length !== c.nIn) throw new Error("state or inputs have the wrong length");
  const a = [0, 1, ...inputs];
  const newState = [...state];
  c.elements.forEach((e, i) => {
    const base = c.stateBase[i];
    if (e.op === NAND) a.push(1 - (a[e.ins[0]] & a[e.ins[1]]));
    else if (e.op === LATCH) a.push(state[base]);
    else {
      const sub = c.subs.get(`${e.cpu}:${e.cid}`)!;
      const r = beat(sub, state.slice(base, base + sub.nState), e.ins.map((s) => a[s]));
      newState.splice(base, sub.nState, ...r.newState);
      a.push(...r.outputs);
    }
  });
  c.elements.forEach((e, i) => {
    if (e.op === LATCH) newState[c.stateBase[i]] = a[e.ins[0]];
  });
  return { newState, outputs: a.slice(a.length - c.nOut) };
}

/** Bit i is bit (i mod 8) of byte floor(i / 8): least significant bit first (TAP-02 §5) */
export function pack(bits: number[]): Uint8Array {
  const out = new Uint8Array((bits.length + 7) >> 3);
  bits.forEach((v, i) => {
    if (v) out[i >> 3] |= 1 << (i & 7);
  });
  return out;
}

/** As the contracts read inputs and state: missing bytes read as 0; extra bytes and bits are ignored */
export const unpack = (data: Uint8Array, n: number): number[] =>
  Array.from({ length: n }, (_, i) => ((i >> 3) < data.length ? (data[i >> 3] >> (i & 7)) & 1 : 0));
