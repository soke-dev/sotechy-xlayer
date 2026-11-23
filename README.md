<div align="center">
  <img src="https://raw.githubusercontent.com/soke-dev/Sotechy-App/main/apps/admin/public/brand/sotechy-icon-512.png" alt="Sotechy" width="80" />
  <h1>Sotechy Protected Orders</h1>
  <p><strong>Buy from a store you've never met. TapeOut circuits on X Layer decide when your money moves.</strong></p>
  <p>
    Built for the <strong>X Layer Build X</strong> hackathon (TapeOut) ·
    Part of <a href="https://sotechy.shop">Sotechy</a> ·
    Main app: <a href="https://github.com/soke-dev/Sotechy-App">soke-dev/Sotechy-App</a>
  </p>
</div>

---

> **Status: in progress.** This repository is being built for the Build X hackathon, November to December 2026. The table under [Status](#status) says what works today; mainnet addresses are added as each part goes live.

## The problem

Sotechy is a marketplace of verified stores in Nigeria. Buying online there runs on low trust: buyers pay strangers and hope the order arrives, and stores fear buyers who claim it never did. Today Sotechy itself holds the money in the middle, so everyone has to trust Sotechy too.

## What we're building

**Protected orders.** A buyer pays in USDT on X Layer. The money isn't sent to the store: it waits in the Sotechy escrow contract. Then **TapeOut circuits decide what happens to it**, and the escrow does exactly what they answer:

- **Delivered** (the buyer confirms, or the store shipped and the confirm window passed with no complaint): the money goes to the store.
- **Not shipped in time**, or the store cancels: the money goes back to the buyer.
- **A dispute is open**: the money stays put until it's resolved.

Nobody, Sotechy included, can move the money in any other way. Anyone can read the circuits on chain and check the rules.

## Where TapeOut is used

The decisions run inside TapeOut circuits, minted on the existing **OrderGuard** processor on X Layer mainnet. Everything else (holding the money, the app, the pages) runs outside circuits.

| Circuit | What it decides | Kind |
|---|---|---|
| **Order Verdict** | From the order's facts (paid, store verified, shipped, delivered, confirm window over, ship-by deadline passed, dispute open, dispute won by the buyer, store cancelled): **release** to the store, **refund** the buyer, or neither | Combinational (`eval`) |
| **New-Store Limit** | Is this order bigger than a new store is allowed? If so, release waits for a Sotechy review | Combinational (`eval`), an 8-bit comparator |
| **Store Breaker** | Has this store just had a dispute? It trips and stays tripped, pausing that store's automatic releases until Sotechy clears it | Sequential (`step`), one LATCH |

The circuits are Sotechy's: each is an NFT on X Layer, so other marketplaces can use the same rules.

## Receipts and tokens on X Layer

- **A receipt that shows the verdict.** When the buyer pays, the escrow mints the order's receipt NFT to their wallet. It changes as the circuits decide: paid and held, then delivered (store paid), refunded, or on hold during a dispute. Its picture is drawn on chain from that status.
- **Tokens only for delivered orders.** Every Sotechy store has its own reward token. On a protected order, the store's tokens are minted only when the Order Verdict circuit releases the money, so a refunded or fake order earns nothing.
- **A public verifier page on DeWEB**, stored on our circuit's container: enter an order number and see where its money is and what the circuits decided.

## How it fits into Sotechy

Two switches in Sotechy's admin dashboard turn it on, and both start off:

| Switch | When it's on |
|---|---|
| **Settings → Protected orders on X Layer (TapeOut)** | Checkout offers "Pay with USDT on X Layer, protected". Orders show where the money is and let the buyer confirm delivery or report a problem. Stores see what's held and when it releases. Sotechy's team sees money held, disputes and tripped breakers. |
| **Tokens → Main chain → X Layer** | All orders' tokens and receipts are written to X Layer, and the wallet's "View on chain" links open X Layer's explorer. |

Turning protected orders off only hides the option for new orders: orders already paid that way still settle by the circuits.

## Status

| Part | Status |
|---|---|
| TapeOut circuit format (TAP-02) toolkit, checked against the official test vectors | In progress |
| The three circuits, tested on every input | In progress |
| `SotechyEscrow`, tested against the real OrderGuard processor on a mainnet fork | Planned |
| Circuit-driven receipts, and tokens minted on release | Planned |
| Mainnet: circuits minted, contracts deployed | Planned |
| In Sotechy: the switches, pay page, order screens, merchant and admin views | Planned |
| DeWEB verifier page | Planned |

## Repository layout

```
spec/        TapeOut's TAP-02 circuit format, reference evaluator and test vectors (CC0)
circuits/    our circuit builder, the three circuits and their exhaustive tests   (coming)
contracts/   the escrow, receipts and deploy scripts, with Foundry tests            (coming)
verifier/    the DeWEB verifier page                                              (coming)
```

## Hackathon work and baseline

- **Everything in this repository is new**, written for Build X.
- **Baseline:** the Sotechy marketplace itself ([Sotechy-App](https://github.com/soke-dev/Sotechy-App)) existed before the event. Its token contract is reused unchanged on X Layer. The changes we make in Sotechy-App for this entry (the switches, the pay page, the order screens and the X Layer watcher) will be listed here with links to the commits.

## Built with

TapeOut (OrderGuard processor, TAP-02 netlists, DeWEB) · X Layer mainnet (chain 196) · USDT0 · Solidity and Foundry · TypeScript and viem · Sotechy's app (Expo), dashboards (Next.js) and API (Hono)

## Team

Sotechy, Nigeria · [sotechy.shop](https://sotechy.shop) · hello@sotechy.shop · [@sotechyshop](https://x.com/sotechyshop)

## License

MIT, see [LICENSE](LICENSE). The files in `spec/` are TapeOut's, dedicated to the public domain (CC0).
