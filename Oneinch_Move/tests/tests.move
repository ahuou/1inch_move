#[test_only]
/// tests are adapted from <https://github.com/kaleido-io/token-sample-htlc/tree/master/test> and <https://github.com/chatch/hashed-timelock-contract-ethereum/tree/master/test>
/// 
/// I don't think it's a best way to test, and this one should be tested with node RPC instead of from inside the framework; but chance to touch Sui randomness worth it. 
/// Also it's fascinating that it's possible to adapt those (external) tests inside the framework, but that makes it quite boilerplatty in turn.
module oneinch_move::chatch_tests {
    use oneinch_move::oneinch_move::{Self};
    use sui::random::{Self, Random};
    use sui::test_scenario;
    use std::hash;
    use sui::clock::{Self};

    use sui::sui::SUI;
    use sui::coin::{Self, Coin};

    const ADDR_INIT: address = @0xA;
    const ADDR_TARGET: address = @0xB;
    const ADDR_REFUND: address = @0xC;
    const ADDR_THIRD_PARTY: address = @0xD;

    // _should fail when no amount is sent_ is covered since even zero balance could be locked
    // _should fail with timelocks in the past_ is covered since it takes duration not timestamp
    // _should reject a duplicate contract request_ is covered since objects allow duplicate locks discreting them by id (though same secret would imply a very tricky, but again it's not realy possible to track this beside good randomness since a lot of locks are even at other chains)

    // Should fail as withdrawal period is not yet reached (finality lock)
    #[test, expected_failure(abort_code = oneinch_move::EWithdrawNotAvailable)]
    fun test_withdraw_earlyfin() {
        // #boilerplate_init: start
        let mut scenario = test_scenario::begin(@0x0);
        random::create_for_testing(scenario.ctx());
        let clock_the = clock::create_for_testing(scenario.ctx());
        
        scenario.next_tx(ADDR_INIT);

        let random_the = scenario.take_shared<Random>();
        let secret = 
            random_the.new_generator(scenario.ctx())
                .generate_bytes(32);
        let hashed = hash::sha2_256(copy secret);

        let coin_the = 
            coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let deposit_the = 
            coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
        // #boilerplate_init: end
        
        let coin_id = object::id<Coin<SUI>>(&coin_the);
        let deposit_id = object::id<Coin<SUI>>(&deposit_the);

        oneinch_move::create_lock_object(
            &clock_the, 
            3_600_000,  // withdrawal_ms
            3_660_000,     // public_withdrawal_ms  
            4_600_000,  // cancellation_ms
            4_660_000,     // public_cancellation_ms
            copy hashed, 
            ADDR_REFUND,
            ADDR_TARGET, 
            32, //secret_length
            coin_the, 
            deposit_the,
            scenario.ctx()
        );

        scenario.next_tx(ADDR_INIT); 
        let lock_the = 
            scenario.take_shared<oneinch_move::LockObject<SUI>>();
        lock_the.withdraw(&clock_the, secret, scenario.ctx());
        
        scenario.next_tx(ADDR_TARGET); 
        let redeemed = 
            scenario.take_from_sender_by_id<Coin<SUI>>(coin_id);
        let deposit_redeemed = 
            scenario.take_from_sender_by_id<Coin<SUI>>(deposit_id);
        assert!(redeemed.value() == 10_000_000_000);
        assert!(deposit_redeemed.value() == 1_000_000);
        scenario.return_to_sender(redeemed);
        scenario.return_to_sender(deposit_redeemed);

        clock_the.destroy_for_testing();
        test_scenario::return_shared(random_the);
        test_scenario::end(scenario);  
    }


