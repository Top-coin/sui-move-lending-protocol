# Lending Protocol

A collateralized lending protocol on Sui supporting deposits, borrows, and liquidations with dynamic interest rates.

## Features

- **Deposits**: Earn interest on deposited assets
- **Borrowing**: Borrow against collateral
- **Dynamic Rates**: Interest rates based on utilization
- **Liquidations**: Incentivized liquidation of unhealthy positions
- **Multi-asset**: Support for multiple lending markets
- **Oracle Integration**: Price feeds for collateral valuation

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                      Lending Protocol                       │
├─────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────┐         │
│  │   Market A  │  │   Market B  │  │   Market C  │   ...   │
│  │   (SUI)     │  │   (USDC)    │  │   (ETH)     │         │
│  └─────────────┘  └─────────────┘  └─────────────┘         │
├─────────────────────────────────────────────────────────────┤
│                      Price Oracle                           │
└─────────────────────────────────────────────────────────────┘
```

## Key Parameters

| Parameter | Value |
|-----------|-------|
| Max LTV | 80% |
| Liquidation Threshold | 85% |
| Liquidation Bonus | 5% |
| Reserve Factor | Configurable |

## Interest Rate Model

```
if utilization <= optimal:
    borrow_rate = utilization * slope1 / optimal
else:
    borrow_rate = slope1 + (utilization - optimal) * slope2 / (1 - optimal)
```

## Usage

### Deposit
```move
let position = lending::deposit(market, coin, clock, ctx);
```

### Borrow
```move
let (position, borrowed) = lending::borrow(
    collateral_market,
    borrow_market,
    oracle,
    collateral_coin,
    borrow_amount,
    clock,
    ctx
);
```

### Repay
```move
let collateral = lending::repay(
    collateral_market,
    borrow_market,
    position,
    repay_coin,
    clock,
    ctx
);
```

### Liquidate
```move
let seized = lending::liquidate(
    collateral_market,
    borrow_market,
    oracle,
    position,
    repay_coin,
    clock,
    ctx
);
```

## Build & Deploy

```bash
sui move build
sui client publish --gas-budget 100000000
```
