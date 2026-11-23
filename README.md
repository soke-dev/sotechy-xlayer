<div align="center">
  <img src="https://raw.githubusercontent.com/soke-dev/Sotechy-App/main/apps/admin/public/brand/sotechy-icon-512.png" alt="Sotechy" width="80" />
  <h1>Sotechy × X Layer</h1>
  <p><strong>The tokenized marketplace of verified stores, on X Layer: pay in USDT, earn store tokens, keep your receipt as an NFT, and let TapeOut circuits decide when your money moves.</strong></p>
  <p>
    Built for the <strong>X Layer Build X</strong> hackathon (TapeOut) ·
    <a href="https://sotechy.shop">sotechy.shop</a> ·
    Main app: <a href="https://github.com/soke-dev/Sotechy-App">soke-dev/Sotechy-App</a>
  </p>
  <p><a href="https://github.com/soke-dev/sotechy-xlayer/actions/workflows/ci.yml"><img src="https://github.com/soke-dev/sotechy-xlayer/actions/workflows/ci.yml/badge.svg" alt="CI"></a></p>
</div>

---

> **Status: built and tested, launching on mainnet next.** Built for Build X, November to December 2026. The [Status](#status) table says what works today; mainnet addresses are added at launch.

Sotechy is a marketplace of verified stores in Nigeria, live on the App Store and the web. Every store has its own reward token, and every order gets a receipt. Buying online there runs on low trust: buyers pay strangers and hope the order arrives, and stores fear buyers who say it never did. This project brings Sotechy's checkout, rewards and receipts onto X Layer, and puts TapeOut circuits in charge of the money between buyer and store.

## What's on X Layer

### 💸 Pay in USDT
At checkout, a buyer pays the order's total in USDT (USD₮0) on X Layer, from OKX Wallet or any wallet. X Layer's fees are a fraction of a cent, and USDT moves from the OKX exchange to X Layer cheaply, which suits Nigerian buyers who already hold dollars there.

### 🛡️ TapeOut decides when the money moves
The payment isn't sent to the store. It waits in the Sotechy escrow contract, and **TapeOut circuits decide what happens to it**:

- **Delivered** (the buyer confirms, or the store shipped and the confirm window passed with no complaint): the store is paid.
- **Not shipped in time**, or the store cancels: the buyer gets the money back.
- **A dispute is open**: the money stays put until it's resolved.

The escrow does exactly what the circuits answer. Nobody, Sotechy included, can move the money any other way, and anyone can read the circuits on chain and check the rules.

### 🪙 Store tokens, earned on delivery
Every Sotechy store has its own token, one token id per store on a single multi-token contract. On X Layer, an order's tokens are minted **only when the circuit releases the money**, so a refunded or fake order earns nothing. Shoppers send tokens to friends by username, and spend them at the store.

### 🧾 Receipt NFTs that show the verdict
When the buyer pays, the order's receipt NFT is minted to their wallet. It follows the circuits' decisions (paid and held, delivered and store paid, refunded, or on hold during a dispute), and its picture is drawn on chain from that status. It holds no amounts or personal data.

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
  → pays the exact total into the escrow     → receipt NFT minted: "Paid, held"
  → the store ships; the buyer taps "I got it" (or the confirm window passes)
  → anyone calls settle(order): the escrow reads the order's facts, asks the circuits
      release → the store is paid, the store's tokens are minted to the buyer, receipt: "Delivered"
      refund  → the buyer is paid back, no tokens,                              receipt: "Refunded"
      neither → nothing moves yet (a dispute or review is open)
```

## Check it yourself

```bash
cd circuits && npm test && npm run check:reference        # Node 22.18+, Python 3; nothing to install
cd ../contracts && git submodule update --init && forge test   # Foundry
FORK=true forge test --match-path "test/fork/*"           # against the real OrderGuard, on a fork of X Layer mainnet
bash script/rehearse.sh                                   # the whole launch on a local copy of X Layer
```

What the contracts do, step by step: [contracts/README.md](contracts/README.md). Launching on mainnet: [docs/LAUNCH.md](docs/LAUNCH.md).

## Turning it on in Sotechy

Two switches in Sotechy's admin dashboard, both off until turned on:

| Switch | When it's on |
|---|---|
| **Settings → Pay with USDT on X Layer** | Checkout offers USDT on X Layer, with the money held by the escrow until the circuits release it. Orders show where the money is and let the buyer confirm delivery or report a problem. Stores see what's held and when it releases. Sotechy's team sees the money held, disputes and tripped breakers. |
| **Tokens → Main chain → X Layer** | All orders' tokens and receipts are written to X Layer, and the wallet's "View on chain" links open X Layer's explorer. |

Turning the payment switch off only hides it for new orders: orders already paid that way still settle by the circuits.

## Two codebases

| Repository | What's in it |
|---|---|
| **This one** (`sotechy-xlayer`) | Everything that runs on X Layer, all new for Build X: the circuits and their tests, the escrow, the receipt NFT contract, the deploy scripts and the DeWEB order checker |
| [**Sotechy-App**](https://github.com/soke-dev/Sotechy-App) | The live Sotechy marketplace: the app, the store and admin dashboards, the website and the API. For Build X it gains the two switches, the USDT pay page, the order screens and the X Layer watcher. Those changes will be listed here, with links to the commits |

## Status

| Part | Status |
|---|---|
| TapeOut circuit format (TAP-02) toolkit, passing the official test vectors | Done |
| The three circuits, tested on every input, and on the real OrderGuard processor | Done |
| The escrow, tested with a mock processor and against the real OrderGuard on a mainnet fork | Done |
| Receipt NFTs, and tokens minted on release | Done |
| DeWEB order checker page, and its publish script | Done |
| Launch scripts (tape out, deploy, publish), rehearsed on a copy of mainnet | Done |
| Mainnet: circuits taped out, contracts deployed, checker published | Next |
| In Sotechy-App: the switches, the pay page, the order screens, the store and admin views | In progress |

## Deployments (X Layer mainnet, chain 196)

| | Address |
|---|---|
| TapeOut processor (OrderGuard, #272) | [`0x57F3…a355`](https://www.oklink.com/xlayer/address/0x57F319CF056F72F48cF1dbb670F2A3DB007Aa355) |
| Order Verdict, New-Store Limit, Store Breaker | circuit ids added at launch |
| `SotechyEscrow` | added at launch |
| `SotechyOrderReceipts` | added at launch |
| `SotechyTokens` | added at launch |
| Order checker on DeWEB | added at launch |

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
- **Baseline:** the Sotechy marketplace ([Sotechy-App](https://github.com/soke-dev/Sotechy-App)) existed before the event. Its store-token contract is reused unchanged on X Layer. Only the Build X changes to Sotechy-App, listed above, are part of this entry.

## Built with

TapeOut (OrderGuard processor, TAP-02 netlists, DeWEB) · X Layer mainnet (chain 196) · USD₮0 · Solidity and Foundry · TypeScript and viem · Sotechy's app (Expo), dashboards (Next.js) and API (Hono)

## Team

Sotechy, Nigeria · [sotechy.shop](https://sotechy.shop) · hello@sotechy.shop · [@sotechyshop](https://x.com/sotechyshop)

## License

MIT, see [LICENSE](LICENSE). The files in `spec/` are TapeOut's, dedicated to the public domain (CC0).