    // Should pass as resolver can withdraw before public withdrawal period
    #[test]
    fun test_withdraw_resolver() {
        // #boilerplate_init: start
        let mut scenario = test_scenario::begin(@0x0);
        random::create_for_testing(scenario.ctx());
        let mut clock_the = clock::create_for_testing(scenario.ctx());
        
        scenario.next_tx(ADDR_INIT);

        let random_the = scenario.take_shared<Random>();
        let secret = 
            random_the.new_generator(scenario.ctx())
                .generate_bytes(32);
        let hashed = hash::sha2_256(copy secret);

        let coin_the = 
            coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let deposit_the = 
            coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
        // #boilerplate_init: end
        
        let coin_id = object::id<Coin<SUI>>(&coin_the);
        let deposit_id = object::id<Coin<SUI>>(&deposit_the);

        oneinch_move::create_lock_object(
            &clock_the, 
            3_600_000,  // withdrawal_ms
            3_660_000,     // public_withdrawal_ms  
            4_600_000,  // cancellation_ms
            4_660_000,     // public_cancellation_ms
            copy hashed, 
            ADDR_REFUND,
            ADDR_TARGET, 
            32, //secret_length
            coin_the, 
            deposit_the,
            scenario.ctx()
        );

        scenario.next_tx(ADDR_INIT); 
        let lock_the = 
            scenario.take_shared<oneinch_move::LockObject<SUI>>();

        clock_the.increment_for_testing(3_630_000);

        lock_the.withdraw(&clock_the, secret, scenario.ctx());
        
        scenario.next_tx(ADDR_TARGET); 
        let redeemed = 
            scenario.take_from_sender_by_id<Coin<SUI>>(coin_id);
        
        assert!(redeemed.value() == 10_000_000_000);
        scenario.return_to_sender(redeemed);

        scenario.next_tx(ADDR_INIT); 
        let deposit_redeemed = 
            scenario.take_from_sender_by_id<Coin<SUI>>(deposit_id);
        assert!(deposit_redeemed.value() == 1_000_000);
        scenario.return_to_sender(deposit_redeemed);

        clock_the.destroy_for_testing();
        test_scenario::return_shared(random_the);
        test_scenario::end(scenario);  
    }


    // should fail if preimage does not hash to hashX
    #[test, expected_failure(abort_code = oneinch_move::ESecretPreimageWrong)]
    fun test_withdraw_wrongsecret() {
        // #boilerplate_init: start
        let mut scenario = test_scenario::begin(@0x0);
        random::create_for_testing(scenario.ctx());
        let mut clock_the = clock::create_for_testing(scenario.ctx());
        
        scenario.next_tx(ADDR_INIT);

        let random_the = scenario.take_shared<Random>();
        let mut generator_the = random_the.new_generator(scenario.ctx());
        let secret = generator_the.generate_bytes(32);
        let hashed = hash::sha2_256(copy secret);

        let coin_the = 
            coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let deposit_the = 
            coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
        // #boilerplate_init: end
        
        oneinch_move::create_lock_object(
            &clock_the, 
            3_600_000,  // withdrawal_ms
            3_660_000,     // public_withdrawal_ms  
            4_600_000,  // cancellation_ms
            4_660_000,     // public_cancellation_ms
            copy hashed, 
            ADDR_REFUND,
            ADDR_TARGET, 
            32, //secret_length
            coin_the, 
            deposit_the,
            scenario.ctx()
        );

        // Advance time past withdrawal period so we can test the wrong secret error
        clock_the.increment_for_testing(3_630_000);

        scenario.next_tx(ADDR_INIT); 
        let lock_the = 
            scenario.take_shared<oneinch_move::LockObject<SUI>>();
        lock_the.withdraw(
            &clock_the,
            generator_the.generate_bytes(32), 
            scenario.ctx()
        );

        clock_the.destroy_for_testing();
        test_scenario::return_shared(random_the);
        test_scenario::end(scenario); 
    }


