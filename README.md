![Programmable](https://raw.githubusercontent.com/programmablehq/PROGRAMMABLE/903b3741a6cd2981788cb09c039f0c47994c5d62/public/brand/programmable-cover.png)

# Programmable V4 token

Source for Programmable's fixed supply V4 token, canonical-pool launch hook and atomic initializer on Robinhood Chain. The repository also contains the original launch configuration, build tooling and post-launch distribution records.

## Token and market

| Field | Value |
| --- | --- |
| Network | Robinhood Chain Mainnet, chain ID `4663` |
| Token | [`0xC60bA256B44334A0Cd2C7242E98B88f031abB006`](https://robinhoodchain.blockscout.com/token/0xC60bA256B44334A0Cd2C7242E98B88f031abB006) |
| Name and symbol | Programmable, V4 |
| Supply | 1,000,000,000 V4, 18 decimals |
| Canonical market | [V4 / native ETH](https://dexscreener.com/robinhood/0x3df16f271060e4941c0386047def159f42e629dc0455db623c5b363eeacbcc1d) |
| Hook | [`0x720e649549F7BC2118aCBA9F4C9ae6fCC7586080`](https://robinhoodchain.blockscout.com/address/0x720e649549F7BC2118aCBA9F4C9ae6fCC7586080) |

The token constructor mints 950,000,000 V4 to `INITIAL_HOLDER` and 50,000,000 V4 to the initializer. There is no later mint, owner, pause or transfer-tax control. The initializer creates the pool, mints its initial full-range liquidity position and completes the launch wallet's initial buy atomically. Distribution and later liquidity custody are separate operations.

## Liquidity fees and custody

The canonical pool uses a 30% LP fee during its first 30 seconds and 1% afterwards. This fee applies to swaps in that pool, not ordinary token transfers or every other pool that might hold V4. Active liquidity providers earn their proportional shares in the input asset: ETH on buys and V4 on sells.

The main LP NFT, `1708785`, is held by the [PositionFeesForwarder locker](https://robinhoodchain.blockscout.com/address/0x9f9424BbCCe8a865f70155fe40Fb22A103eBEc63), with its withdrawal lock set to the maximum `uint256` block number. Fee collection leaves the position locked and forwards proceeds to `0x39544A7023081B56D7405c1af0bFaf72da7e24F6`. The initializer's original transfer of the NFT to the launch wallet is not its subsequent custody state.

## Revenue and burns

Programmable's allocation policy assigns half of net platform revenue to daily V4 buybacks and burns and half to the treasury. Collected V4 from the project's LP fees is also assigned to daily burns. Creator and module author rewards are separate liabilities and are excluded from the platform allocation.

V4 burns are transfers to `0x000000000000000000000000000000000000dEaD`. They remove tokens from circulation without reducing the ERC-20 `totalSupply`, because this token does not expose a supply-reducing burn function. [Tokenomics](https://programmable.market/docs/v4-token) explains the policy and [Dune](https://dune.com/programmablehq/analytics) records observed burns and fees. The policy is separate from an individual executed claim, purchase or burn transaction.

## Repository map

| Path | Contents |
| --- | --- |
| [src/ProgrammableToken.sol](src/ProgrammableToken.sol) | Fixed supply ERC-20 |
| [src/ProgrammableLaunchFeeHook.sol](src/ProgrammableLaunchFeeHook.sol) | Canonical-pool guard and LP-fee schedule |
| [src/ProgrammableLaunchInitializer.sol](src/ProgrammableLaunchInitializer.sol) | Atomic pool initialization, LP mint and initial buy |
| [test/](test) | Contract and integration tests |
| [config/](config) | Original launch intent, supply plan and recorded trust roots |
| [scripts/](scripts) | Reproducible compiler and package tooling |
| [distribution/](distribution/README.md) | Post-launch migration allocation package and verifier |
| [metadata/](metadata) | Token metadata and assets |

Configuration snapshots preserve the conditions under which they were authored. Read the actual chain state and the selected release evidence before reusing a deployment address or launch input. A launch-intent file with unresolved values is not the current token directory.

## Local verification

Use Node.js 24+, Foundry and the pinned dependencies:

```sh
npm ci --ignore-scripts
npm run build:pack-artifacts
npm run fmt:check
npm run build:production
npm test
npm run verify:distribution
```

For a deeper contract change, run `npm run test:fuzz`. Local checks do not establish an external audit, a deployed bytecode match or a trading route. Read [SECURITY.md](SECURITY.md) and the distribution instructions before changing or executing an operation.

## Links and license

[Platform](https://programmable.market) · [Docs](https://programmable.market/docs) · [Discord](https://discord.com/invite/programmable) · [X](https://x.com/ProgrammableHQ) · [Dune](https://dune.com/programmablehq/analytics)

This repository is licensed under [MIT](LICENSE).
