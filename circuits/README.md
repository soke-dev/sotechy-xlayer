# Circuits

Sotechy's three TapeOut circuits, the small toolkit that builds them, and tests that check every one on every possible input.

```bash
npm test                  # the official TAP-02 vectors, the builder, and every input of every circuit
npm run build             # writes netlists.json: the exact bytes to tape out
npm run check:reference   # runs netlists.json through TapeOut's own reference evaluator (Python)
```

Node 22.18 or later runs the TypeScript directly; there's nothing to install.

## The circuits

| Circuit | Inputs | Outputs | Gates | What it decides |
|---|---|---|---|---|
| **Order Verdict** | 9 | 2 | 27 NAND | Release the order's money to the store, refund the buyer, or neither |
| **New-Store Limit** | 17 | 1 | 40 NAND | Whether a new store's order is within its limit (or the store is established) |
| **Store Breaker** | 2 | 1 | 5 NAND + 1 LATCH | Whether the store is clear, remembering a dispute until Sotechy clears it |

Bits are packed least significant first (TAP-02 §5). The escrow packs the inputs in exactly this order.

### Order Verdict

| Bit | Input | Meaning |
|---|---|---|
| 0 | `paid` | the buyer's USDT is in the escrow |
| 1 | `storeVerified` | the store passed Sotechy's checks and isn't suspended |
| 2 | `shipped` | the store marked the order sent |
| 3 | `delivered` | the buyer confirmed they got it |
| 4 | `confirmWindowOver` | shipped, and the confirm window passed with no complaint |
| 5 | `shipDeadlinePassed` | the ship-by date passed |
| 6 | `disputeOpen` | the buyer reported a problem that isn't resolved |
| 7 | `buyerWonDispute` | a dispute was resolved for the buyer |
| 8 | `storeCancelled` | the store cancelled |

```
release = paid AND storeVerified AND NOT disputeOpen AND NOT buyerWonDispute AND NOT storeCancelled
          AND (delivered OR (shipped AND confirmWindowOver))
refund  = paid AND NOT disputeOpen
          AND (storeCancelled OR buyerWonDispute OR (NOT shipped AND NOT delivered AND shipDeadlinePassed))
```

The tests also check that `release` and `refund` are never both 1, that unpaid money never moves, and that nothing moves while a dispute is open.

### New-Store Limit

Bits 0–7: the order amount, bits 8–15: the store's limit, both in the same steps (the escrow uses $10). Bit 16: the store is established. Output: `established OR amount ≤ limit`.

The comparator is the carry out of `limit + NOT amount + 1`, five NANDs a bit and two for bit 0 (37 for 8 bits).

### Store Breaker

Inputs: `disputeOpened`, `cleared`. One LATCH remembers whether the store is tripped:

```
tripped' = disputeOpened OR (tripped AND NOT cleared)      a new dispute wins over a clear
ok       = NOT tripped'
```

The escrow keeps each store's one bit of memory and passes it to `step` on the processor.

## How it's checked

1. **`src/tap02.ts`** decodes, checks and runs netlists exactly as TAP-02 says. It's a port of TapeOut's reference implementation, and passes all of TapeOut's official vectors (`spec/vectors.json`).
2. **`src/builder.ts`** writes logic as NAND gates. It folds constants, shares equal gates, drops unused ones and puts the outputs last, as TAP-02 requires.
3. **`src/circuits.ts`** has each circuit's pinout, its builder and its rule in plain code.
4. **The tests** decode the built bytes and run them with `tap02.ts`, comparing with the rule on every input: 512 for the Order Verdict, 131,072 for the New-Store Limit, and every state and input of the Store Breaker.
5. **`test/check_reference.py`** runs `netlists.json` through TapeOut's own Python evaluator on all 131,592 cases, independent of our TypeScript.
6. **On chain:** `contracts/test/fork` tapes the same bytes out on the real OrderGuard processor, on a fork of X Layer mainnet, and checks the processor's answers too.
