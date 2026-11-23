// Each circuit's gates, decoded and run by the TAP-02 evaluator, against its rule on every possible input
import { test } from "node:test";
import assert from "node:assert/strict";
import {
  NEW_STORE_LIMIT,
  newStoreLimit,
  newStoreLimitRule,
  ORDER_VERDICT,
  orderVerdict,
  orderVerdictRule,
  STORE_BREAKER,
  storeBreaker,
  storeBreakerRule,
} from "../src/circuits.ts";
import { beat, load } from "../src/tap02.ts";

const bits = (n: number, width: number) => Array.from({ length: width }, (_, i) => (n >> i) & 1);

test("Order Verdict matches its rule on all 512 inputs", () => {
  const built = orderVerdict();
  const c = load(built.netlist, built.nIn, built.nOut);
  assert.equal(c.nIn, 9);
  assert.equal(c.nState, 0);
  for (let n = 0; n < 512; n++) {
    const ins = bits(n, 9);
    const facts = Object.fromEntries(ORDER_VERDICT.inputs.map((k, i) => [k, ins[i] === 1])) as Parameters<typeof orderVerdictRule>[0];
    const want = orderVerdictRule(facts);
    const [release, refund] = beat(c, [], ins).outputs;
    assert.equal(release, want.release ? 1 : 0, `release for ${JSON.stringify(facts)}`);
    assert.equal(refund, want.refund ? 1 : 0, `refund for ${JSON.stringify(facts)}`);
  }
});

test("Order Verdict never releases and refunds at once, and never moves unpaid money", () => {
  const built = orderVerdict();
  const c = load(built.netlist, built.nIn, built.nOut);
  for (let n = 0; n < 512; n++) {
    const ins = bits(n, 9);
    const [release, refund] = beat(c, [], ins).outputs;
    assert.ok(!(release && refund), `both for input ${n}`);
    if (!ins[0]) assert.deepEqual([release, refund], [0, 0], `unpaid input ${n}`);
    if (ins[6]) assert.deepEqual([release, refund], [0, 0], `open dispute, input ${n}`);
  }
});

test("Order Verdict, the everyday cases", () => {
  const built = orderVerdict();
  const c = load(built.netlist, built.nIn, built.nOut);
  const run = (on: string[]) => beat(c, [], ORDER_VERDICT.inputs.map((k) => (on.includes(k) ? 1 : 0))).outputs;
  assert.deepEqual(run(["paid", "storeVerified"]), [0, 0], "paid, waiting for the store");
  assert.deepEqual(run(["paid", "storeVerified", "shipped", "delivered"]), [1, 0], "delivered: release");
  assert.deepEqual(run(["paid", "storeVerified", "shipped", "confirmWindowOver"]), [1, 0], "no complaint in time: release");
  assert.deepEqual(run(["paid", "storeVerified", "shipDeadlinePassed"]), [0, 1], "never shipped: refund");
  assert.deepEqual(run(["paid", "storeVerified", "storeCancelled"]), [0, 1], "cancelled: refund");
  assert.deepEqual(run(["paid", "storeVerified", "shipped", "disputeOpen"]), [0, 0], "dispute: hold");
  assert.deepEqual(run(["paid", "storeVerified", "shipped", "buyerWonDispute"]), [0, 1], "buyer won: refund");
  assert.deepEqual(run(["paid", "shipped", "delivered"]), [0, 0], "store not verified: hold");
});

test("New-Store Limit matches its rule on all 131,072 inputs", () => {
  const built = newStoreLimit();
  const c = load(built.netlist, built.nIn, built.nOut);
  assert.equal(c.nIn, NEW_STORE_LIMIT.inputs.length);
  for (let established = 0; established < 2; established++) {
    for (let amount = 0; amount < 256; amount++) {
      for (let limit = 0; limit < 256; limit++) {
        const [ok] = beat(c, [], [...bits(amount, 8), ...bits(limit, 8), established]).outputs;
        assert.equal(ok, newStoreLimitRule(amount, limit, established === 1) ? 1 : 0, `amount ${amount} limit ${limit} established ${established}`);
      }
    }
  }
});

test("Store Breaker matches its rule in every state, for every input", () => {
  const built = storeBreaker();
  const c = load(built.netlist, built.nIn, built.nOut);
  assert.equal(c.nState, STORE_BREAKER.state.length);
  for (let tripped = 0; tripped < 2; tripped++) {
    for (let n = 0; n < 4; n++) {
      const [opened, cleared] = bits(n, 2);
      const r = beat(c, [tripped], [opened, cleared]);
      const want = storeBreakerRule(tripped === 1, opened === 1, cleared === 1);
      assert.deepEqual(r.newState, [want.tripped ? 1 : 0], `tripped ${tripped} opened ${opened} cleared ${cleared}`);
      assert.deepEqual(r.outputs, [want.ok ? 1 : 0]);
    }
  }
});

test("Store Breaker over a store's life", () => {
  const built = storeBreaker();
  const c = load(built.netlist, built.nIn, built.nOut);
  let state = [0];
  const beatWith = (opened: number, cleared: number) => {
    const r = beat(c, state, [opened, cleared]);
    state = r.newState;
    return r.outputs[0];
  };
  assert.equal(beatWith(0, 0), 1, "a fresh store is fine");
  assert.equal(beatWith(1, 0), 0, "a dispute trips it");
  assert.equal(beatWith(0, 0), 0, "it stays tripped");
  assert.equal(beatWith(0, 1), 1, "Sotechy clears it");
  assert.equal(beatWith(1, 1), 0, "a new dispute wins over a clear");
});

test("the circuits stay small", () => {
  assert.ok(orderVerdict().nand <= 40, `Order Verdict: ${orderVerdict().nand} NAND`);
  assert.ok(newStoreLimit().nand <= 45, `New-Store Limit: ${newStoreLimit().nand} NAND`);
  const breaker = storeBreaker();
  assert.equal(breaker.latch, 1);
  assert.ok(breaker.nand <= 8, `Store Breaker: ${breaker.nand} NAND`);
});
