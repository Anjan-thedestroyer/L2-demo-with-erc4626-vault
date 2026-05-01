# Multi-Chain Vault Deployment

A Foundry-based deployment of `Vault.s.sol` across Ethereum L1 and two Layer 2 testnets — built to understand how gas costs actually behave across different networks.

---

## What This Project Does

This project deploys the same smart contract to three different networks and compares the results. The goal isn't just to get the contract live — it's to understand *why* costs differ across chains, and what that means when you eventually move to mainnet.

---

## Deployment Results

| Network      | Total Paid (ETH)     | Gas Used | Avg Gas Price |
| Sepolia (L1) | 0.000011552793406581 | 7,470,897 | 0.001546373 Gwei |
| Arbitrum Sepolia (L2) | 0.000149435898978 | 7,470,885 | 0.020004333 Gwei |
| Optimism Sepolia (L2) | 0.00000747275272125 | 7,470,885 | 0.00100025 Gwei |

> Gas used was nearly identical across all three chains — within 12 units. Every cost difference comes down to gas *price*, not gas *consumption*.

---

## A Quick Primer on L2s

Ethereum can only process so many transactions at a time. During busy periods, users compete to get their transactions included, which drives gas prices up. Layer 2 networks (L2s) solve this by processing transactions off the main chain and periodically posting a compressed summary back to Ethereum.

The result: you get Ethereum's security guarantees at a fraction of the cost — because you're sharing the L1 settlement fee across thousands of bundled transactions.

Both Arbitrum and Optimism are **Optimistic Rollups** — the dominant L2 architecture today. They assume transactions are valid by default and only run fraud proofs if someone challenges them. In theory, they should be significantly cheaper than L1.

---

## The Arbitrum Anomaly

Here's the part that's actually interesting: **Arbitrum cost more than both Ethereum L1 and Optimism in this deployment.**

That runs counter to the whole point of L2s, so it deserves an explanation.

**Two things caused this:**

**1. Arbitrum's minimum gas floor**
Arbitrum enforces a minimum base fee of roughly 0.02 Gwei, even when the network is completely idle. This is intentional — it's a spam protection mechanism that prevents people from flooding the testnet with near-free transactions. On a real network under real load, this floor is typically well below the market price and doesn't matter. On a quiet testnet, it becomes the dominant cost driver.

**2. L1 data posting overhead**
Every L2 sequencer has to periodically bundle transactions and post them to Ethereum L1 as calldata. On mainnet, this cost is split across thousands of transactions, making it negligible per-user. On a testnet, L1 (Sepolia) is nearly free and underutilized — but the overhead of running the sequencer and posting that bundle still exists. In this run, that overhead was enough to push Arbitrum's total cost past what it would've been to just run the transaction directly on L1.

**Optimism didn't have this problem** because its base fee was sitting at 0.001 Gwei — well below Arbitrum's floor — so the economics worked out in its favor.

---

## What This Looks Like on Mainnet

Testnets distort the numbers. Here's what the same deployment would cost under realistic mainnet conditions:

| Scenario | Network | Est. Gas Price | Total Cost (7.4M gas) |
| High-traffic L1 | Ethereum Mainnet | ~30 Gwei | ~0.22 ETH (~$600) |
| L2 scaling | Arbitrum / Optimism | ~0.1 Gwei | ~0.001 ETH (~$3) |

That's roughly a **200× cost reduction** for identical execution.

---

## Key Takeaways

**Gas used ≠ gas cost.** The EVM ran the same bytecode with the same computational effort on every chain. What you pay is determined by the fee market of each individual network.

**L2 costs have two components.** Execution fees (what you pay the L2 sequencer) and data availability fees (what the sequencer pays to post your transaction batch to L1). On testnets, the second part can dominate in unexpected ways.

**Testnet economics are not mainnet economics.** Arbitrum's behavior here is a testnet-specific quirk. Under real congestion, both L2s deliver on their promise of dramatically lower fees.

**Rollup architecture matters.** Arbitrum and Optimism are both Optimistic Rollups, but their sequencer designs and fee policies are different. For large deployments like this one (7.4M gas), those differences show up clearly.

---

## How to Run It

```bash
# Deploy to any supported network
forge script script/Vault.s.sol \
  --rpc-url <NETWORK_RPC> \
  --broadcast \
  --verify
```

Replace `<NETWORK_RPC>` with your target network's RPC endpoint. RPC URLs for testnets can be obtained from [Alchemy](https://www.alchemy.com) or [Infura](https://www.infura.io).

---

## Stack

- [Foundry](https://book.getfoundry.sh/) — smart contract development and deployment
- Sepolia — Ethereum L1 testnet
- Arbitrum Sepolia — L2 testnet (Optimistic Rollup)
- Optimism Sepolia — L2 testnet (Optimistic Rollup)