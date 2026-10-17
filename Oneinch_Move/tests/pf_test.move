#[test_only]
/// Tests for `oneinch_move::partial_fills`: one hashlock-guarded escrow that resolvers
/// drain in several fills, with the same timelock windows as the base module.
module oneinch_move::pf_test {
    use sui::test_scenario::{Self as test, Scenario};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::sui::SUI;
    use sui::hash;
    use std::string;
    use oneinch_move::partial_fills::{Self as escrow, LockObject, UsedSecretsRegistry};

    const MAKER: address = @0xA;
    const TARGET: address = @0xB;
    const RESOLVER1: address = @0xC;
    const RESOLVER2: address = @0xD;
    const RESOLVER3: address = @0xE;

    const TOTAL_AMOUNT: u64 = 1000;
    const DEPOSIT: u64 = 10;

    // Windows relative to creation (ms): resolver-only withdraw from 1h,
    // public withdraw from 2h, resolver-only cancel from 3h, public cancel from 4h.
    const WITHDRAWAL: u64 = 3_600_000;
    const PUBLIC_WITHDRAWAL: u64 = 7_200_000;
    const CANCELLATION: u64 = 10_800_000;
    const PUBLIC_CANCELLATION: u64 = 14_400_000;

    const SECRET: vector<u8> = b"test_secret_32_bytes_long_______";

    /// Starts a scenario, shares the registry and a 1000-MIST lock created by MAKER.
    fun setup(): (Scenario, Clock) {
        let mut scenario = test::begin(MAKER);
        let clock = clock::create_for_testing(scenario.ctx());
        escrow::init_for_testing(scenario.ctx());
        scenario.next_tx(MAKER);

        let secret = SECRET;
        escrow::createLockObject<SUI>(
            &clock,
            WITHDRAWAL,
            PUBLIC_WITHDRAWAL,
            CANCELLATION,
            PUBLIC_CANCELLATION,
            hash::keccak256(&secret),
            TARGET,
            MAKER,
            coin::mint_for_testing<SUI>(TOTAL_AMOUNT, scenario.ctx()),
            coin::mint_for_testing<SUI>(DEPOSIT, scenario.ctx()),
            (secret.length() as u8),
            string::utf8(b"0x1234567890abcdef"),
            scenario.ctx(),
        );
        (scenario, clock)
    }

    /// One partial fill as `who`; returns nothing, the coin goes to `who`.
    fun fill(scenario: &mut Scenario, clock: &Clock, who: address, amount: u64) {
        scenario.next_tx(who);
        let mut lock = scenario.take_shared<LockObject<SUI>>();
        let mut registry = scenario.take_shared<UsedSecretsRegistry>();
        escrow::withdrawPartial(&mut lock, &mut registry, clock, SECRET, amount, scenario.ctx());
        test::return_shared(lock);
        test::return_shared(registry);
    }

    fun remaining(scenario: &mut Scenario): (u64, bool) {
        let lock = scenario.take_shared<LockObject<SUI>>();
        let left = escrow::remainingAmount(&lock);
        let done = escrow::isFilled(&lock);
        test::return_shared(lock);
        (left, done)
    }

    fun received(scenario: &mut Scenario, who: address): u64 {
        scenario.next_tx(who);
        let c = scenario.take_from_address<Coin<SUI>>(who);
        let v = c.value();
        test::return_to_address(who, c);
        v
    }

    #[test]
    fun test_partial_fill_basic() {
        let (mut scenario, mut clock) = setup();
        clock.increment_for_testing(WITHDRAWAL);

        fill(&mut scenario, &clock, MAKER, 300);
        scenario.next_tx(MAKER);
        let (left, done) = remaining(&mut scenario);
        assert!(left == 700);
        assert!(!done);
        assert!(received(&mut scenario, MAKER) == 300);

        scenario.next_tx(MAKER);
        let registry = scenario.take_shared<UsedSecretsRegistry>();
        assert!(escrow::getUsedHashesCount(&registry) == 1);
        test::return_shared(registry);

        clock.destroy_for_testing();
        scenario.end();
    }

