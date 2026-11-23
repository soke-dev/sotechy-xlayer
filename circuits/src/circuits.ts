/**
 * Sotechy's three circuits. Each has its pinout (which input bit means what), a builder that turns the rule
 * into gates, and the same rule in plain code, which the tests check the gates against on every input.
 *
 * Inputs and outputs are bit vectors packed least significant bit first (TAP-02 §5); the escrow contract
 * packs them in the same order as the pin lists below.
 */
import { Builder, type Built, type Sig } from "./builder.ts";

/** Order Verdict: from an order's facts, release the money to the store, refund the buyer, or neither */
export const ORDER_VERDICT = {
  key: "order-verdict",
  title: "Order Verdict",
  inputs: [
    "paid", // the buyer's USDT is in the escrow
    "storeVerified", // the store passed Sotechy's checks and isn't suspended
    "shipped", // the store marked the order sent
    "delivered", // the buyer confirmed they got it
    "confirmWindowOver", // shipped, and the confirm window passed with no complaint
    "shipDeadlinePassed", // the ship-by date passed
    "disputeOpen", // the buyer reported a problem that isn't resolved yet
    "buyerWonDispute", // a dispute was resolved in the buyer's favour
    "storeCancelled", // the store cancelled the order
  ],
  outputs: ["release", "refund"],
} as const;

export function orderVerdictRule(x: Record<(typeof ORDER_VERDICT.inputs)[number], boolean>) {
  const release =
    x.paid && x.storeVerified && !x.disputeOpen && !x.buyerWonDispute && !x.storeCancelled && (x.delivered || (x.shipped && x.confirmWindowOver));
  const refund = x.paid && !x.disputeOpen && (x.storeCancelled || x.buyerWonDispute || (!x.shipped && !x.delivered && x.shipDeadlinePassed));
  return { release, refund };
}

export function orderVerdict(): Built {
  const b = new Builder(ORDER_VERDICT.inputs.length);
  const [paid, verified, shipped, delivered, windowOver, deadlinePassed, dispute, buyerWon, cancelled] = ORDER_VERDICT.inputs.map((_, i) => b.input(i));
  const settled = b.and(paid, b.not(dispute)); // paid, and nothing is in dispute
  const goodToRelease = b.andAll([verified, b.not(buyerWon), b.not(cancelled)]);
  const arrived = b.or(delivered, b.and(shipped, windowOver));
  const release = b.and(settled, b.and(goodToRelease, arrived));
  const notSent = b.and(b.not(shipped), b.not(delivered));
  const refund = b.and(settled, b.orAll([cancelled, buyerWon, b.and(notSent, deadlinePassed)]));
  return b.build([release, refund]);
}

/** New-Store Limit: an order may be released automatically if the store is established, or the amount is within its limit */
export const NEW_STORE_LIMIT = {
  key: "new-store-limit",
  title: "New-Store Limit",
  // amount and limit are 8-bit counts of the same unit (e.g. $10 steps), least significant bit first
  inputs: [...Array.from({ length: 8 }, (_, i) => `amount${i}`), ...Array.from({ length: 8 }, (_, i) => `limit${i}`), "established"],
  outputs: ["ok"],
} as const;

export const newStoreLimitRule = (amount: number, limit: number, established: boolean) => established || amount <= limit;

/**
 * x ≤ y on 8 bits is the carry out of y + NOT x + 1. Per bit, with n1 = NAND(x, y), n2 = NAND(y, n1) and
 * n3 = NAND(x, n1) (which is y OR NOT x), the carry is c' = NAND(n2, NAND(c, n3)); bit 0 starts with c = 1,
 * so its carry is n3 itself. 37 NANDs for 8 bits.
 */
function lessOrEqual(b: Builder, x: Sig[], y: Sig[]): Sig {
  let carry: Sig | undefined;
  for (let i = 0; i < x.length; i++) {
    const n1 = b.nand(x[i], y[i]);
    const n3 = b.nand(x[i], n1);
    if (carry === undefined) {
      carry = n3;
      continue;
    }
    const n2 = b.nand(y[i], n1);
    carry = b.nand(n2, b.nand(carry, n3));
  }
  return carry!;
}

export function newStoreLimit(): Built {
  const b = new Builder(NEW_STORE_LIMIT.inputs.length);
  const amount = Array.from({ length: 8 }, (_, i) => b.input(i));
  const limit = Array.from({ length: 8 }, (_, i) => b.input(8 + i));
  const established = b.input(16);
  return b.build([b.or(established, lessOrEqual(b, amount, limit))]);
}

/** Store Breaker: a dispute trips it, and it stays tripped (no automatic releases for that store) until Sotechy clears it */
export const STORE_BREAKER = {
  key: "store-breaker",
  title: "Store Breaker",
  inputs: ["disputeOpened", "cleared"],
  outputs: ["ok"],
  state: ["tripped"],
} as const;

/** One beat: tripped' = disputeOpened OR (tripped AND NOT cleared); ok = NOT tripped'. A new dispute wins over a clear. */
export function storeBreakerRule(tripped: boolean, disputeOpened: boolean, cleared: boolean) {
  const next = disputeOpened || (tripped && !cleared);
  return { tripped: next, ok: !next };
}

export function storeBreaker(): Built {
  const b = new Builder(STORE_BREAKER.inputs.length);
  const [opened, cleared] = [b.input(0), b.input(1)];
  const tripped = b.latch();
  const next = b.or(opened, b.and(tripped, b.not(cleared)));
  b.store(tripped, next);
  return b.build([b.not(next)]);
}

export const CIRCUITS = [
  { ...ORDER_VERDICT, build: orderVerdict },
  { ...NEW_STORE_LIMIT, build: newStoreLimit },
  { ...STORE_BREAKER, build: storeBreaker },
];