    // should fail if trying to withdraw before public withdrawal period
    #[test, expected_failure(abort_code = oneinch_move::EWithdrawNotAllowed)]
    fun test_withdraw_before_public_withdrawal() {
        // #boilerplate_init: start
        let mut scenario = test_scenario::begin(@0x0);
        random::create_for_testing(scenario.ctx());
        let mut clock_the = clock::create_for_testing(scenario.ctx());
        
        scenario.next_tx(ADDR_INIT);

        let random_the = scenario.take_shared<Random>();
        let secret = 
            random_the.new_generator(scenario.ctx())
                .generate_bytes(32);
        let hashed = hash::sha2_256(copy secret);

        let coin_the = 
            coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let deposit_the = 
            coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
        // #boilerplate_init: end
        
        oneinch_move::create_lock_object(
            &clock_the, 
            3_600_000,  // withdrawal_ms
            3_660_000,     // public_withdrawal_ms  
            4_600_000,  // cancellation_ms
            4_660_000,     // public_cancellation_ms
            copy hashed, 
            ADDR_REFUND,
            ADDR_TARGET, 
            32, //secret_length
            coin_the, 
            deposit_the,
            scenario.ctx()
        );

        // Try to withdraw immediately (before withdrawal period)
        scenario.next_tx(ADDR_INIT); 
        let lock_the = 
            scenario.take_shared<oneinch_move::LockObject<SUI>>();

        clock_the.increment_for_testing(3_630_000);

        scenario.next_tx(ADDR_THIRD_PARTY); 
        lock_the.withdraw(&clock_the, secret, scenario.ctx());

        clock_the.destroy_for_testing();
        test_scenario::return_shared(random_the);
        test_scenario::end(scenario); 
    }

    // should succeed if trying to withdraw after public withdrawal period
    #[test]
    fun test_withdraw_after_public_withdrawal() {
        // #boilerplate_init: start
        let mut scenario = test_scenario::begin(@0x0);
        random::create_for_testing(scenario.ctx());
        let mut clock_the = clock::create_for_testing(scenario.ctx());
        
        scenario.next_tx(ADDR_INIT);

        let random_the = scenario.take_shared<Random>();
        let secret = 
            random_the.new_generator(scenario.ctx())
                .generate_bytes(32);
        let hashed = hash::sha2_256(copy secret);

        let coin_the = 
            coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let deposit_the = 
            coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
        // #boilerplate_init: end
        
        oneinch_move::create_lock_object(
            &clock_the, 
            3_600_000,  // withdrawal_ms
            3_660_000,     // public_withdrawal_ms  
            4_600_000,  // cancellation_ms
            4_660_000,     // public_cancellation_ms
            copy hashed, 
            ADDR_REFUND,
            ADDR_TARGET, 
            32, //secret_length
            coin_the, 
            deposit_the,
            scenario.ctx()
        );

        // Try to withdraw immediately (before withdrawal period)
        scenario.next_tx(ADDR_INIT); 
        let lock_the = 
            scenario.take_shared<oneinch_move::LockObject<SUI>>();

        clock_the.increment_for_testing(3_670_000);

        scenario.next_tx(ADDR_THIRD_PARTY); 
        lock_the.withdraw(&clock_the, secret, scenario.ctx());

        clock_the.destroy_for_testing();
        test_scenario::return_shared(random_the);
        test_scenario::end(scenario); 
    }

    
    // should fail if secret length is wrong
    #[test, expected_failure(abort_code = oneinch_move::ESecretLengthWrong)]
    fun test_withdraw_wrong_secret_length() {
        // #boilerplate_init: start
        let mut scenario = test_scenario::begin(@0x0);
        random::create_for_testing(scenario.ctx());
        let mut clock_the = clock::create_for_testing(scenario.ctx());
        
        scenario.next_tx(ADDR_INIT);

        let random_the = scenario.take_shared<Random>();
        let secret = 
            random_the.new_generator(scenario.ctx())
                .generate_bytes(32);
        let hashed = hash::sha2_256(copy secret);

        let coin_the = 
            coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let deposit_the = 
            coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
        // #boilerplate_init: end
        
        oneinch_move::create_lock_object(
            &clock_the, 
            3_600_000,  // withdrawal_ms
            3_660_000,     // public_withdrawal_ms  
            4_600_000,  // cancellation_ms
            4_660_000,     // public_cancellation_ms
            copy hashed, 
            ADDR_REFUND,
            ADDR_TARGET, 
            32, //secret_length
            coin_the, 
            deposit_the,
            scenario.ctx()
        );

        // Advance time past withdrawal period
        clock_the.increment_for_testing(3_700_000);

        // Try to withdraw with wrong secret length (16 bytes instead of 32)
        scenario.next_tx(ADDR_TARGET); 
        let lock_the = 
            scenario.take_shared<oneinch_move::LockObject<SUI>>();
        let wrong_length_secret = random_the.new_generator(scenario.ctx()).generate_bytes(16);

        scenario.next_tx(ADDR_THIRD_PARTY); 
        lock_the.withdraw(&clock_the, wrong_length_secret, scenario.ctx());

        clock_the.destroy_for_testing();
        test_scenario::return_shared(random_the);
        test_scenario::end(scenario); 
    }


