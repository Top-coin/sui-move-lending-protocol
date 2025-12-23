/// Lending Protocol - Collateralized lending on Sui
module lending_protocol::lending {
    use sui::object::{Self, UID, ID};
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::tx_context::{Self, TxContext};
    use sui::transfer;
    use sui::event;
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};

    // ======== Constants ========
    const PRECISION: u128 = 1_000_000_000_000; // 1e12
    const SECONDS_PER_YEAR: u64 = 31536000;
    const MAX_LTV: u64 = 8000;  // 80% in BPS
    const LIQUIDATION_THRESHOLD: u64 = 8500; // 85% in BPS
    const LIQUIDATION_BONUS: u64 = 500; // 5% bonus for liquidators
    const BPS: u64 = 10000;

    // ======== Errors ========
    const EZeroAmount: u64 = 0;
    const EInsufficientCollateral: u64 = 1;
    const EInsufficientLiquidity: u64 = 2;
    const EPositionHealthy: u64 = 3;
    const EExceedsLTV: u64 = 4;
    const ENotOwner: u64 = 5;
    const EInvalidOracle: u64 = 6;
    const EMarketPaused: u64 = 7;

    // ======== Types ========

    /// Lending market for a specific asset
    public struct LendingMarket<phantom Asset> has key {
        id: UID,
        total_deposits: Balance<Asset>,
        total_borrows: u64,
        deposit_rate: u64,     // Annual rate in BPS
        borrow_rate: u64,      // Annual rate in BPS
        utilization_optimal: u64,
        rate_slope1: u64,
        rate_slope2: u64,
        reserve_factor: u64,
        last_update_time: u64,
        borrow_index: u128,
        supply_index: u128,
        reserves: u64,
        paused: bool,
    }

    /// Price oracle for asset pricing
    public struct PriceOracle has key {
        id: UID,
        prices: Table<ID, u64>, // market_id -> price in USD (8 decimals)
        admin: address,
    }

    /// User deposit position
    public struct DepositPosition<phantom Asset> has key, store {
        id: UID,
        market_id: ID,
        owner: address,
        shares: u64,
        deposit_index: u128,
    }

    /// User borrow position
    public struct BorrowPosition<phantom Collateral, phantom Borrowed> has key, store {
        id: UID,
        collateral_market_id: ID,
        borrow_market_id: ID,
        owner: address,
        collateral_amount: u64,
        borrow_shares: u64,
        borrow_index: u128,
    }

    /// Market admin capability
    public struct MarketAdminCap has key, store {
        id: UID,
    }

    // ======== Events ========

    public struct MarketCreated has copy, drop {
        market_id: ID,
    }

    public struct Deposit has copy, drop {
        market_id: ID,
        user: address,
        amount: u64,
        shares: u64,
    }

    public struct Withdraw has copy, drop {
        market_id: ID,
        user: address,
        amount: u64,
        shares: u64,
    }

    public struct Borrow has copy, drop {
        collateral_market_id: ID,
        borrow_market_id: ID,
        user: address,
        collateral_amount: u64,
        borrow_amount: u64,
    }

    public struct Repay has copy, drop {
        market_id: ID,
        user: address,
        amount: u64,
    }

    public struct Liquidation has copy, drop {
        borrower: address,
        liquidator: address,
        collateral_seized: u64,
        debt_repaid: u64,
    }

    // ======== Init ========

    fun init(ctx: &mut TxContext) {
        let oracle = PriceOracle {
            id: object::new(ctx),
            prices: table::new(ctx),
            admin: tx_context::sender(ctx),
        };
        transfer::share_object(oracle);

        transfer::transfer(
            MarketAdminCap { id: object::new(ctx) },
            tx_context::sender(ctx)
        );
    }

    // ======== Market Functions ========

    /// Create a new lending market
    public fun create_market<Asset>(
        _admin: &MarketAdminCap,
        utilization_optimal: u64,
        rate_slope1: u64,
        rate_slope2: u64,
        reserve_factor: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let market = LendingMarket<Asset> {
            id: object::new(ctx),
            total_deposits: balance::zero(),
            total_borrows: 0,
            deposit_rate: 0,
            borrow_rate: rate_slope1,
            utilization_optimal,
            rate_slope1,
            rate_slope2,
            reserve_factor,
            last_update_time: clock::timestamp_ms(clock) / 1000,
            borrow_index: (PRECISION as u128),
            supply_index: (PRECISION as u128),
            reserves: 0,
            paused: false,
        };

        event::emit(MarketCreated {
            market_id: object::id(&market),
        });

        transfer::share_object(market);
    }

    /// Deposit assets into the lending pool
    public fun deposit<Asset>(
        market: &mut LendingMarket<Asset>,
        deposit_coin: Coin<Asset>,
        clock: &Clock,
        ctx: &mut TxContext
    ): DepositPosition<Asset> {
        assert!(!market.paused, EMarketPaused);

        let amount = coin::value(&deposit_coin);
        assert!(amount > 0, EZeroAmount);

        accrue_interest(market, clock);

        // Calculate shares based on current supply with interest
        let total_deposits = balance::value(&market.total_deposits);
        let total_with_interest = get_total_supply_with_interest(market);
        let shares = if (total_deposits == 0 || total_with_interest == 0) {
            amount
        } else {
            // shares = amount * total_shares / total_value_with_interest
            (amount * total_deposits) / total_with_interest
        };

        balance::join(&mut market.total_deposits, coin::into_balance(deposit_coin));

        event::emit(Deposit {
            market_id: object::id(market),
            user: tx_context::sender(ctx),
            amount,
            shares,
        });

        DepositPosition {
            id: object::new(ctx),
            market_id: object::id(market),
            owner: tx_context::sender(ctx),
            shares,
            deposit_index: market.supply_index,
        }
    }

    /// Withdraw deposited assets
    public fun withdraw<Asset>(
        market: &mut LendingMarket<Asset>,
        position: DepositPosition<Asset>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<Asset> {
        let DepositPosition { id, market_id: _, owner, shares, deposit_index } = position;
        assert!(owner == tx_context::sender(ctx), ENotOwner);

        accrue_interest(market, clock);

        // Calculate amount with accrued interest
        let amount = calculate_deposit_value(market, shares, deposit_index);

        assert!(balance::value(&market.total_deposits) >= amount, EInsufficientLiquidity);

        event::emit(Withdraw {
            market_id: object::id(market),
            user: tx_context::sender(ctx),
            amount,
            shares,
        });

        object::delete(id);
        coin::from_balance(balance::split(&mut market.total_deposits, amount), ctx)
    }

    /// Borrow assets using collateral
    public fun borrow<Collateral, Borrowed>(
        collateral_market: &mut LendingMarket<Collateral>,
        borrow_market: &mut LendingMarket<Borrowed>,
        oracle: &PriceOracle,
        collateral_coin: Coin<Collateral>,
        borrow_amount: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ): (BorrowPosition<Collateral, Borrowed>, Coin<Borrowed>) {
        assert!(!collateral_market.paused && !borrow_market.paused, EMarketPaused);
        assert!(borrow_amount > 0, EZeroAmount);

        accrue_interest(collateral_market, clock);
        accrue_interest(borrow_market, clock);

        let collateral_amount = coin::value(&collateral_coin);
        assert!(collateral_amount > 0, EZeroAmount);

        // Get prices and check LTV
        let collateral_price = get_price(oracle, object::id(collateral_market));
        let borrow_price = get_price(oracle, object::id(borrow_market));

        let collateral_value = (collateral_amount as u128) * (collateral_price as u128);
        let borrow_value = (borrow_amount as u128) * (borrow_price as u128);

        let ltv = (((borrow_value * (BPS as u128)) / collateral_value) as u64);
        assert!(ltv <= MAX_LTV, EExceedsLTV);

        // Check liquidity
        assert!(balance::value(&borrow_market.total_deposits) >= borrow_amount, EInsufficientLiquidity);

        // Calculate borrow shares based on current borrows with interest
        let total_borrows_with_interest = get_total_borrows_with_interest(borrow_market);
        let borrow_shares = if (borrow_market.total_borrows == 0 || total_borrows_with_interest == 0) {
            borrow_amount
        } else {
            // shares = amount * total_shares / total_value_with_interest
            (borrow_amount * borrow_market.total_borrows) / total_borrows_with_interest
        };

        // Store collateral
        balance::join(&mut collateral_market.total_deposits, coin::into_balance(collateral_coin));
        borrow_market.total_borrows = borrow_market.total_borrows + borrow_amount;

        let position = BorrowPosition<Collateral, Borrowed> {
            id: object::new(ctx),
            collateral_market_id: object::id(collateral_market),
            borrow_market_id: object::id(borrow_market),
            owner: tx_context::sender(ctx),
            collateral_amount,
            borrow_shares,
            borrow_index: borrow_market.borrow_index,
        };

        let borrowed_coin = coin::from_balance(
            balance::split(&mut borrow_market.total_deposits, borrow_amount),
            ctx
        );

        event::emit(Borrow {
            collateral_market_id: object::id(collateral_market),
            borrow_market_id: object::id(borrow_market),
            user: tx_context::sender(ctx),
            collateral_amount,
            borrow_amount,
        });

        update_rates(borrow_market);

        (position, borrowed_coin)
    }

    /// Repay borrowed assets
    public fun repay<Collateral, Borrowed>(
        collateral_market: &mut LendingMarket<Collateral>,
        borrow_market: &mut LendingMarket<Borrowed>,
        position: BorrowPosition<Collateral, Borrowed>,
        repay_coin: Coin<Borrowed>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<Collateral> {
        let BorrowPosition {
            id,
            collateral_market_id: _,
            borrow_market_id: _,
            owner,
            collateral_amount,
            borrow_shares,
            borrow_index,
        } = position;

        assert!(owner == tx_context::sender(ctx), ENotOwner);

        accrue_interest(borrow_market, clock);

        let debt = calculate_borrow_value(borrow_market, borrow_shares, borrow_index);
        let repay_amount = coin::value(&repay_coin);

        assert!(repay_amount >= debt, EZeroAmount);

        // Update market state
        borrow_market.total_borrows = if (borrow_market.total_borrows >= debt) {
            borrow_market.total_borrows - debt
        } else {
            0
        };

        balance::join(&mut borrow_market.total_deposits, coin::into_balance(repay_coin));

        event::emit(Repay {
            market_id: object::id(borrow_market),
            user: tx_context::sender(ctx),
            amount: debt,
        });

        update_rates(borrow_market);

        object::delete(id);

        // Return collateral
        coin::from_balance(
            balance::split(&mut collateral_market.total_deposits, collateral_amount),
            ctx
        )
    }

    /// Liquidate an undercollateralized position
    public fun liquidate<Collateral, Borrowed>(
        collateral_market: &mut LendingMarket<Collateral>,
        borrow_market: &mut LendingMarket<Borrowed>,
        oracle: &PriceOracle,
        position: BorrowPosition<Collateral, Borrowed>,
        repay_coin: Coin<Borrowed>,
        clock: &Clock,
        ctx: &mut TxContext
    ): Coin<Collateral> {
        accrue_interest(collateral_market, clock);
        accrue_interest(borrow_market, clock);

        let BorrowPosition {
            id,
            collateral_market_id: _,
            borrow_market_id: _,
            owner,
            collateral_amount,
            borrow_shares,
            borrow_index,
        } = position;

        // Check if position is liquidatable
        let collateral_price = get_price(oracle, object::id(collateral_market));
        let borrow_price = get_price(oracle, object::id(borrow_market));

        let debt = calculate_borrow_value(borrow_market, borrow_shares, borrow_index);
        let collateral_value = (collateral_amount as u128) * (collateral_price as u128);
        let debt_value = (debt as u128) * (borrow_price as u128);

        let health_factor = (((collateral_value * (LIQUIDATION_THRESHOLD as u128)) / debt_value) as u64);
        assert!(health_factor < BPS, EPositionHealthy);

        let repay_amount = coin::value(&repay_coin);

        // Calculate collateral to seize (with bonus)
        let seize_value = (repay_amount as u128) * (borrow_price as u128);
        let seize_amount_base = ((seize_value / (collateral_price as u128)) as u64);
        let seize_amount = seize_amount_base + (seize_amount_base * LIQUIDATION_BONUS) / BPS;

        let seize_amount = if (seize_amount > collateral_amount) {
            collateral_amount
        } else {
            seize_amount
        };

        // Update borrow market
        borrow_market.total_borrows = if (borrow_market.total_borrows >= repay_amount) {
            borrow_market.total_borrows - repay_amount
        } else {
            0
        };

        balance::join(&mut borrow_market.total_deposits, coin::into_balance(repay_coin));

        event::emit(Liquidation {
            borrower: owner,
            liquidator: tx_context::sender(ctx),
            collateral_seized: seize_amount,
            debt_repaid: repay_amount,
        });

        update_rates(borrow_market);

        object::delete(id);

        // Transfer seized collateral to liquidator
        coin::from_balance(
            balance::split(&mut collateral_market.total_deposits, seize_amount),
            ctx
        )
    }

    // ======== Oracle Functions ========

    /// Update asset price (oracle admin only)
    public fun update_price(
        oracle: &mut PriceOracle,
        market_id: ID,
        price: u64,
        ctx: &TxContext
    ) {
        assert!(oracle.admin == tx_context::sender(ctx), EInvalidOracle);

        if (table::contains(&oracle.prices, market_id)) {
            *table::borrow_mut(&mut oracle.prices, market_id) = price;
        } else {
            table::add(&mut oracle.prices, market_id, price);
        };
    }

    fun get_price(oracle: &PriceOracle, market_id: ID): u64 {
        assert!(table::contains(&oracle.prices, market_id), EInvalidOracle);
        *table::borrow(&oracle.prices, market_id)
    }

    // ======== Internal Functions ========

    fun accrue_interest<Asset>(market: &mut LendingMarket<Asset>, clock: &Clock) {
        let current_time = clock::timestamp_ms(clock) / 1000;
        let time_elapsed = current_time - market.last_update_time;

        if (time_elapsed == 0) return;

        let borrow_rate_per_second = (market.borrow_rate as u128) / (SECONDS_PER_YEAR as u128) / (BPS as u128);
        let interest_factor = borrow_rate_per_second * (time_elapsed as u128);

        // Update borrow index
        market.borrow_index = market.borrow_index + 
            (market.borrow_index * interest_factor) / PRECISION;

        // Update supply index (net of reserves)
        let utilization = get_utilization(market);
        let supply_rate = (market.borrow_rate * utilization * (BPS - market.reserve_factor)) / (BPS * BPS);
        let supply_rate_per_second = (supply_rate as u128) / (SECONDS_PER_YEAR as u128) / (BPS as u128);
        let supply_interest = supply_rate_per_second * (time_elapsed as u128);

        market.supply_index = market.supply_index +
            (market.supply_index * supply_interest) / PRECISION;

        market.last_update_time = current_time;
    }

    fun update_rates<Asset>(market: &mut LendingMarket<Asset>) {
        let utilization = get_utilization(market);

        // Guard against division by zero
        if (market.utilization_optimal == 0) {
            market.borrow_rate = market.rate_slope1;
        } else if (utilization <= market.utilization_optimal) {
            market.borrow_rate = (utilization * market.rate_slope1) / market.utilization_optimal;
        } else {
            let excess_utilization = utilization - market.utilization_optimal;
            let base_rate = market.rate_slope1;
            // Guard against division by zero when utilization_optimal == BPS
            let denominator = BPS - market.utilization_optimal;
            let excess_rate = if (denominator == 0) {
                market.rate_slope2
            } else {
                (excess_utilization * market.rate_slope2) / denominator
            };
            market.borrow_rate = base_rate + excess_rate;
        };

        market.deposit_rate = (market.borrow_rate * utilization * (BPS - market.reserve_factor)) / (BPS * BPS);
    }

    fun get_utilization<Asset>(market: &LendingMarket<Asset>): u64 {
        let total_deposits = balance::value(&market.total_deposits);
        if (total_deposits == 0) {
            0
        } else {
            (market.total_borrows * BPS) / total_deposits
        }
    }

    fun get_total_supply_with_interest<Asset>(market: &LendingMarket<Asset>): u64 {
        let base = balance::value(&market.total_deposits);
        if (base == 0) {
            return 0
        };
        // Apply supply index to get interest-adjusted value
        let adjusted = ((base as u128) * market.supply_index) / PRECISION;
        (adjusted as u64)
    }

    fun get_total_borrows_with_interest<Asset>(market: &LendingMarket<Asset>): u64 {
        if (market.total_borrows == 0) {
            return 0
        };
        // Apply borrow index to get interest-adjusted value
        let adjusted = ((market.total_borrows as u128) * market.borrow_index) / PRECISION;
        (adjusted as u64)
    }

    fun calculate_deposit_value<Asset>(
        market: &LendingMarket<Asset>,
        shares: u64,
        deposit_index: u128
    ): u64 {
        let total_deposits = balance::value(&market.total_deposits);
        if (total_deposits == 0 || shares == 0) {
            return shares
        };
        // Calculate value based on index growth since deposit
        // value = shares * current_index / deposit_index
        let value = ((shares as u128) * market.supply_index) / deposit_index;
        (value as u64)
    }

    fun calculate_borrow_value<Asset>(
        market: &LendingMarket<Asset>,
        borrow_shares: u64,
        original_index: u128
    ): u64 {
        if (borrow_shares == 0 || original_index == 0) {
            return borrow_shares
        };
        // Calculate value based on index growth since borrow
        // value = shares * current_index / original_index
        let accrued = (market.borrow_index * (borrow_shares as u128)) / original_index;
        (accrued as u64)
    }

    // ======== View Functions ========

    public fun get_market_info<Asset>(market: &LendingMarket<Asset>): (u64, u64, u64, u64) {
        (
            balance::value(&market.total_deposits),
            market.total_borrows,
            market.deposit_rate,
            market.borrow_rate
        )
    }

    public fun get_position_debt<Collateral, Borrowed>(
        market: &LendingMarket<Borrowed>,
        position: &BorrowPosition<Collateral, Borrowed>
    ): u64 {
        calculate_borrow_value(market, position.borrow_shares, position.borrow_index)
    }
}
