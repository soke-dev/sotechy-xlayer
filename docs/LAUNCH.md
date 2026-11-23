# Launching on X Layer mainnet

Everything runs from `contracts/` with Foundry (in WSL on Windows). The whole launch costs about **0.1 OKB**: 0.0125 OKB for the circuits, 0.08 OKB to open the DeWEB container once, and a little gas.

## 0. Before you start

- **A deploy wallet** with about 0.2 OKB on X Layer. It becomes the owner of the circuits (their NFTs) and of the contracts. Its key stays on this computer.
- **An operator address** for Sotechy's API, a separate low-power key. Make one with `cast wallet new` and keep its private key for Railway (step 6). Send it about 0.02 OKB for gas.

Import the deploy key once into Foundry's encrypted keystore. You type the key and a password; nothing is written in plain text:

```bash
cast wallet import sotechy-deployer --interactive
```

## 1. Rehearse

```bash
bash script/rehearse.sh
```

It runs steps 2 to 4 on a local copy of X Layer with a throwaway key, and prints the circuit ids and addresses it would get.

## 2. Tape out the circuits

```bash
forge script script/TapeOut.s.sol --rpc-url xlayer --account sotechy-deployer --broadcast
```

Note the three circuit ids it prints (Order Verdict, New-Store Limit, Store Breaker).

## 3. Deploy

```bash
OPERATOR=0x<operator address> VERDICT_ID=<id> LIMIT_ID=<id> BREAKER_ID=<id> FEE_BPS=<Sotechy's fee, e.g. 500 for 5%> \
forge script script/Deploy.s.sol --rpc-url xlayer --account sotechy-deployer --broadcast
```

Optional: `OWNER=0x…` hands the contracts to another owner (they then call `acceptOwnership`), `TREASURY=0x…` receives the fee, and `TOKENS=0x…` uses an existing store-token contract instead of deploying one.

## 4. Publish the order checker on DeWEB

```bash
ESCROW=0x<escrow> forge script script/PublishChecker.s.sol --rpc-url xlayer --account sotechy-deployer --broadcast
```

It prints the page's name (`<id>.2.272.tape`) and its web address (`https://<id>-2-272.tapekit.org/`).

## 5. Record the addresses

Fill in the README's Deployments table: the three circuit ids, the escrow, the receipts, the token contract and the checker's address.

## 6. Connect Sotechy

In Railway, on the `api` service, set:

| Variable | Value |
|---|---|
| `XLAYER_ESCROW` | the escrow's address |
| `XLAYER_OPERATOR_KEY` | the operator's private key (never the deploy key) |
| `XLAYER_RPC_URL` | optional; `https://rpc.xlayer.tech` is used without it |

Then in Sotechy's admin, **Settings → Pay with USDT on X Layer**: start with **Staff only**, run a few real orders (delivered, refunded, a dispute), then switch to **Everyone**.