    // should fail if secret preimage is wrong (correct length but wrong hash)
    #[test, expected_failure(abort_code = oneinch_move::ESecretPreimageWrong)]
    fun test_withdraw_wrong_secret_preimage() {
        // #boilerplate_init: start
        let mut scenario = test_scenario::begin(@0x0);
        random::create_for_testing(scenario.ctx());
        let mut clock_the = clock::create_for_testing(scenario.ctx());
        
        scenario.next_tx(ADDR_INIT);

        let random_the = scenario.take_shared<Random>();
        let secret = 
            random_the.new_generator(scenario.ctx())
                .generate_bytes(32);
        let hashed = hash::sha2_256(copy secret);

        let coin_the = 
            coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let deposit_the = 
            coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
        // #boilerplate_init: end
        
        oneinch_move::create_lock_object(
            &clock_the, 
            3_600_000,  // withdrawal_ms
            3_660_000,     // public_withdrawal_ms  
            4_600_000,  // cancellation_ms
            4_660_000,     // public_cancellation_ms
            copy hashed, 
            ADDR_REFUND,
            ADDR_TARGET, 
            32, //secret_length
            coin_the, 
            deposit_the,
            scenario.ctx()
        );

        // Advance time past withdrawal period
        clock_the.increment_for_testing(3_700_000);

        // Try to withdraw with wrong secret (correct length but wrong hash)
        scenario.next_tx(ADDR_TARGET); 
        let lock_the = 
            scenario.take_shared<oneinch_move::LockObject<SUI>>();
        let wrong_secret = random_the.new_generator(scenario.ctx()).generate_bytes(32);
        lock_the.withdraw(&clock_the, wrong_secret, scenario.ctx());    

        clock_the.destroy_for_testing();
        test_scenario::return_shared(random_the);
        test_scenario::end(scenario); 
    }

