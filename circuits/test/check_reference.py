"""Runs circuits/netlists.json through TapeOut's own reference evaluator (spec/reference.py) on every input,
and checks the answers against the rules written out again here. Independent of our TypeScript code.

Run from the repo root or circuits/: python circuits/test/check_reference.py
"""
import json
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent.parent / "spec"))
import reference as ref  # noqa: E402

circuits = {c["key"]: c for c in json.loads((HERE.parent / "netlists.json").read_text())["circuits"]}


def load(key):
    c = circuits[key]
    return ref.load(bytes.fromhex(c["netlist"][2:]), c["nIn"], c["nOut"])


def bits(n, width):
    return [(n >> i) & 1 for i in range(width)]


checked = 0

# Order Verdict
c = load("order-verdict")
for n in range(1 << 9):
    paid, verified, shipped, delivered, window_over, deadline, dispute, buyer_won, cancelled = bits(n, 9)
    release = paid and verified and not dispute and not buyer_won and not cancelled and (delivered or (shipped and window_over))
    refund = paid and not dispute and (cancelled or buyer_won or (not shipped and not delivered and deadline))
    _, outs = ref.beat(c, [], bits(n, 9))
    assert outs == [int(bool(release)), int(bool(refund))], f"order-verdict input {n}: {outs}"
    checked += 1

# New-Store Limit
c = load("new-store-limit")
for established in (0, 1):
    for amount in range(256):
        for limit in range(256):
            _, outs = ref.beat(c, [], bits(amount, 8) + bits(limit, 8) + [established])
            assert outs == [int(bool(established) or amount <= limit)], f"new-store-limit {amount} {limit} {established}"
            checked += 1

# Store Breaker
c = load("store-breaker")
assert c.n_state == 1
for tripped in (0, 1):
    for n in range(4):
        opened, cleared = bits(n, 2)
        nxt = int(bool(opened or (tripped and not cleared)))
        new_state, outs = ref.beat(c, [tripped], [opened, cleared])
        assert new_state == [nxt] and outs == [1 - nxt], f"store-breaker {tripped} {opened} {cleared}"
        checked += 1

print(f"TapeOut's reference evaluator agrees on all {checked:,} cases")