    #[test]
    fun test_multiple_partial_fills() {
        let (mut scenario, mut clock) = setup();
        clock.increment_for_testing(WITHDRAWAL);

        fill(&mut scenario, &clock, MAKER, 300);
        fill(&mut scenario, &clock, MAKER, 500);
        scenario.next_tx(MAKER);
        let (left, done) = remaining(&mut scenario);
        assert!(left == 200);
        assert!(!done);

        // Same secret reused across fills is recorded only once.
        let registry = scenario.take_shared<UsedSecretsRegistry>();
        assert!(escrow::getUsedHashesCount(&registry) == 1);
        test::return_shared(registry);

        clock.destroy_for_testing();
        scenario.end();
    }

    #[test]
    fun test_fill_escrow_completion() {
        let (mut scenario, mut clock) = setup();
        clock.increment_for_testing(WITHDRAWAL);

        fill(&mut scenario, &clock, MAKER, 400);
        fill(&mut scenario, &clock, MAKER, 600);
        scenario.next_tx(MAKER);
        let (left, done) = remaining(&mut scenario);
        assert!(left == 0);
        assert!(done);

        clock.destroy_for_testing();
        scenario.end();
    }

    #[test, expected_failure(abort_code = escrow::EInsufficientRemainingAmount)]
    fun test_fill_exceeds_remaining() {
        let (mut scenario, mut clock) = setup();
        clock.increment_for_testing(WITHDRAWAL);

        fill(&mut scenario, &clock, MAKER, 800);
        fill(&mut scenario, &clock, MAKER, 300);

        clock.destroy_for_testing();
        scenario.end();
    }

    #[test, expected_failure(abort_code = escrow::EInvalidFillAmount)]
    fun test_fill_zero_amount() {
        let (mut scenario, mut clock) = setup();
        clock.increment_for_testing(WITHDRAWAL);

        fill(&mut scenario, &clock, MAKER, 0);

        clock.destroy_for_testing();
        scenario.end();
    }

    #[test]
    fun test_cancel_partially_filled_escrow() {
        let (mut scenario, mut clock) = setup();
        clock.increment_for_testing(WITHDRAWAL);
        fill(&mut scenario, &clock, MAKER, 300);

        // Past the public cancellation window anyone may cancel; refund goes to MAKER.
        clock.increment_for_testing(PUBLIC_CANCELLATION);
        scenario.next_tx(RESOLVER1);
        let mut lock = scenario.take_shared<LockObject<SUI>>();
        escrow::cancel(&mut lock, &clock, scenario.ctx());
        test::return_shared(lock);

        // RESOLVER1 gets the safety deposit for doing the cancel.
        assert!(received(&mut scenario, RESOLVER1) == DEPOSIT);

        // MAKER holds two coins: the 300 fill and the 700 refund.
        scenario.next_tx(MAKER);
        let a = scenario.take_from_address<Coin<SUI>>(MAKER);
        let b = scenario.take_from_address<Coin<SUI>>(MAKER);
        assert!(a.value() + b.value() == TOTAL_AMOUNT);
        assert!(a.value() == 700 || b.value() == 700);
        test::return_to_address(MAKER, a);
        test::return_to_address(MAKER, b);

        clock.destroy_for_testing();
        scenario.end();
    }

    #[test]
    fun test_multiple_resolvers_competition() {
        let (mut scenario, mut clock) = setup();
        // In the public window any resolver can fill.
        clock.increment_for_testing(PUBLIC_WITHDRAWAL);

        fill(&mut scenario, &clock, RESOLVER1, 200);
        fill(&mut scenario, &clock, RESOLVER2, 300);
        fill(&mut scenario, &clock, RESOLVER3, 500);

        assert!(received(&mut scenario, RESOLVER1) == 200);
        assert!(received(&mut scenario, RESOLVER2) == 300);
        assert!(received(&mut scenario, RESOLVER3) == 500);
        let (left, done) = remaining(&mut scenario);
        assert!(left == 0);
        assert!(done);

        clock.destroy_for_testing();
        scenario.end();
    }

    #[test, expected_failure(abort_code = escrow::EWithdrawNotAllowed)]
    fun test_non_initiator_blocked_before_public_window() {
        let (mut scenario, mut clock) = setup();
        clock.increment_for_testing(WITHDRAWAL);

        fill(&mut scenario, &clock, RESOLVER1, 100);

        clock.destroy_for_testing();
        scenario.end();
    }
}
