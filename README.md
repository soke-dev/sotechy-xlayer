<div align="center">
  <img src="https://raw.githubusercontent.com/soke-dev/Sotechy-App/main/apps/admin/public/brand/sotechy-icon-512.png" alt="Sotechy" width="80" />
  <h1>Sotechy × X Layer</h1>
  <p><strong>The tokenized marketplace of verified stores, on X Layer: pay in USDT, earn store tokens, keep your receipt as an NFT, and let TapeOut circuits decide when your money moves.</strong></p>
  <p>
    Built for the <strong>X Layer Build X</strong> hackathon (TapeOut) ·
    <a href="https://sotechy.shop">sotechy.shop</a> ·
    Main app: <a href="https://github.com/soke-dev/Sotechy-App">soke-dev/Sotechy-App</a>
  </p>
</div>

---

> **Status: live on X Layer mainnet.** Built for Build X, November to December 2026. The [Status](#status) table says what works today, and [Deployments](#deployments-x-layer-mainnet-chain-196) lists every address.

Sotechy is a marketplace of verified stores in Nigeria, live on the App Store and the web. Every store has its own reward token, and every order gets a receipt. Buying online there runs on low trust: buyers pay strangers and hope the order arrives, and stores fear buyers who say it never did. This project brings Sotechy's checkout, rewards and receipts onto X Layer, and puts TapeOut circuits in charge of the money between buyer and store.

## What's on X Layer

### 💸 Pay in USDT
At checkout, a buyer pays the order's total in USDT (USD₮0) on X Layer, from OKX Wallet or any wallet. They need no OKB for gas: they sign a permit, and Sotechy sends the payment and pays the fee. X Layer's fees are a fraction of a cent, and USDT moves from the OKX exchange to X Layer cheaply, which suits Nigerian buyers who already hold dollars there.

### 🇳🇬 Paid in naira? Still on X Layer
Most Sotechy orders are paid in naira by bank transfer. The escrow holds only USDT, so a naira payment stays with Sotechy and the store is paid on Sotechy's usual schedule. The order still earns its store tokens and gets its Sotechy receipt on X Layer, like every other order.

### 🛡️ TapeOut decides when the money moves
The payment isn't sent to the store. It waits in the Sotechy escrow contract, and **TapeOut circuits decide what happens to it**:

- **Delivered** (the buyer confirms, or the store shipped and the confirm window passed with no complaint): the store is paid.
- **Not shipped in time**, or the store cancels: the buyer gets the money back.
- **A dispute is open**: the money stays put until it's resolved.

The escrow does exactly what the circuits answer. Nobody, Sotechy included, can move the money any other way, and anyone can read the circuits on chain and check the rules.

### 🪙 Store tokens on X Layer
Every Sotechy store has its own token, one token id per store on a single multi-token contract (`SotechyTokens`). Shoppers earn a store's token when an order is delivered, send it to friends by username, and spend it at the store.

Every token change from every Sotechy order (earned, spent, sent, or taken back on a refund) is written to X Layer, however the order was paid, and Sotechy pays the gas. An order the circuits refund was never delivered, so it earns nothing. Tokens and receipts are on X Layer from **24 November 2026**.

### 🧾 Receipt NFTs
Two kinds, both on X Layer. Neither can be sold or sent on, and neither holds amounts or personal data.

- **Escrow receipt** (`SotechyOrderReceipts`): minted to the buyer when they pay into the escrow. It follows the circuits' decisions (paid and held, shipped, on hold during a dispute, delivered, refunded), and its picture is drawn on chain from that status.
- **Sotechy receipt** (`SotechyReceipts`): every completed Sotechy order gets one, however it was paid. It records the store, the order number, the date and a fingerprint of the full receipt Sotechy keeps, so anyone holding the receipt can check it.

### 🔍 A public order checker on DeWEB
A page stored on chain, on our circuit's DeWEB container: enter an order number and see where its money is and what the circuits decided.

## Where TapeOut is used

The decisions run inside TapeOut circuits, minted on the existing **OrderGuard** processor on X Layer mainnet. Holding the money, the tokens, the receipts and the app run outside circuits.

| Circuit | What it decides | Kind | Gates |
|---|---|---|---|
| **Order Verdict** | From the order's facts (paid, store verified, shipped, delivered, confirm window over, ship-by deadline passed, dispute open, dispute won by the buyer, store cancelled): **release** to the store, **refund** the buyer, or neither | Combinational (`eval`) | 27 NAND |
| **New-Store Limit** | Is this order bigger than a new store is allowed? If so, release waits for a Sotechy review | Combinational (`eval`), an 8-bit comparator | 40 NAND |
| **Store Breaker** | Has this store just had a dispute? It trips and stays tripped, pausing that store's automatic releases until Sotechy clears it | Sequential (`step`), one LATCH | 5 NAND, 1 LATCH |

Every circuit is checked on every possible input, by our TAP-02 evaluator, by TapeOut's own reference evaluator, and by the real OrderGuard processor on a fork of mainnet. Pinouts and rules: [circuits/README.md](circuits/README.md).

The circuits are Sotechy's: each is an NFT on X Layer, so other marketplaces can use the same rules.

## How an order goes

```
Buyer picks "Pay with USDT on X Layer" in the Sotechy app
  → the exact total goes into the escrow     → receipt NFT minted: "Paid, held"
  → the store ships; the buyer taps "I got it" (or the confirm window passes)
  → anyone calls settle(order): the escrow reads the order's facts, asks the circuits
      release → the store is paid,          receipt: "Delivered"
      refund  → the buyer is paid back,     receipt: "Refunded"
      neither → nothing moves yet (a dispute or review is open)
```

The delivered order earns the buyer its store tokens and gets its Sotechy receipt, both on X Layer. A refunded order earns nothing.

## Check it yourself

```bash
cd circuits && npm test && npm run check:reference        # Node 22.18+, Python 3; nothing to install
cd ../contracts && git submodule update --init && forge test   # Foundry
FORK=true forge test --match-path "test/fork/*"           # against the real OrderGuard, on a fork of X Layer mainnet
bash script/rehearse.sh                                   # the whole launch on a local copy of X Layer
```

What the contracts do, step by step: [contracts/README.md](contracts/README.md). Launching on mainnet: [docs/LAUNCH.md](docs/LAUNCH.md).

## Two codebases

| Repository | What's in it |
|---|---|
| **This one** (`sotechy-xlayer`) | Everything that runs on X Layer, all new for Build X: the circuits and their tests, the escrow, the receipt NFT contract, the deploy scripts and the DeWEB order checker |
| [**Sotechy-App**](https://github.com/soke-dev/Sotechy-App) | The live Sotechy marketplace: the app, the store and admin dashboards, the website and the API. For Build X it gains the USDT pay page, the order screens, the X Layer watcher, and every order's store tokens and receipts written to X Layer (listed below) |

### The Build X changes in Sotechy-App

All on `main`, live on [sotechy.shop](https://sotechy.shop). `apps/api/dev/xlayer-e2e.mjs` runs them end to end on a local copy of X Layer mainnet, with the real escrow and circuits: USDT paid, released and refunded, and every order's store tokens and receipts written to X Layer.

| Commit | What it adds |
|---|---|
| [`717d84f`](https://github.com/soke-dev/Sotechy-App/commit/717d84f) | API: pay with USDT on X Layer through the escrow, mirror each order step to it, and watch its events |
| [`62f76dc`](https://github.com/soke-dev/Sotechy-App/commit/62f76dc) | Admin → Settings: Pay with USDT on X Layer, with the escrow's setup and the operator's gas |
| [`a479519`](https://github.com/soke-dev/Sotechy-App/commit/a479519) | The pay page, sotechy.shop/pay/usdt: connect a wallet or open it in OKX Wallet, sign a USD₮0 permit, no OKB needed |
| [`494f3f7`](https://github.com/soke-dev/Sotechy-App/commit/494f3f7) | App: USDT on X Layer at checkout, and where the money is on each order, with a link to the order checker |
| [`f0a45bc`](https://github.com/soke-dev/Sotechy-App/commit/f0a45bc) | Store dashboard: a USDT order's payouts go out when the circuits release the money |
| [`a34ede9`](https://github.com/soke-dev/Sotechy-App/commit/a34ede9) | Store tokens and receipts deployed on X Layer |
| [`44d5c97`](https://github.com/soke-dev/Sotechy-App/commit/44d5c97) | API: every order's store tokens and receipts written to X Layer |
| [`1a8b58e`](https://github.com/soke-dev/Sotechy-App/commit/1a8b58e) | Admin → Tokens: X Layer's contracts, what's waiting to be written, and the operator's OKB |
| [`68e6f04`](https://github.com/soke-dev/Sotechy-App/commit/68e6f04) | API: tokens and receipts on X Layer from 24 November 2026 |

## Status

| Part | Status |
|---|---|
| TapeOut circuit format (TAP-02) toolkit, passing the official test vectors | Done |
| The three circuits, tested on every input, and on the real OrderGuard processor | Done |
| The escrow, tested with a mock processor and against the real OrderGuard on a mainnet fork | Done |
| Receipt NFTs, and tokens minted on release | Done |
| DeWEB order checker page, and its publish script | Done |
| Launch scripts (tape out, deploy, publish), rehearsed on a copy of mainnet | Done |
| Mainnet: circuits taped out, contracts deployed, checker published on DeWEB | Done |
| In Sotechy-App: the pay page, the order screens, the store and admin views | Done, live |
| Every order's store tokens and receipts written to X Layer | Done, live |

## Deployments (X Layer mainnet, chain 196)

| | Where |
|---|---|
| TapeOut processor (OrderGuard, processor #272) | [`0x57F319CF056F72F48cF1dbb670F2A3DB007Aa355`](https://www.oklink.com/xlayer/address/0x57F319CF056F72F48cF1dbb670F2A3DB007Aa355) |
| **Order Verdict** circuit | **#26** on OrderGuard |
| **New-Store Limit** circuit | **#27** on OrderGuard |
| **Store Breaker** circuit | **#28** on OrderGuard |
| `SotechyEscrow` | [`0xdfEE90861e00ed79963edB7e7c11facdBF930310`](https://www.oklink.com/xlayer/address/0xdfEE90861e00ed79963edB7e7c11facdBF930310) |
| `SotechyOrderReceipts` | [`0x80b42099567D5eF1A8e8421bD38ae6cAc589F180`](https://www.oklink.com/xlayer/address/0x80b42099567D5eF1A8e8421bD38ae6cAc589F180) |
| `SotechyTokens` (store tokens) | [`0x704c1Fc6e6adb2De17436b509e196F1A57968f7B`](https://www.oklink.com/xlayer/address/0x704c1Fc6e6adb2De17436b509e196F1A57968f7B) |
| `SotechyReceipts` (a receipt for every order) | [`0x04779caedcc9ecfd28a6a51cf85536be67db01db`](https://www.oklink.com/xlayer/address/0x04779caedcc9ecfd28a6a51cf85536be67db01db) |
| Order checker on DeWEB | `26.2.272.tape`, at [26-2-272.tapekit.org](https://26-2-272.tapekit.org/) (stored in circuit #26's container [`0xc3595E8d2405BD2df6ceC4Ef73452a41A892F52D`](https://www.oklink.com/xlayer/address/0xc3595E8d2405BD2df6ceC4Ef73452a41A892F52D)) |
| USD₮0 | [`0x779Ded0c9e1022225f8E0630b35a9b54bE713736`](https://www.oklink.com/xlayer/address/0x779Ded0c9e1022225f8E0630b35a9b54bE713736) |

The circuits' NFTs and the contracts are owned by Sotechy's wallet [`0xB73B75db9Da49F37f6f8aB658355DBE7D1558e89`](https://www.oklink.com/xlayer/address/0xB73B75db9Da49F37f6f8aB658355DBE7D1558e89).

## Repository layout

```
spec/        TapeOut's TAP-02 circuit format, reference evaluator and test vectors (CC0)
circuits/    the TAP-02 toolkit, the three circuits, netlists.json and their exhaustive tests
contracts/   the escrow, the receipt NFT, the launch scripts, and Foundry tests (unit and mainnet fork)
checker/     the order checker page, published on DeWEB
docs/        the mainnet launch guide
```

## Hackathon work and baseline

- **Everything in this repository is new**, written for Build X.
- **Baseline:** the Sotechy marketplace ([Sotechy-App](https://github.com/soke-dev/Sotechy-App)) existed before the event. Its store-token and receipt contracts are reused unchanged, deployed on X Layer during the event. Only the Build X changes to Sotechy-App, listed above, are part of this entry.

## Built with

TapeOut (OrderGuard processor, TAP-02 netlists, DeWEB) · X Layer mainnet (chain 196) · USD₮0 · Solidity and Foundry · TypeScript and viem · Sotechy's app (Expo), dashboards (Next.js) and API (Hono)

## Team

Sotechy, Nigeria · [sotechy.shop](https://sotechy.shop) · hello@sotechy.shop · [@sotechyshop](https://x.com/sotechyshop)

## License

MIT, see [LICENSE](LICENSE). The files in `spec/` are TapeOut's, dedicated to the public domain (CC0).
