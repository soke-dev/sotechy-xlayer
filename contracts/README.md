# Contracts

The escrow, the receipt NFT, and the scripts that tape out the circuits, deploy everything and publish the order checker on X Layer mainnet. Built with [Foundry](https://getfoundry.sh).

```bash
git submodule update --init       # forge-std
forge test                        # unit tests, with a TAP-02 mock processor
FORK=true forge test --match-path "test/fork/*"   # the same against the real OrderGuard, on a mainnet fork
bash script/rehearse.sh           # the whole launch on a local copy of X Layer, with a throwaway key
```

## `SotechyEscrow`

Holds each order's USDT and does what the circuits answer.

| Step | Who | What happens |
|---|---|---|
| `open` | Sotechy's operator | Sets the order's terms: the store's payout address, amount, pay-by and ship-by dates, and the tokens it earns |
| `pay` | The buyer | Pays the exact amount (after approving it). The receipt NFT is minted to them |
| `markShipped` | The store, or Sotechy | Records that it was sent |
| `confirmDelivered` | The buyer, or Sotechy relaying "I got it" from the app | Records delivery, and settles at once if the circuits release |
| `openDispute` | The buyer, or Sotechy | Holds the money and trips the store's breaker |
| `resolveDispute` | Sotechy | For the buyer (refund) or the store, then settles if decided |
| `cancel` | The store, or Sotechy | Refunds the buyer |
| `approveReview` | Sotechy | Lets a new store's order above its limit be released |
| `settle` | **Anyone** | Asks the circuits and does what they answer |

How a decision is made (`_decide`):

1. The order's facts become the Order Verdict's 9 input bits; `eval` on OrderGuard answers release, refund or neither.
2. A release also needs the **New-Store Limit** (`eval`) to say the amount is within the store's limit, and the **Store Breaker** (`step`, with the store's memory) to say the store is clear. A refund never waits for either.
3. On release: the store is paid (less Sotechy's fee, fixed when the order opened), the receipt says "Delivered", and the store's tokens are minted to the buyer. A failed mint never holds up the store's money.
4. On refund: the buyer gets the full amount back, the receipt says "Refunded", and no tokens are minted.

Safety:

- **Trusted processor only.** The escrow remembers the processor's code and the circuit implementation behind TapeOut's beacon. If TapeOut upgrades either, nothing is decided until the owner reviews it and calls `trustProcessor`.
- **The exact circuits.** `setCircuits` checks each circuit's shape and that its bytes hash to `circuits/netlists.json`.
- **Bounded circuit calls.** Each gets a fixed gas allowance, and a malformed answer is refused.
- **Sotechy can't take the money.** The only emergency power, `emergencyRefund`, sends a paid order's money back to its own buyer, and only while paused.
- Reentrancy guard on every money path; transfers last.

## `SotechyOrderReceipts`

A soulbound ERC-721: one receipt per order, token id = order id, minted to the buyer when they pay. Only the escrow sets its status: held, shipped, on hold, delivered or refunded. `tokenURI` returns JSON with an SVG picture drawn on chain from that status, and status changes emit ERC-4906 `MetadataUpdate` so wallets refresh it. No amounts or personal details are stored.

## Store tokens

`src/vendor/SotechyTokens.sol` is Sotechy's existing store-token contract, copied unchanged from Sotechy-App (see [src/vendor/README.md](src/vendor/README.md)). On X Layer the escrow is added as one more operator, and mints a store's tokens only when an order's money is released.

## Launching on mainnet

See [docs/LAUNCH.md](../docs/LAUNCH.md).

| Script | Does |
|---|---|
| `script/TapeOut.s.sol` | Buys the transistors (72 NAND, 1 LATCH) and tapes out the three circuits on OrderGuard. About 0.0125 OKB |
| `script/Deploy.s.sol` | Deploys the receipts, the escrow and the token contract, and wires them to the circuits |
| `script/PublishChecker.s.sol` | Publishes the order checker on DeWEB, in the Order Verdict circuit's container (0.08 OKB once) |
| `script/rehearse.sh` | All three on a local copy of X Layer, with a throwaway key |
