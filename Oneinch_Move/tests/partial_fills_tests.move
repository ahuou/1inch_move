module oneinch_move::partial_fills_tests {
    use super::partial_fills;
    use sui::test_scenario as ts;
    use sui::tx_context::TxContext;
    use sui::clock::{Self as clock, Clock};
    use sui::managed_coin::{Self as mcoin, TreasuryCap};
    use sui::transfer;
    use sui::coin::{Self as coin, Coin};
    use std::vector;

    /// Simple test coin type for minting in tests
    struct TestCoin has drop {}

    #[test_only]
    fun create_test_coin(ctx: &mut TxContext): (TreasuryCap<TestCoin>, TestCoin) {
        // Creates a new coin type and returns its TreasuryCap
        let (treasury, metadata) = mcoin::create<TestCoin>(
            b"TestCoin", b"TCOIN", b"TC test", 9, false, ctx
        );
        (treasury, TestCoin {})
    }

    #[test]
    fun test_withdraw_all() {
        let mut scenario = ts::begin();
        let ctx = ts::ctx(&mut scenario);

        // Set up clock
        let clock = ts::create_clock(&mut scenario, ctx, 0); // ts helper provides a Clock

        let (mut cap, _) = create_test_coin(ctx);

        // Mint lock amount and safety deposit
        let lock_amount = mcoin::mint(&mut cap, 100, ctx);
        let deposit = mcoin::mint(&mut cap, 10, ctx);

        // Secret setup
        let secret = vector::from_bytes(b"abcdefghijklmnop"); // 16 bytes
        let secret_hash = std::hash::sha2_256(&secret);

        // Addresses
        let target = @0xBEEF;
        let refund = @0xCAFE;

        // Create lock with allow_partial/multiple enabled
        partial_fills::create_lock_object<TestCoin>(
            &clock,
            0,   // withdrawal_ms
            0,   // public_withdrawal_ms
            0,   // cancellation_ms
            0,   // public_cancellation_ms
            secret_hash,
            target,
            refund,
            lock_amount,
            deposit,
            16,          // secret length
            true,        // allow_partial
            true,        // allow_multiple
            1,           // min_partial
            ctx
        );

        // Take shared lock object from scenario (latest shared LockObject<TestCoin>)
        let lock_id = ts::take_shared<partial_fills::LockObject<TestCoin>>(&mut scenario);

        // Full withdrawal: the remaining balance equals the original amount
        partial_fills::withdraw_all<TestCoin>(
            lock_id,
            &clock,
            secret,
            ctx
        );

        // At this point: safety deposit distributed to ctx.sender()
        // and Coin transferred to `target`.
        ts::end(scenario);
    }

    #[test]
    fun test_partial_withdraw_then_reconstruct() {
        let mut scenario = ts::begin();
        let ctx = ts::ctx(&mut scenario);
        let clock = ts::create_clock(&mut scenario, ctx, 0);

        let (mut cap, _) = create_test_coin(ctx);

        let lock_amount = mcoin::mint(&mut cap, 100, ctx);
        let deposit = mcoin::mint(&mut cap, 50, ctx);

        let secret = vector::from_bytes(b"abcdefghijklmnop");
        let secret_hash = std::hash::sha2_256(&secret);
        let target = @0xDAD;
        let refund = @0xADD;

        partial_fills::create_lock_object<TestCoin>(
            &clock,
            0, 0, 0, 0,
            secret_hash,
            target,
            refund,
            lock_amount,
            deposit,
            16,       // secret length
            true,     // allow_partial
            true,     // allow_multiple
            10,       // minimum partial
            ctx
        );

        let lock = ts::take_shared<partial_fills::LockObject<TestCoin>>(&mut scenario);

        // First partial withdrawal — amount 40
        partial_fills::withdraw_partial<TestCoin>(
            lock,
            &clock,
            secret,
            40,
            ctx
        );

        // After the first fill, the lock is re-shared (remaining 60)
        let lock2 = ts::take_shared<partial_fills::LockObject<TestCoin>>(&mut scenario);

        // Second partial withdrawal — amount 30
        partial_fills::withdraw_partial<TestCoin>(
            lock2,
            &clock,
            secret,
            30,
            ctx
        );

        // After that, the lock is still re-shared (remaining 30)
        let lock3 = ts::take_shared<partial_fills::LockObject<TestCoin>>(&mut scenario);

        // Final withdraw — withdraw_all should consume rest, delete object
        partial_fills::withdraw_all<TestCoin>(
            lock3,
            &clock,
            secret,
            ctx
        );

        ts::end(scenario);
    }

    #[test]
    fun test_cancel() {
        let mut scenario = ts::begin();
        let ctx = ts::ctx(&mut scenario);
        let clock = ts::create_clock(&mut scenario, ctx, 0);

        let (mut cap, _) = create_test_coin(ctx);
        let lock_amount = mcoin::mint(&mut cap, 100, ctx);
        let deposit = mcoin::mint(&mut cap, 20, ctx);

        let secret = vector::from_bytes(b"abcdefghijklmnop");
        let secret_hash = std::hash::sha2_256(&secret);
        let target = @0x111;
        let refund = @0x222;

        // cancellation happens immediately because we set ms = 0
        partial_fills::create_lock_object<TestCoin>(
            &clock, 0, 0, 0, 0,
            secret_hash,
            target,
            refund,
            lock_amount,
            deposit,
            16,
            true,
            true,
            1,
            ctx
        );

        let lock = ts::take_shared<partial_fills::LockObject<TestCoin>>(&mut scenario);

        partial_fills::cancel<TestCoin>(
            lock,
            &clock,
            ctx
        );

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 8)] // EAmountTooSmall
    fun test_amount_too_small_rejected() {
        let mut scenario = ts::begin();
        let ctx = ts::ctx(&mut scenario);
        let clock = ts::create_clock(&mut scenario, ctx, 0);

        let (mut cap, _) = create_test_coin(ctx);
        let lock_amount = mcoin::mint(&mut cap, 100, ctx);
        let deposit = mcoin::mint(&mut cap, 10, ctx);
        let secret = vector::from_bytes(b"abcdefghijklmnop");
        let secret_hash = std::hash::sha2_256(&secret);
        let target = @0xAAA;
        let refund = @0xBBB;

        partial_fills::create_lock_object<TestCoin>(
            &clock, 0, 0, 0, 0,
            secret_hash,
            target, refund,
            lock_amount, deposit,
            16, true, true, 10, ctx
        );

        let lock = ts::take_shared<partial_fills::LockObject<TestCoin>>(&mut scenario);

        // Attempt to withdraw with amount < min_partial = 10
        partial_fills::withdraw_partial<TestCoin>(
            lock, &clock, secret, 5, ctx
        );

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 9)] // EPartialNotAllowed
    fun test_partial_not_allowed_rejected() {
        let mut scenario = ts::begin();
        let ctx = ts::ctx(&mut scenario);
        let clock = ts::create_clock(&mut scenario, ctx, 0);

        let (mut cap, _) = create_test_coin(ctx);
        let lock_amount = mcoin::mint(&mut cap, 100, ctx);
        let deposit = mcoin::mint(&mut cap, 10, ctx);
        let secret = vector::from_bytes(b"abcdefghijklmnop");
        let secret_hash = std::hash::sha2_256(&secret);
        let target = @0x77;
        let refund = @0x88;

        // allow_partial = false
        partial_fills::create_lock_object<TestCoin>(
            &clock, 0, 0, 0, 0,
            secret_hash,
            target,
            refund,
            lock_amount,
            deposit,
            16, false, true, 1, ctx
        );

        let lock = ts::take_shared<partial_fills::LockObject<TestCoin>>(&mut scenario);

        partial_fills::withdraw_partial<TestCoin>(
            lock, &clock, secret, 10, ctx
        );

        ts::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = 10)] // EMultipleFillsNotAllowed
    fun test_multiple_fills_not_allowed_rejected() {
        let mut scenario = ts::begin();
        let ctx = ts::ctx(&mut scenario);
        let clock = ts::create_clock(&mut scenario, ctx, 0);

        let (mut cap, _) = create_test_coin(ctx);
        let lock_amount = mcoin::mint(&mut cap, 100, ctx);
        let deposit = mcoin::mint(&mut cap, 10, ctx);
        let secret = vector::from_bytes(b"abcdefghijklmnop");
        let secret_hash = std::hash::sha2_256(&secret);
        let target = @0xA1A1;
        let refund = @0xB2B2;

        // allow_multiple = false
        partial_fills::create_lock_object<TestCoin>(
            &clock, 0, 0, 0, 0,
            secret_hash,
            target, refund,
            lock_amount, deposit,
            16, true, false, 1, ctx
        );

        let lock = ts::take_shared<partial_fills::LockObject<TestCoin>>(&mut scenario);

        partial_fills::withdraw_partial<TestCoin>(
            lock, &clock, secret, 10, ctx
        );

        ts::end(scenario);
    }
}