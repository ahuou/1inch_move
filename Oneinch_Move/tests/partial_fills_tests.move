module oneinch_move::partial_fills_smoke {
    use std::vector;
    use std::string::String;
    use std::hash;

    use sui::test_scenario as ts;
    use sui::tx_context::TxContext;
    use sui::clock::{Self as clock, Clock};
    use sui::transfer;
    use sui::coin::{Self as coin, TreasuryCap, Coin};

    use oneinch_move::pf_test_utils::{Self as utils, TEST_COIN};
    use oneinch_move::partial_fills;

    /// Helper: new clock in test_scenario (epoch 0, timestamp 0 -> we’ll manually advance)
    fun new_clock(ctx: &mut TxContext): Clock {
        // In test_scenario use ts::create_clock; for simple unit tests we create dummy:
        // The Sui framework exposes a test-only constructor for Clock.
        clock::new_for_testing(ctx)
    }

    /// Helper: fast forward the clock by `ms`
    fun tick_ms(clock_ref: &mut Clock, ms: u64) {
        clock::fast_forward_for_testing(clock_ref, ms)
    }

    /// Returns a (treasury, coin(amount), deposit(deposit_amount))
    fun mint_pair(
        tc: &mut TreasuryCap<TEST_COIN>,
        amount: u64,
        deposit_amount: u64,
        ctx: &mut TxContext
    ): (Coin<TEST_COIN>, Coin<TEST_COIN>) {
        let c = utils::mint_test_coin(tc, amount, ctx);
        let d = utils::mint_test_coin(tc, deposit_amount, ctx);
        (c, d)
    }

    /// === Test 1: happy path, partial fill unlocking stage 1 of 2 ===
    #[test]
    fun t_partial_fill_stage1_happy(ctx: &mut TxContext) {
        let mut tc = utils::create_treasury_cap(ctx);
        let mut clk = new_clock(ctx);

        // Build merkle over 2 leaves (stages {1,2}):
        let s1 = b"stage1_secret"; // 13 bytes
        let s2 = b"stage2_secret"; // 13 bytes
        let (root, p1, _p2) = utils::build_merkle_2(&s1, &s2);

        // Prepare coins
        let (amount_coin, deposit_coin) = mint_pair(&mut tc, 1_000_000, 100_000, ctx);

        // Lock params
        let withdrawal_ms = 100;           // t >= 100 -> maker may withdraw
        let public_withdrawal_ms = 10_000; // t >= 10k -> anyone can withdraw
        let cancellation_ms = 20_000;
        let public_cancellation_ms = 40_000;
        let maker = @0x111;
        let taker = @0x0;                  // anyone
        let refund = @0x222;
        let target = @0x333;
        let allow_partial = true;
        let allow_multiple = true;
        let min_partial = 200_000;         // must withdraw at least this much
        let secret_len = 13;
        let order_hash = String::utf8(b"eth_order#A");

        // now=0, fast-forward into maker-only withdrawal window
        tick_ms(&mut clk, 100);

        // Create lock
        partial_fills::create_lock_object<TEST_COIN>(
            &clk,
            withdrawal_ms, public_withdrawal_ms,
            cancellation_ms, public_cancellation_ms,
            root, /* total_stages = */ 2,
            maker, taker, refund, target,
            secret_len,
            amount_coin, deposit_coin,
            allow_partial, allow_multiple, min_partial,
            order_hash.clone(),
            ctx
        );

        // Fetch the shared lock object id from events, then take it from shared storage.
        // In unit tests, we can extract it via test_scenario’s “take_shared” macro:
        let mut scenario = ts::begin(ctx);
        let lock_id = ts::last_emitted_id<partial_fills::NewLockEvent>(&mut scenario, ctx);
        let mut lock = ts::take_shared<partial_fills::LockObject<TEST_COIN>>(&mut scenario, lock_id);

        // Also create a shared UsedSecretsRegistry for the global replay protection.
        // test-only "public entry" exists in your module (init_registry)
        partial_fills::init_registry(ctx);
        let reg_id = ts::last_emitted_shared<partial_fills::UsedSecretsRegistry>(&mut scenario, ctx);
        let mut registry = ts::borrow_shared_mut<partial_fills::UsedSecretsRegistry>(&mut scenario, reg_id);

        // Partial withdraw “stage 1”:
        // threshold for stage 1 of 2 = 50% of initial -> 500_000
        // We withdraw 600_000 (>= min_partial 200k, >= 50%).
        partial_fills::withdraw_partial<TEST_COIN>(
            lock,
            &mut registry,
            &clk,
            *s1,           // secret
            p1,            // proof for stage_index=1
            /* stage_index */ 1,
            /* amount */ 600_000,
            ctx
        );

        // Lock is re-shared internally with remaining ~400_000.
        // The claim transfers the piece to `target` and pro-rata deposit to claimer (maker in this window).
        // (You can add explicit balance checks with ts helpers if desired.)
        scenario.end();
    }

    /// === Test 2: secret length mismatch reverts ===
    #[test, expected_failure(abort_code = 1)] // ESecretLengthWrong
    fun t_secret_length_mismatch(ctx: &mut TxContext) {
        let mut tc = utils::create_treasury_cap(ctx);
        let mut clk = new_clock(ctx);

        let s1 = b"abcd";
        let s2 = b"efgh";
        let (root, p1, _p2) = utils::build_merkle_2(&s1, &s2);

        let (amount_coin, deposit_coin) = mint_pair(&mut tc, 1000, 100, ctx);
        tick_ms(&mut clk, 100);

        partial_fills::create_lock_object<TEST_COIN>(
            &clk, 100, 10_000, 20_000, 40_000,
            root, 2,
            @0xA, @0x0, @0xB, @0xC,
            /* secret_length */ 5,     // mismatch: s1.len() = 4
            amount_coin, deposit_coin,
            /* allow_partial */ true, /* allow_multiple */ true, /* min_partial */ 100,
            String::utf8(b"hash#B"),
            ctx
        );

        let mut scenario = ts::begin(ctx);
        let lock_id = ts::last_emitted_id<partial_fills::NewLockEvent>(&mut scenario, ctx);
        let mut lock = ts::take_shared<partial_fills::LockObject<TEST_COIN>>(&mut scenario, lock_id);

        partial_fills::init_registry(ctx);
        let reg_id = ts::last_emitted_shared<partial_fills::UsedSecretsRegistry>(&mut scenario, ctx);
        let mut registry = ts::borrow_shared_mut<partial_fills::UsedSecretsRegistry>(&mut scenario, reg_id);

        // Fails on secret length check
        partial_fills::withdraw_partial<TEST_COIN>(
            lock, &mut registry, &clk,
            *s1, p1, 1, 100, ctx
        );
        scenario.end();
    }

    /// === Test 3: taker restriction enforced ===
    #[test, expected_failure(abort_code = 101)] // E_NOT_TAKER
    fun t_taker_only(ctx: &mut TxContext) {
        let mut tc = utils::create_treasury_cap(ctx);
        let mut clk = new_clock(ctx);

        let s1 = b"s1";
        let s2 = b"s2";
        let (root, p1, _p2) = utils::build_merkle_2(&s1, &s2);

        let (amount_coin, deposit_coin) = mint_pair(&mut tc, 10_000, 1_000, ctx);
        tick_ms(&mut clk, 100);

        // taker is restricted to @0xDEAD; test sender != @0xDEAD
        partial_fills::create_lock_object<TEST_COIN>(
            &clk, 100, 10_000, 20_000, 40_000,
            root, 2,
            /* maker */ @0x111, /* taker */ @0xDEAD, /* refund */ @0x2, /* target */ @0x3,
            /* secret_len */ 2,
            amount_coin, deposit_coin,
            true, true, 1_000,
            String::utf8(b"hash#C"),
            ctx
        );

        let mut scenario = ts::begin(ctx);
        let lock_id = ts::last_emitted_id<partial_fills::NewLockEvent>(&mut scenario, ctx);
        let mut lock = ts::take_shared<partial_fills::LockObject<TEST_COIN>>(&mut scenario, lock_id);

        partial_fills::init_registry(ctx);
        let reg_id = ts::last_emitted_shared<partial_fills::UsedSecretsRegistry>(&mut scenario, ctx);
        let mut registry = ts::borrow_shared_mut<partial_fills::UsedSecretsRegistry>(&mut scenario, reg_id);

        // Not called by taker -> abort
        partial_fills::withdraw_partial<TEST_COIN>(
            lock, &mut registry, &clk, *s1, p1, 1, 2_000, ctx
        );
        scenario.end();
    }

    /// === Test 4: secret reuse is rejected globally ===
    #[test, expected_failure(abort_code = 103)] // E_SECRET_ALREADY_USED
    fun t_secret_reuse_rejected(ctx: &mut TxContext) {
        let mut tc = utils::create_treasury_cap(ctx);
        let mut clk = new_clock(ctx);

        let s1 = b"reused";
        let s2 = b"other";
        let (root, p1, _p2) = utils::build_merkle_2(&s1, &s2);
        let (amount_coin, deposit_coin) = mint_pair(&mut tc, 1000, 100, ctx);
        tick_ms(&mut clk, 100);

        partial_fills::init_registry(ctx);
        let mut scenario = ts::begin(ctx);
        let reg_id = ts::last_emitted_shared<partial_fills::UsedSecretsRegistry>(&mut scenario, ctx);
        let mut registry = ts::borrow_shared_mut<partial_fills::UsedSecretsRegistry>(&mut scenario, reg_id);

        // First order (consume s1)
        partial_fills::create_lock_object<TEST_COIN>(
            &clk, 100, 10_000, 20_000, 40_000,
            root, 2, @0x1, @0x0, @0x2, @0x3,
            /* secret_len */ 6,
            amount_coin, deposit_coin,
            true, true, 100,
            String::utf8(b"hash#D"),
            ctx
        );
        let lock1_id = ts::last_emitted_id<partial_fills::NewLockEvent>(&mut scenario, ctx);
        let lock1 = ts::take_shared<partial_fills::LockObject<TEST_COIN>>(&mut scenario, lock1_id);
        partial_fills::withdraw_partial<TEST_COIN>(lock1, &mut registry, &clk, *s1, p1, 1, 600, ctx);
        // Lock1 re-shared automatically with remainder

        // Second order attempts to reuse the same s1 -> rejected
        let (c2, d2) = mint_pair(&mut tc, 1000, 100, ctx);
        let (root2, p1b, _p2b) = utils::build_merkle_2(&s1, &s2);
        partial_fills::create_lock_object<TEST_COIN>(
            &clk, 100, 10_000, 20_000, 40_000,
            root2, 2, @0x10, @0x0, @0x20, @0x30,
            6, c2, d2, true, true, 100, String::utf8(b"hash#E"), ctx
        );

        let lock2_id = ts::last_emitted_id<partial_fills::NewLockEvent>(&mut scenario, ctx);
        let lock2 = ts::take_shared<partial_fills::LockObject<TEST_COIN>>(&mut scenario, lock2_id);

        // Should abort with E_SECRET_ALREADY_USED
        partial_fills::withdraw_partial<TEST_COIN>(lock2, &mut registry, &clk, *s1, p1b, 1, 600, ctx);
        scenario.end();
    }

    /// === Test 5: cancel by maker before public cancellation window ===
    #[test]
    fun t_maker_cancel(ctx: &mut TxContext) {
        let mut tc = utils::create_treasury_cap(ctx);
        let mut clk = new_clock(ctx);

        let s1 = b"a";
        let s2 = b"b";
        let (root, _p1, _p2) = utils::build_merkle_2(&s1, &s2);
        let (amount_coin, deposit_coin) = mint_pair(&mut tc, 1000, 100, ctx);

        // windows: maker-only cancel at t >= 200, public cancel at t >= 400
        partial_fills::create_lock_object<TEST_COIN>(
            &clk, 100, 10_000, 200, 400,
            root, 2, @0xAB, @0x0, @0xCD, @0xEF,
            /* secret_len */ 1,
            amount_coin, deposit_coin,
            true, true, 100, String::utf8(b"hash#F"), ctx
        );

        tick_ms(&mut clk, 200); // in maker-only cancel window

        let mut scenario = ts::begin(ctx);
        let lock_id = ts::last_emitted_id<partial_fills::NewLockEvent>(&mut scenario, ctx);
        let lock = ts::take_shared<partial_fills::LockObject<TEST_COIN>>(&mut scenario, lock_id);

        partial_fills::cancel<TEST_COIN>(lock, &clk, ctx);
        scenario.end();

        // If you want, you can assert LockCancelledEvent & SafetyDepositClaimedEvent with ts APIs
        // e.g. by fetching last events and verifying fields match.
    }
}