    //should fail before cancellation period
    #[test, expected_failure(abort_code = oneinch_move::ECancelNotAvailable)]
    fun test_cancel_early() {
        // #boilerplate_init: start
        let mut scenario = test_scenario::begin(@0x0);
        random::create_for_testing(scenario.ctx());
        let mut clock_the = clock::create_for_testing(scenario.ctx());
        
        scenario.next_tx(ADDR_INIT);

        let random_the = scenario.take_shared<Random>();
        let secret = 
            random_the.new_generator(scenario.ctx())
                .generate_bytes(32);
        let hashed = hash::sha2_256(copy secret);

        let coin_the = 
            coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let deposit_the = 
            coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
        // #boilerplate_init: end

        oneinch_move::create_lock_object(
            &clock_the, 
            3_600_000,  // withdrawal_ms
            3_660_000,     // public_withdrawal_ms  
            4_600_000,  // cancellation_ms
            4_660_000,     // public_cancellation_ms
            copy hashed, 
            ADDR_REFUND,
            ADDR_TARGET, 
            32, //secret_length
            coin_the, 
            deposit_the,
            scenario.ctx()
        );

        clock_the.increment_for_testing(3_700_000);

        scenario.next_tx(ADDR_INIT); 
        let lock_the = 
            scenario.take_shared<oneinch_move::LockObject<SUI>>();
        
        scenario.next_tx(ADDR_INIT); 
        lock_the.cancel(&clock_the, scenario.ctx());

        clock_the.destroy_for_testing();
        test_scenario::return_shared(random_the);
        test_scenario::end(scenario);  
    }

// should pass after resolver cancellation period
    #[test]
    fun test_cancel_resolver() {
        // #boilerplate_init: start
        let mut scenario = test_scenario::begin(@0x0);
        random::create_for_testing(scenario.ctx());
        let mut clock_the = clock::create_for_testing(scenario.ctx());
        
        scenario.next_tx(ADDR_INIT);

        let random_the = scenario.take_shared<Random>();
        let mut generator_the = random_the.new_generator(scenario.ctx());
        let secret = generator_the.generate_bytes(32);
        let hashed = hash::sha2_256(copy secret);

        let coin_the = 
            coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let deposit_the = 
            coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
        // #boilerplate_init: end
        
        let coin_id = object::id<Coin<SUI>>(&coin_the);
        let deposit_id = object::id<Coin<SUI>>(&deposit_the);
        
        oneinch_move::create_lock_object(
            &clock_the, 
            3_600_000,  // withdrawal_ms
            3_660_000,     // public_withdrawal_ms  
            4_600_000,  // cancellation_ms
            4_660_000,     // public_cancellation_ms
            copy hashed, 
            ADDR_REFUND,
            ADDR_TARGET, 
            32, //secret_length
            coin_the, 
            deposit_the,
            scenario.ctx()
        );

        scenario.next_tx(ADDR_TARGET); 
        clock_the.increment_for_testing(4_620_000);
        
        scenario.next_tx(ADDR_INIT); 
        let lock_the = 
            scenario.take_shared<oneinch_move::LockObject<SUI>>();

        scenario.next_tx(ADDR_INIT); 
        lock_the.cancel(&clock_the, scenario.ctx());
        
        scenario.next_tx(ADDR_REFUND); 
        let refunded = scenario.take_from_sender_by_id<Coin<SUI>>(coin_id);
        assert!(refunded.value() == 10_000_000_000);
        scenario.return_to_sender(refunded);

        scenario.next_tx(ADDR_INIT);
        let deposit_redeemed = 
            scenario.take_from_sender_by_id<Coin<SUI>>(deposit_id);
        assert!(deposit_redeemed.value() == 1_000_000);
        scenario.return_to_sender(deposit_redeemed);

        clock_the.destroy_for_testing();
        test_scenario::return_shared(random_the);
        test_scenario::end(scenario);  
    }

