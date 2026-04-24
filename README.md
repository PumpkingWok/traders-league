```text
████████╗██████╗  █████╗ ██████╗ ███████╗██████╗ ███████╗
╚══██╔══╝██╔══██╗██╔══██╗██╔══██╗██╔════╝██╔══██╗██╔════╝
   ██║   ██████╔╝███████║██║  ██║█████╗  ██████╔╝███████╗
   ██║   ██╔══██╗██╔══██║██║  ██║██╔══╝  ██╔══██╗╚════██║
   ██║   ██║  ██║██║  ██║██████╔╝███████╗██║  ██║███████║
   ╚═╝   ╚═╝  ╚═╝╚═╝  ╚═╝╚═════╝ ╚══════╝╚═╝  ╚═╝╚══════╝

██╗     ███████╗ █████╗  ██████╗ ██╗   ██╗███████╗
██║     ██╔════╝██╔══██╗██╔════╝ ██║   ██║██╔════╝
██║     █████╗  ███████║██║  ███╗██║   ██║█████╗
██║     ██╔══╝  ██╔══██║██║   ██║██║   ██║██╔══╝
███████╗███████╗██║  ██║╚██████╔╝╚██████╔╝███████╗
╚══════╝╚══════╝╚═╝  ╚═╝ ╚═════╝  ╚═════╝ ╚══════╝
```

# Traders League

Traders League is an on-chain virtual trading game.

Players enter a match with the same buy-in. When the match starts, each player receives an equal virtual portfolio and can trade whitelisted assets using on-chain prices. At the end of the match, the portfolio with the highest USD value wins the pot.

## How the Virtual Game Works

1. A match is created with:
- buy-in amount
- duration
- allowed trading tokens
- optional reservation for a specific opponent

2. Players join by depositing buy-in tokens into the contract.

3. When both players are present, the match starts and each player receives:
- `100,000` virtual USD

4. During the match, players can perform virtual swaps:
- token `0` = virtual USD
- swaps can be single or batched
- each swap applies a game trading fee of `0.3%`

5. After `endTime`, anyone can conclude the match:
- each portfolio is marked to market in virtual USD
- the portfolio with the higher virtual USD total wins
- a tie returns both buy-ins without charging platform fees

6. Payout:
- winner receives `2 * buyIn - platformFee`
- platform fee is configurable up to `MAX_PLATFORM_FEE`

## Hyperliquid Settlement Note

For the Hyperliquid version, settlement does **not** use historical spot prices at `endTime`.

`HyperDuel.sol` can only read the current spot price from Hyperliquid precompiles at the moment `concludeMatch()` is called.

This means:
- trading stops at `endTime`
- final valuation is computed using current spot prices at settlement time
- if settlement happens later, the result can differ from the theoretical portfolio value at exact `endTime`

So the final outcome may include a discrepancy between:
- portfolio value at match end
- portfolio value at conclusion time

## Smart Contracts

- `src/Duel.sol`  
Core game engine: match lifecycle, virtual balances, swaps, settlement, and fee accounting.

- `src/HyperDuel.sol`  
Hyperliquid-specific extension. Reads:
- token metadata from precompile `0x...080C`
- spot prices from precompile `0x...0808`

## Match Lifecycle

- `TO_START`: match created, waiting for players
- `ONGOING`: started, trading enabled until `endTime`
- `FINISHED`: concluded and paid out
- `REMOVED`: reserved match canceled before start

## Local Development

### Requirements

- [Foundry](https://book.getfoundry.sh/getting-started/installation)

### Build

```bash
forge build
```

### Test

```bash
forge test
```

### Run Specific Test File

```bash
forge test --match-path test/HyperDuel.sol -vv
```