#!/usr/bin/env bash
# Rehearses the whole mainnet launch on a local copy of X Layer: tape out the circuits on OrderGuard with
# TapeOut.s.sol, deploy and wire everything with Deploy.s.sol, then publish the order checker with
# PublishChecker.s.sol. Uses a throwaway key on the local copy, so no real
# key or OKB is involved. Run from contracts/: bash script/rehearse.sh
set -euo pipefail
cd "$(dirname "$0")/.."

PORT=8547
RPC="http://127.0.0.1:$PORT"
# A throwaway key made up for this rehearsal, funded on the local copy only. (Anvil's usual test accounts
# can't be used: on X Layer mainnet they carry smart-wallet code that refuses the transistor tokens.)
KEY=$(cast keccak "sotechy-xlayer rehearsal")

anvil --fork-url https://rpc.xlayer.tech --port "$PORT" --silent &
ANVIL=$!
trap 'kill $ANVIL 2>/dev/null' EXIT
for _ in $(seq 1 60); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 1; done
echo "Local copy of X Layer at block $(cast block-number --rpc-url "$RPC"), chain $(cast chain-id --rpc-url "$RPC")"
cast rpc anvil_setBalance "$(cast wallet address "$KEY")" 0x8ac7230489e80000 --rpc-url "$RPC" >/dev/null # 10 OKB

echo; echo "== Tape out"
OUT=$(forge script script/TapeOut.s.sol --rpc-url "$RPC" --private-key "$KEY" --broadcast 2>&1)
echo "$OUT" | grep -E "needed|OKB to spend|circuit id" || { echo "$OUT" | tail -20; exit 1; }
id() { echo "$OUT" | grep "$1: circuit id" | awk '{print $NF}'; }
export VERDICT_ID=$(id order-verdict) LIMIT_ID=$(id new-store-limit) BREAKER_ID=$(id store-breaker)

echo; echo "== Deploy"
export OPERATOR=0x70997970C51812dc3A010C7d01b50e0d17dc79C8 FEE_BPS=500
DEPLOYED=$(forge script script/Deploy.s.sol --rpc-url "$RPC" --private-key "$KEY" --broadcast 2>&1)
echo "$DEPLOYED" | grep -E "^ *Sotechy|Now," || { echo "$DEPLOYED" | tail -20; exit 1; }
export ESCROW=$(echo "$DEPLOYED" | grep -E "^ *SotechyEscrow 0x" | head -1 | awk '{print $NF}')

echo; echo "== Publish the order checker on DeWEB"
PUBLISHED=$(forge script script/PublishChecker.s.sol --rpc-url "$RPC" --private-key "$KEY" --broadcast 2>&1)
echo "$PUBLISHED" | grep -E "container|page bytes|name|tapekit" || { echo "$PUBLISHED" | tail -20; exit 1; }
echo; echo "Rehearsal done: circuits $VERDICT_ID, $LIMIT_ID, $BREAKER_ID; escrow $ESCROW"
