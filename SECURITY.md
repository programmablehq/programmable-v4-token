# Security status and operating boundaries

This package is a pre-launch engineering draft. It has not been externally audited, approved by Programmable, deployed, source-verified, or proven routable by public trading terminals. Local tests must never be presented as an audit.

## Immutable contract surface

The intended contracts deliberately omit owner/admin methods, proxy upgrades, arbitrary execution, additional minting, pause, blacklist, seizure, transfer taxes, and payout redirection. The initializer is one-shot and binds the canonical pool, initial price, token/hook runtime hashes, infrastructure hashes, exact funding, LP recipient, initial-buy recipient, slippage floor, price limit, and deadline.

The hook has only `beforeInitialize` and `beforeSwap` permissions. It guards the canonical pool initialization and forces the immutable dynamic LP-fee schedule. It does not custody tokens, return swap deltas, call arbitrary external targets, or expose an admin setter.

## Material disclosed risks

- **Single-wallet concentration:** `0x245099E77F8F0Cad9a75B1B56db8FDE7C948d5B1` receives 95% of supply at construction and controls the initial LP NFT. It is intentionally not a multisig. Compromise, loss, or misuse of that key is catastrophic.
- **Unlocked initial liquidity:** the launch wallet can remove its initial position until a separate lock or burn is completed. This is a genuine custody/rug risk and may trigger scanner warnings. The contracts do not pretend otherwise.
- **High opening fee:** canonical-pool swaps in the first 30 seconds pay a 30% LP fee. The first swap is the launch wallet's own atomic buy. Users and integrators must see this clearly before trading.
- **Fee recipient semantics:** there is no exclusive developer tax. Canonical-pool LP fees accrue pro rata to active LPs, subject to protocol accounting. If other LPs add active liquidity, they earn their share.
- **Pool scope:** the 30% then 1% schedule is enforced only for the exact canonical hooked pool. The token cannot force another pool, CEX, OTC transfer, or direct ERC-20 transfer to use it.
- **No automatic compounding:** trading fees do not automatically deepen liquidity. A position owner must collect and deliberately add assets to a position if it wants to compound.
- **Market risk:** a $2 million FDV and $100,000-per-side liquidity plan is a reference, not a guaranteed market price. The opening buy, fees, MEV, volatile ETH/USD inputs, later trades, and concentrated order flow can move price and produce substantial impact.
- **Routing and discovery:** standards-compliant contracts do not guarantee indexing, quotes, routing, logos, or the absence of third-party scam warnings. Every intended terminal must be verified after deployment with exact-in/exact-out and both-direction tests.
- **Trust-root drift:** official deployments, platform contracts, activation state, and router configuration can change. `config/trust-roots.snapshot.json` must be refreshed at a finalized launch block. A recorded address without current code-hash and linkage proof is insufficient. The current official Uniswap registry marks Universal Router `0x06AfBA43Fd06227fA663b0DAecF536f6EaA6bf99` as latest and `0x8876789976dEcBfCbBbe364623C63652db8C0904` as historical/orphaned.
- **Platform availability:** live V4 capabilities/readiness currently report `ready`, and the public finalized feed has a published row. Those backend/read facts do not activate writes. Canonical public discovery still reports Robinhood V4 as `planned-not-deployed`, with `publicAuthorization: false`, `publicWrites: false`, `releaseReady: false`, and no released/installable V4 CLI. An API key and visible UI controls do not override that fail-closed release contract.
- **Off-contract distribution:** migration and treasury transfers happen later from the launch wallet. The token and launch initializer do not enforce recipient correctness; the package verifier, balance reconciliation, owner review, and transaction simulation are mandatory.
- **Irreversible LP operations:** locking or burning the LP NFT can permanently remove recovery options. The exact lock target, duration, ownership semantics, source verification, and post-lock onchain state must be reviewed before signing.

## Required pre-signing checks

1. Freeze the exact source revision and dependency lock; reproduce the build offline.
2. Run formatting, build/size checks, all tests, extended fuzzing, distribution verification, and an independent security review.
3. Simulate the official generated bundle against a current Robinhood Chain state; do not substitute locally invented addresses or calldata.
4. Verify `chainId == 4663`, finalized block identity, balances, nonces, every runtime code hash, PositionManager-to-PoolManager linkage, hook flag bits, constructor arguments, pool ID, and currency ordering.
5. Recompute the quote and all numeric inputs immediately before signing. Confirm the full gross ETH requirement, slippage floor, price limit, and deadline. The initializer deadline must equal the Router permit deadline, whose total lifetime is capped at 3,600 seconds; repack if the quote or wallet handoff is delayed.
6. Decode the complete owner-facing transaction. It must not include approvals, transfers, arbitrary calls, or recipients beyond the reviewed plan.
7. Keep API keys, wallet keys, seed phrases, signatures, and raw authorization tokens out of files, logs, screenshots, and chat.

## Required post-confirmation checks

Verify the transaction receipt and finality independently, then reconcile deployed bytecode, verified source, total supply, initial balances, canonical PoolKey and pool state, exact LP NFT owner/liquidity/principals, initial buy output, fee timestamps, and residual balances. Test quotes and small trades in all four swap quadrants through each intended router before publishing broad availability claims.

Treat LP locking, migration distribution, and treasury transfers as separate change-controlled operations with their own simulations and receipts. Reconcile the full one-billion-token equation after each operation.

## Reporting

No monitored private security contact is committed in this draft. Add and verify one before public release. Until then, do not publish exploitable details; contact the project through the official channels at https://programmable.market/ or https://x.com/ProgrammableHQ and request a private reporting path.
