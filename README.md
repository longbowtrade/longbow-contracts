# 🏹 Longbow Contracts

[![tests](https://github.com/longbowtrade/longbow-contracts/actions/workflows/test.yml/badge.svg)](https://github.com/longbowtrade/longbow-contracts/actions/workflows/test.yml)
[![license: MIT](https://img.shields.io/badge/license-MIT-CCFF00.svg)](LICENSE)

**`LongbowExecutor.sol` — a ~200-line permissionless executor that adds limit orders & DCA to Uniswap V2 for tokenized stocks on Robinhood Chain.**

*Aim. Set. Hit.*

This is the standalone Foundry mirror of [`longbow`](../../longbow) `packages/contracts` — published separately for easy review and audit. Funds never leave the user's wallet: orders are pre-approved allowances executed by any keeper when the Chainlink trigger condition is met.

## Layout

```
src/LongbowExecutor.sol   the executor (limit + DCA, all guards)
src/interfaces/           AggregatorV3, IERC20, IUniswapV2Router02
src/mocks/                MockERC20, MockAggregatorV3, MockV2Router
script/Deploy.s.sol       mainnet deploy against the real V2 Router02
script/SeedDemo.s.sol     full testnet demo env (router+tokens+feeds+pools)
test/                     11 tests — triggers, DCA multi-run, slippage,
                          expiry, oraclePaused, stale price, sequencer
                          down, cancel auth
```

## Build & test

```bash
forge install foundry-rs/forge-std
forge test
```

Note: `via_ir = true` is required (already set in `foundry.toml`) — the executor does not compile without it.

## Deploy

```bash
# testnet demo environment
forge script script/SeedDemo.s.sol --rpc-url robinhood_testnet --broadcast --private-key $KEY

# mainnet, against the real Uniswap V2 Router02
ROUTER=0x89e5db8b5aa49aa85ac63f691524311aeb649eba \
forge script script/Deploy.s.sol --rpc-url robinhood_mainnet --broadcast --private-key $KEY
```

## Execution guards

- Chainlink feed staleness (1h) and `oraclePaused()`
- Sequencer uptime feed + 1h grace period
- `minAmountOut` slippage bound, order expiry, reentrancy guard, swap-path validation
- **USDG is 6 decimals**, every stock token is 18
- Stock feeds are **total-return** (dividends via ERC-8056 `uiMultiplier`) — the multiplier applies to *balances*, never to feed prices
- Never hardcode the V2 pair init code hash on Robinhood Chain — resolve pairs via `factory.getPair()`

## Disclaimers

Experimental software, provided as-is, MIT licensed. Not financial advice.
