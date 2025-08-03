#[test_only]
module oneinch_move::pf_test {
    use sui::test_scenario::{Self as test, next_tx, ctx};
    use sui::coin::{Self};
    use sui::clock::{Self};
    use sui::sui::SUI;
    use sui::test_utils::assert_eq;
    use std::string;
    use sui::hash;
    use oneinch_move::partial_fills::{
        Self as escrow, CrossChainEscrow, UsedSecretsRegistry
    };

    // Test constants
    const MAKER: address = @0xA;
    const TAKER: address = @0xB;
    const RESOLVER1: address = @0xC;
    const RESOLVER2: address = @0xD;
    const RESOLVER3: address = @0xE;
    const TOTAL_AMOUNT: u64 = 1000;
    const PARTIAL_AMOUNT_1: u64 = 300; // 30%
    const PARTIAL_AMOUNT_2: u64 = 500; // 50%
    const PARTIAL_AMOUNT_3: u64 = 200; // 20%
    const ONE_HOUR_MS: u64 = 3600000;

    #[test]
    fun test_partial_fill_basic() {
        let mut scenario = test::begin(MAKER);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        
        // Initialize the module
        escrow::init_for_testing(ctx(&mut scenario));
        
        next_tx(&mut scenario, MAKER);
        
        // Create test data
        let secret = b"test_secret";
        let hash_lock = hash::keccak256(&secret);
        let time_lock = clock::timestamp_ms(&clock) + ONE_HOUR_MS;
        let coin = coin::mint_for_testing<SUI>(TOTAL_AMOUNT, ctx(&mut scenario));
        let ethereum_order_hash = string::utf8(b"0x1234567890abcdef");
        
        // Create escrow with open taker (address 0x0 for anyone to fill)
        let escrow_id = escrow::create_and_share_escrow<SUI>(
            coin,
            @0x0, // Open to any resolver
            hash_lock,
            time_lock,
            ethereum_order_hash,
            &clock,
            ctx(&mut scenario)
        );
        
        assert!(sui::object::id_to_address(&escrow_id) != @0x0, 0);
        
        next_tx(&mut scenario, RESOLVER1);
        
        // Get shared objects
        let mut escrow = test::take_shared<CrossChainEscrow<SUI>>(&scenario);
        let mut registry = test::take_shared<UsedSecretsRegistry>(&scenario);
        
        // Verify initial escrow state
        let (maker, taker, total_amount, remaining_amount, stored_hash_lock, stored_time_lock, is_filled, created_at, stored_ethereum_order_hash) = 
            escrow::get_escrow_info(&escrow);
        
        assert_eq(maker, MAKER);
        assert_eq(taker, @0x0); // Open taker
        assert_eq(total_amount, TOTAL_AMOUNT);
        assert_eq(remaining_amount, TOTAL_AMOUNT);
        assert_eq(stored_hash_lock, hash_lock);
        assert_eq(stored_time_lock, time_lock);
        assert_eq(is_filled, false);
        assert_eq(created_at, clock::timestamp_ms(&clock));
        assert_eq(stored_ethereum_order_hash, ethereum_order_hash);
        
        // Partial fill by Resolver1 (30%)
        let received_coin_1 = escrow::fill_escrow_partial(
            &mut escrow,
            &mut registry,
            PARTIAL_AMOUNT_1,
            secret,
            &clock,
            ctx(&mut scenario)
        );
        
        // Verify partial fill
        assert_eq(coin::value(&received_coin_1), PARTIAL_AMOUNT_1);
        assert_eq(escrow::get_remaining_amount(&escrow), TOTAL_AMOUNT - PARTIAL_AMOUNT_1);
        
        let (_, _, _, remaining_amount, _, _, is_filled, _, _) = escrow::get_escrow_info(&escrow);
        assert_eq(remaining_amount, TOTAL_AMOUNT - PARTIAL_AMOUNT_1);
        assert_eq(is_filled, false); // Not yet completed
        
        // Verify secret was stored
        let stored_secret = escrow::get_secret(&escrow);
        assert_eq(stored_secret, secret);
        
        coin::burn_for_testing(received_coin_1);
        test::return_shared(escrow);
        test::return_shared(registry);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_multiple_partial_fills() {
        let mut scenario = test::begin(MAKER);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        
        escrow::init_for_testing(ctx(&mut scenario));
        next_tx(&mut scenario, MAKER);
        
        let secret = b"test_secret";
        let hash_lock = hash::keccak256(&secret);
        let time_lock = clock::timestamp_ms(&clock) + ONE_HOUR_MS;
        let coin = coin::mint_for_testing<SUI>(TOTAL_AMOUNT, ctx(&mut scenario));
        let ethereum_order_hash = string::utf8(b"0x1234567890abcdef");
        
        let escrow_id = escrow::create_and_share_escrow<SUI>(
            coin,
            @0x0, // Open to any resolver
            hash_lock,
            time_lock,
            ethereum_order_hash,
            &clock,
            ctx(&mut scenario)
        );
        
        // First partial fill by Resolver1
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut escrow = test::take_shared<CrossChainEscrow<SUI>>(&scenario);
            let mut registry = test::take_shared<UsedSecretsRegistry>(&scenario);
            
            let received_coin_1 = escrow::fill_escrow_partial(
                &mut escrow,
                &mut registry,
                PARTIAL_AMOUNT_1,
                secret,
                &clock,
                ctx(&mut scenario)
            );
            
            assert_eq(coin::value(&received_coin_1), PARTIAL_AMOUNT_1);
            assert_eq(escrow::get_remaining_amount(&escrow), TOTAL_AMOUNT - PARTIAL_AMOUNT_1);
            
            coin::burn_for_testing(received_coin_1);
            test::return_shared(escrow);
            test::return_shared(registry);
        };
        
        // Second partial fill by Resolver2
        next_tx(&mut scenario, RESOLVER2);
        {
            let mut escrow = test::take_shared<CrossChainEscrow<SUI>>(&scenario);
            let mut registry = test::take_shared<UsedSecretsRegistry>(&scenario);
            
            let received_coin_2 = escrow::fill_escrow_partial(
                &mut escrow,
                &mut registry,
                PARTIAL_AMOUNT_2,
                secret,
                &clock,
                ctx(&mut scenario)
            );
            
            assert_eq(coin::value(&received_coin_2), PARTIAL_AMOUNT_2);
            assert_eq(escrow::get_remaining_amount(&escrow), TOTAL_AMOUNT - PARTIAL_AMOUNT_1 - PARTIAL_AMOUNT_2);
            
            coin::burn_for_testing(received_coin_2);
            test::return_shared(escrow);
            test::return_shared(registry);
        };
        
        // Final fill by Resolver3 (should complete the escrow)
        next_tx(&mut scenario, RESOLVER3);
        {
            let mut escrow = test::take_shared<CrossChainEscrow<SUI>>(&scenario);
            let mut registry = test::take_shared<UsedSecretsRegistry>(&scenario);
            
            let received_coin_3 = escrow::fill_escrow_partial(
                &mut escrow,
                &mut registry,
                PARTIAL_AMOUNT_3,
                secret,
                &clock,
                ctx(&mut scenario)
            );
            
            assert_eq(coin::value(&received_coin_3), PARTIAL_AMOUNT_3);
            assert_eq(escrow::get_remaining_amount(&escrow), 0);
            
            // Verify escrow is now completed
            let (_, _, _, remaining_amount, _, _, is_filled, _, _) = escrow::get_escrow_info(&escrow);
            assert_eq(remaining_amount, 0);
            assert_eq(is_filled, true);
            
            coin::burn_for_testing(received_coin_3);
            test::return_shared(escrow);
            test::return_shared(registry);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_fill_escrow_completion() {
        let mut scenario = test::begin(MAKER);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        
        escrow::init_for_testing(ctx(&mut scenario));
        next_tx(&mut scenario, MAKER);
        
        let secret = b"test_secret";
        let hash_lock = hash::keccak256(&secret);
        let time_lock = clock::timestamp_ms(&clock) + ONE_HOUR_MS;
        let coin = coin::mint_for_testing<SUI>(TOTAL_AMOUNT, ctx(&mut scenario));
        let ethereum_order_hash = string::utf8(b"0x1234567890abcdef");
        
        let escrow_id = escrow::create_and_share_escrow<SUI>(
            coin,
            TAKER, // Fixed taker
            hash_lock,
            time_lock,
            ethereum_order_hash,
            &clock,
            ctx(&mut scenario)
        );
        
        next_tx(&mut scenario, TAKER);
        
        let mut escrow = test::take_shared<CrossChainEscrow<SUI>>(&scenario);
        let mut registry = test::take_shared<UsedSecretsRegistry>(&scenario);
        
        // Use fill_escrow (should fill remaining amount)
        let received_coin = escrow::fill_escrow(
            &mut escrow,
            &mut registry,
            secret,
            &clock,
            ctx(&mut scenario)
        );
        
        // Verify full amount received and escrow completed
        assert_eq(coin::value(&received_coin), TOTAL_AMOUNT);
        assert_eq(escrow::get_remaining_amount(&escrow), 0);
        
        let (_, _, _, remaining_amount, _, _, is_filled, _, _) = escrow::get_escrow_info(&escrow);
        assert_eq(remaining_amount, 0);
        assert_eq(is_filled, true);
        
        coin::burn_for_testing(received_coin);
        test::return_shared(escrow);
        test::return_shared(registry);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = oneinch_move::partial_fills::E_INSUFFICIENT_REMAINING_AMOUNT)]
    fun test_fill_exceeds_remaining() {
        let mut scenario = test::begin(MAKER);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        
        escrow::init_for_testing(ctx(&mut scenario));
        next_tx(&mut scenario, MAKER);
        
        let secret = b"test_secret";
        let hash_lock = hash::keccak256(&secret);
        let time_lock = clock::timestamp_ms(&clock) + ONE_HOUR_MS;
        let coin = coin::mint_for_testing<SUI>(TOTAL_AMOUNT, ctx(&mut scenario));
        let ethereum_order_hash = string::utf8(b"0x1234567890abcdef");
        
        let escrow_id = escrow::create_and_share_escrow<SUI>(
            coin,
            @0x0,
            hash_lock,
            time_lock,
            ethereum_order_hash,
            &clock,
            ctx(&mut scenario)
        );
        
        next_tx(&mut scenario, RESOLVER1);
        
        let mut escrow = test::take_shared<CrossChainEscrow<SUI>>(&scenario);
        let mut registry = test::take_shared<UsedSecretsRegistry>(&scenario);
        
        // Try to fill more than total amount (should fail)
        let received_coin = escrow::fill_escrow_partial(
            &mut escrow,
            &mut registry,
            TOTAL_AMOUNT + 1,
            secret,
            &clock,
            ctx(&mut scenario)
        );
        
        coin::burn_for_testing(received_coin);
        test::return_shared(escrow);
        test::return_shared(registry);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    #[expected_failure(abort_code = oneinch_move::partial_fills::E_INVALID_FILL_AMOUNT)]
    fun test_fill_zero_amount() {
        let mut scenario = test::begin(MAKER);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        
        escrow::init_for_testing(ctx(&mut scenario));
        next_tx(&mut scenario, MAKER);
        
        let secret = b"test_secret";
        let hash_lock = hash::keccak256(&secret);
        let time_lock = clock::timestamp_ms(&clock) + ONE_HOUR_MS;
        let coin = coin::mint_for_testing<SUI>(TOTAL_AMOUNT, ctx(&mut scenario));
        let ethereum_order_hash = string::utf8(b"0x1234567890abcdef");
        
        let escrow_id = escrow::create_and_share_escrow<SUI>(
            coin,
            @0x0,
            hash_lock,
            time_lock,
            ethereum_order_hash,
            &clock,
            ctx(&mut scenario)
        );
        
        next_tx(&mut scenario, RESOLVER1);
        
        let mut escrow = test::take_shared<CrossChainEscrow<SUI>>(&scenario);
        let mut registry = test::take_shared<UsedSecretsRegistry>(&scenario);
        
        // Try to fill with zero amount (should fail)
        let received_coin = escrow::fill_escrow_partial(
            &mut escrow,
            &mut registry,
            0,
            secret,
            &clock,
            ctx(&mut scenario)
        );
        
        coin::burn_for_testing(received_coin);
        test::return_shared(escrow);
        test::return_shared(registry);
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_cancel_partially_filled_escrow() {
        let mut scenario = test::begin(MAKER);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        
        escrow::init_for_testing(ctx(&mut scenario));
        next_tx(&mut scenario, MAKER);
        
        let secret = b"test_secret";
        let hash_lock = hash::keccak256(&secret);
        let time_lock = clock::timestamp_ms(&clock) + ONE_HOUR_MS;
        let coin = coin::mint_for_testing<SUI>(TOTAL_AMOUNT, ctx(&mut scenario));
        let ethereum_order_hash = string::utf8(b"0x1234567890abcdef");
        
        let escrow_id = escrow::create_and_share_escrow<SUI>(
            coin,
            @0x0,
            hash_lock,
            time_lock,
            ethereum_order_hash,
            &clock,
            ctx(&mut scenario)
        );
        
        // Partial fill
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut escrow = test::take_shared<CrossChainEscrow<SUI>>(&scenario);
            let mut registry = test::take_shared<UsedSecretsRegistry>(&scenario);
            
            let received_coin = escrow::fill_escrow_partial(
                &mut escrow,
                &mut registry,
                PARTIAL_AMOUNT_1,
                secret,
                &clock,
                ctx(&mut scenario)
            );
            
            coin::burn_for_testing(received_coin);
            test::return_shared(escrow);
            test::return_shared(registry);
        };
        
        // Advance time past expiry
        clock::increment_for_testing(&mut clock, ONE_HOUR_MS + 1000);
        
        // Cancel and get remaining amount
        next_tx(&mut scenario, MAKER);
        {
            let mut escrow = test::take_shared<CrossChainEscrow<SUI>>(&scenario);
            
            let refunded_coin = escrow::cancel_escrow(
                &mut escrow,
                &clock,
                ctx(&mut scenario)
            );
            
            // Should only get the remaining amount (not the filled amount)
            assert_eq(coin::value(&refunded_coin), TOTAL_AMOUNT - PARTIAL_AMOUNT_1);
            
            coin::burn_for_testing(refunded_coin);
            test::return_shared(escrow);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }

    #[test]
    fun test_multiple_resolvers_competition() {
        let mut scenario = test::begin(MAKER);
        let mut clock = clock::create_for_testing(ctx(&mut scenario));
        
        escrow::init_for_testing(ctx(&mut scenario));
        next_tx(&mut scenario, MAKER);
        
        let secret = b"test_secret";
        let hash_lock = hash::keccak256(&secret);
        let time_lock = clock::timestamp_ms(&clock) + ONE_HOUR_MS;
        let coin = coin::mint_for_testing<SUI>(TOTAL_AMOUNT, ctx(&mut scenario));
        let ethereum_order_hash = string::utf8(b"0x1234567890abcdef");
        
        let escrow_id = escrow::create_and_share_escrow<SUI>(
            coin,
            @0x0, // Open to competition
            hash_lock,
            time_lock,
            ethereum_order_hash,
            &clock,
            ctx(&mut scenario)
        );
        
        // Resolver1 fills first
        next_tx(&mut scenario, RESOLVER1);
        {
            let mut escrow = test::take_shared<CrossChainEscrow<SUI>>(&scenario);
            let mut registry = test::take_shared<UsedSecretsRegistry>(&scenario);
            
            let received_coin = escrow::fill_escrow_partial(
                &mut escrow,
                &mut registry,
                200, // 20%
                secret,
                &clock,
                ctx(&mut scenario)
            );
            
            assert_eq(coin::value(&received_coin), 200);
            coin::burn_for_testing(received_coin);
            test::return_shared(escrow);
            test::return_shared(registry);
        };
        
        // Resolver2 fills next
        next_tx(&mut scenario, RESOLVER2);
        {
            let mut escrow = test::take_shared<CrossChainEscrow<SUI>>(&scenario);
            let mut registry = test::take_shared<UsedSecretsRegistry>(&scenario);
            
            let received_coin = escrow::fill_escrow_partial(
                &mut escrow,
                &mut registry,
                300, // 30%
                secret,
                &clock,
                ctx(&mut scenario)
            );
            
            assert_eq(coin::value(&received_coin), 300);
            coin::burn_for_testing(received_coin);
            test::return_shared(escrow);
            test::return_shared(registry);
        };
        
        // Resolver3 completes the escrow
        next_tx(&mut scenario, RESOLVER3);
        {
            let mut escrow = test::take_shared<CrossChainEscrow<SUI>>(&scenario);
            let mut registry = test::take_shared<UsedSecretsRegistry>(&scenario);
            
            let remaining = escrow::get_remaining_amount(&escrow);
            assert_eq(remaining, 500); // 50% left
            
            let received_coin = escrow::fill_escrow_partial(
                &mut escrow,
                &mut registry,
                remaining,
                secret,
                &clock,
                ctx(&mut scenario)
            );
            
            assert_eq(coin::value(&received_coin), 500);
            assert_eq(escrow::get_remaining_amount(&escrow), 0);
            
            let (_, _, _, remaining_amount, _, _, is_filled, _, _) = escrow::get_escrow_info(&escrow);
            assert_eq(remaining_amount, 0);
            assert_eq(is_filled, true);
            
            coin::burn_for_testing(received_coin);
            test::return_shared(escrow);
            test::return_shared(registry);
        };
        
        clock::destroy_for_testing(clock);
        test::end(scenario);
    }
}