    // should fail after public tries to cancel before resolver cancellation period
    #[test, expected_failure(abort_code = oneinch_move::ECancelNotAllowed)]
    fun test_cancel_public_early() {
        // #boilerplate_init: start
        let mut scenario = test_scenario::begin(@0x0);
        random::create_for_testing(scenario.ctx());
        let mut clock_the = clock::create_for_testing(scenario.ctx());
        
        scenario.next_tx(ADDR_INIT);

        let random_the = scenario.take_shared<Random>();
        let mut generator_the = random_the.new_generator(scenario.ctx());
        let secret = generator_the.generate_bytes(32);
        let hashed = hash::sha2_256(copy secret);

        let coin_the = 
            coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let deposit_the = 
            coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
        // #boilerplate_init: end
        
        let coin_id = object::id<Coin<SUI>>(&coin_the);
        let deposit_id = object::id<Coin<SUI>>(&deposit_the);
        
        oneinch_move::create_lock_object(
            &clock_the, 
            3_600_000,  // withdrawal_ms
            3_660_000,     // public_withdrawal_ms  
            4_600_000,  // cancellation_ms
            4_660_000,     // public_cancellation_ms
            copy hashed, 
            ADDR_REFUND,
            ADDR_TARGET, 
            32, //secret_length
            coin_the, 
            deposit_the,
            scenario.ctx()
        );

        scenario.next_tx(ADDR_TARGET); 
        clock_the.increment_for_testing(4_620_000);
        
        scenario.next_tx(ADDR_INIT); 
        let lock_the = 
            scenario.take_shared<oneinch_move::LockObject<SUI>>();

        scenario.next_tx(ADDR_THIRD_PARTY); 
        lock_the.cancel(&clock_the, scenario.ctx());
        
        scenario.next_tx(ADDR_REFUND); 
        let refunded = scenario.take_from_sender_by_id<Coin<SUI>>(coin_id);
        assert!(refunded.value() == 10_000_000_000);
        scenario.return_to_sender(refunded);

        scenario.next_tx(ADDR_INIT);
        let deposit_redeemed = 
            scenario.take_from_sender_by_id<Coin<SUI>>(deposit_id);
        assert!(deposit_redeemed.value() == 1_000_000);
        scenario.return_to_sender(deposit_redeemed);

        clock_the.destroy_for_testing();
        test_scenario::return_shared(random_the);
        test_scenario::end(scenario);  
    }


    // should pass after public cancellation period
    #[test]
    fun test_cancel_everyone() {
        // #boilerplate_init: start
        let mut scenario = test_scenario::begin(@0x0);
        random::create_for_testing(scenario.ctx());
        let mut clock_the = clock::create_for_testing(scenario.ctx());
        
        scenario.next_tx(ADDR_INIT);

        let random_the = scenario.take_shared<Random>();
        let mut generator_the = random_the.new_generator(scenario.ctx());
        let secret = generator_the.generate_bytes(32);
        let hashed = hash::sha2_256(copy secret);

        let coin_the = 
            coin::mint_for_testing<SUI>(10_000_000_000, scenario.ctx());
        let deposit_the = 
            coin::mint_for_testing<SUI>(1_000_000, scenario.ctx());
        // #boilerplate_init: end
        
        let coin_id = object::id<Coin<SUI>>(&coin_the);
        let deposit_id = object::id<Coin<SUI>>(&deposit_the);
        
        oneinch_move::create_lock_object(
            &clock_the, 
            3_600_000,  // withdrawal_ms
            3_660_000,     // public_withdrawal_ms  
            4_600_000,  // cancellation_ms
            4_660_000,     // public_cancellation_ms
            copy hashed, 
            ADDR_REFUND,
            ADDR_TARGET, 
            32, //secret_length
            coin_the, 
            deposit_the,
            scenario.ctx()
        );

        scenario.next_tx(ADDR_TARGET); 
        clock_the.increment_for_testing(4_700_000);
        
        scenario.next_tx(ADDR_INIT); 
        let lock_the = 
            scenario.take_shared<oneinch_move::LockObject<SUI>>();

        scenario.next_tx(ADDR_THIRD_PARTY); 
        lock_the.cancel(&clock_the, scenario.ctx());
        
        scenario.next_tx(ADDR_REFUND); 
        let refunded = scenario.take_from_sender_by_id<Coin<SUI>>(coin_id);
        assert!(refunded.value() == 10_000_000_000);
        scenario.return_to_sender(refunded);

        scenario.next_tx(ADDR_THIRD_PARTY);
        let deposit_redeemed = 
            scenario.take_from_sender_by_id<Coin<SUI>>(deposit_id);
        assert!(deposit_redeemed.value() == 1_000_000);
        scenario.return_to_sender(deposit_redeemed);

        clock_the.destroy_for_testing();
        test_scenario::return_shared(random_the);
        test_scenario::end(scenario);  
    }
}