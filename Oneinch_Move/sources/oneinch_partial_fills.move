module oneinch_move::partial_fills {
    use sui::balance::{Self, Balance};
    use sui::coin::{Self, Coin};
    use sui::clock::{Self, Clock};
    use sui::event;
    use sui::hash;
    use std::string::String;

    const E_INVALID_TIME_LOCK: u64 = 1;
    const E_INVALID_AMOUNT: u64 = 2;
    const E_NOT_TAKER: u64 = 3;
    const E_ALREADY_FILLED: u64 = 4;
    const E_EXPIRED: u64 = 5;
    const E_INVALID_SECRET: u64 = 6;
    const E_NOT_MAKER: u64 = 7;
    const E_NOT_EXPIRED: u64 = 8;
    const E_SECRET_ALREADY_USED: u64 = 9;
    const E_INSUFFICIENT_REMAINING_AMOUNT: u64 = 10;
    const E_INVALID_FILL_AMOUNT: u64 = 11;
    const E_EMPTY_SECRET: u64 = 13;
    const E_TIME_LOCK_EXPIRED: u64 = 14;

    public struct UsedSecretsRegistry has key {
        id: sui::object::UID,
        used_secrets: vector<vector<u8>>,
    }

    fun init(ctx: &mut sui::tx_context::TxContext) {
        let registry = UsedSecretsRegistry {
            id: sui::object::new(ctx),
            used_secrets: std::vector::empty(),
        };
        sui::transfer::share_object(registry);
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut sui::tx_context::TxContext) {
        init(ctx);
    }

    public struct CrossChainEscrow<phantom T> has key, store {
        id: UID,
        maker: address,
        taker: address,
        total_amount: u64,
        remaining_amount: u64,
        balance: Balance<T>,
        hash_lock: vector<u8>,
        time_lock: u64,
        is_filled: bool,
        created_at: u64,
        ethereum_order_hash: String,
        secret: vector<u8>,
    }

    public struct EscrowCreated has copy, drop {
        escrow_id: ID,
        maker: address,
        taker: address,
        amount: u64,
        hash_lock: vector<u8>,
        time_lock: u64,
        ethereum_order_hash: String,
    }

    public struct EscrowPartiallyFilled has copy, drop {
        escrow_id: ID,
        resolver: address,
        amount: u64,
        remaining_amount: u64,
        secret: vector<u8>,
        ethereum_order_hash: String,
    }
    
    public struct EscrowFilled has copy, drop {
        escrow_id: ID,
        last_resolver: address,
        secret: vector<u8>,
        ethereum_order_hash: String,
    }

    public struct EscrowCancelled has copy, drop {
        escrow_id: ID,
        maker: address,
        ethereum_order_hash: String,
    }

    public struct EscrowRefunded has copy, drop {
        escrow_id: ID,
        maker: address,
        amount: u64,
        ethereum_order_hash: String,
    }

    fun verify_secret(secret: vector<u8>, hash_lock: vector<u8>): bool {
        if (std::vector::is_empty(&secret)) {
            return false
        };
        
        let computed_hash = hash::keccak256(&secret);
        computed_hash == hash_lock
    }

    fun create_hash_lock_internal(secret: vector<u8>): vector<u8> {
        assert!(!std::vector::is_empty(&secret), E_EMPTY_SECRET);
        hash::keccak256(&secret)
    }

    fun is_valid_hash_lock(hash_lock: &vector<u8>): bool {
        !std::vector::is_empty(hash_lock) && std::vector::length(hash_lock) == 32
    }

    fun generate_test_secret(seed: u64): vector<u8> {
        let mut secret = std::vector::empty<u8>();
        let mut i = 0;
        while (i < 32) {
            let byte = ((seed + i) % 256) as u8;
            std::vector::push_back(&mut secret, byte);
            i = i + 1;
        };
        secret
    }

    fun create_batch_hash_locks_internal(secrets: vector<vector<u8>>): vector<vector<u8>> {
        let mut result = std::vector::empty();
        let mut i = 0;
        let len = std::vector::length(&secrets);
        while (i < len) {
            let secret = std::vector::borrow(&secrets, i);
            let hash_lock = hash::keccak256(secret);
            std::vector::push_back(&mut result, hash_lock);
            i = i + 1;
        };
        result
    }

    fun are_equal(hash_lock1: &vector<u8>, hash_lock2: &vector<u8>): bool {
        hash_lock1 == hash_lock2
    }

    fun is_expired(time_lock: u64, clock: &Clock): bool {
        clock::timestamp_ms(clock) > time_lock
    }

    fun is_valid_time_lock(time_lock: u64, clock: &Clock): bool {
        time_lock > clock::timestamp_ms(clock)
    }

    fun get_remaining_time(time_lock: u64, clock: &Clock): u64 {
        let current_time = clock::timestamp_ms(clock);
        if (current_time >= time_lock) {
            0
        } else {
            time_lock - current_time
        }
    }

    fun create_time_lock(duration: u64, clock: &Clock): u64 {
        clock::timestamp_ms(clock) + duration
    }

    // Duration constants
    fun standard_duration(): u64 { 3600000 }  // 1 hour
    fun extended_duration(): u64 { 86400000 } // 24 hours
    fun short_duration(): u64 { 900000 }      // 15 minutes


    fun can_withdraw(time_lock: u64, clock: &Clock): bool {
        is_expired(time_lock, clock)
    }

    fun is_active(time_lock: u64, clock: &Clock): bool {
        !is_expired(time_lock, clock)
    }

    fun validate_time_lock(time_lock: u64, clock: &Clock): bool {
        is_valid_time_lock(time_lock, clock)
    }

    // Main escrow creation 
    public fun create_escrow<T>(
        coin: Coin<T>,
        taker: address,
        hash_lock: vector<u8>,
        time_lock: u64,
        ethereum_order_hash: String,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): CrossChainEscrow<T> {
        let amount = coin::value(&coin);
        let maker = sui::tx_context::sender(ctx);
        let current_time = clock::timestamp_ms(clock);
        
        assert!(is_valid_time_lock(time_lock, clock), E_INVALID_TIME_LOCK);
        assert!(amount > 0, E_INVALID_AMOUNT);
        
        let escrow_uid = sui::object::new(ctx);
        let escrow_id = sui::object::uid_to_inner(&escrow_uid);
        
        let escrow = CrossChainEscrow<T> {
            id: escrow_uid,
            maker,
            taker,
            total_amount: amount,
            remaining_amount: amount,
            balance: coin::into_balance(coin),
            hash_lock,
            time_lock,
            is_filled: false,
            created_at: current_time,
            ethereum_order_hash,
            secret: std::vector::empty(),
        };

        event::emit(EscrowCreated {
            escrow_id,
            maker,
            taker,
            amount,
            hash_lock,
            time_lock,
            ethereum_order_hash,
        });

        escrow
    }

    public fun create_and_share_escrow<T>(
        coin: Coin<T>,
        taker: address,
        hash_lock: vector<u8>,
        time_lock: u64,
        ethereum_order_hash: String,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): sui::object::ID {
        let amount = coin::value(&coin);
        let maker = sui::tx_context::sender(ctx);
        let current_time = clock::timestamp_ms(clock);
        
        assert!(is_valid_time_lock(time_lock, clock), E_INVALID_TIME_LOCK);
        assert!(amount > 0, E_INVALID_AMOUNT);
        
        let escrow_uid = sui::object::new(ctx);
        let escrow_id = sui::object::uid_to_inner(&escrow_uid);
        
        let escrow = CrossChainEscrow<T> {
            id: escrow_uid,
            maker,
            taker,
            total_amount: amount,
            remaining_amount: amount,
            balance: coin::into_balance(coin),
            hash_lock,
            time_lock,
            is_filled: false,
            created_at: current_time,
            ethereum_order_hash,
            secret: std::vector::empty(),
        };

        event::emit(EscrowCreated {
            escrow_id,
            maker,
            taker,
            amount,
            hash_lock,
            time_lock,
            ethereum_order_hash,
        });

        sui::transfer::share_object(escrow);
        
        escrow_id
    }

    public fun share_escrow<T>(escrow: CrossChainEscrow<T>) {
        sui::transfer::share_object(escrow);
    }

    public fun fill_escrow_partial<T>(
        escrow: &mut CrossChainEscrow<T>,
        registry: &mut UsedSecretsRegistry,
        amount: u64,
        secret: vector<u8>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): Coin<T> {
        let sender = sui::tx_context::sender(ctx);
        let _current_time = clock::timestamp_ms(clock);
        
        if (escrow.taker != @0x0) {
            assert!(sender == escrow.taker, E_NOT_TAKER);
        };
        assert!(!escrow.is_filled, E_ALREADY_FILLED);
        assert!(!is_expired(escrow.time_lock, clock), E_EXPIRED);
        assert!(verify_secret(secret, escrow.hash_lock), E_INVALID_SECRET);
        if (!std::vector::is_empty(&escrow.secret)) {
            assert!(escrow.secret == secret, E_INVALID_SECRET);
        } else {
            assert!(!is_secret_used(registry, &secret), E_SECRET_ALREADY_USED);
        };
        assert!(amount > 0, E_INVALID_FILL_AMOUNT);
        assert!(amount <= escrow.remaining_amount, E_INSUFFICIENT_REMAINING_AMOUNT);
        
        escrow.remaining_amount = escrow.remaining_amount - amount;
        
        if (std::vector::is_empty(&escrow.secret)) {
            escrow.secret = secret;
            std::vector::push_back(&mut registry.used_secrets, secret);
        };
        
        let is_completed = escrow.remaining_amount == 0;
        if (is_completed) {
            escrow.is_filled = true;
        };
        
        let coin = coin::from_balance(balance::split(&mut escrow.balance, amount), ctx);
        
        if (is_completed) {
            event::emit(EscrowFilled {
                escrow_id: sui::object::uid_to_inner(&escrow.id),
                last_resolver: sender,
                secret,
                ethereum_order_hash: escrow.ethereum_order_hash,
            });
        } else {
            event::emit(EscrowPartiallyFilled {
                escrow_id: sui::object::uid_to_inner(&escrow.id),
                resolver: sender,
                amount,
                remaining_amount: escrow.remaining_amount,
                secret,
                ethereum_order_hash: escrow.ethereum_order_hash,
            });
        };

        coin
    }
    
    public fun fill_escrow<T>(
        escrow: &mut CrossChainEscrow<T>,
        registry: &mut UsedSecretsRegistry,
        secret: vector<u8>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): Coin<T> {
        assert!(escrow.remaining_amount > 0, E_ALREADY_FILLED);
        
        let remaining_amount = escrow.remaining_amount;
        fill_escrow_partial(escrow, registry, remaining_amount, secret, clock, ctx)
    }

    public fun cancel_escrow<T>(
        escrow: &mut CrossChainEscrow<T>,
        clock: &Clock,
        ctx: &mut sui::tx_context::TxContext
    ): Coin<T> {
        let sender = sui::tx_context::sender(ctx);
        let _current_time = clock::timestamp_ms(clock);
        
        assert!(sender == escrow.maker, E_NOT_MAKER);
        assert!(!escrow.is_filled, E_ALREADY_FILLED);
        assert!(is_expired(escrow.time_lock, clock), E_NOT_EXPIRED);
        
        let amount = escrow.remaining_amount;
        let coin = coin::from_balance(balance::withdraw_all(&mut escrow.balance), ctx);
        
        event::emit(EscrowRefunded {
            escrow_id: sui::object::uid_to_inner(&escrow.id),
            maker: sender,
            amount,
            ethereum_order_hash: escrow.ethereum_order_hash,
        });

        coin
    }

    public fun verify_secret_public(
        secret: vector<u8>,
        hash_lock: vector<u8>
    ): bool {
        verify_secret(secret, hash_lock)
    }

    public fun create_hash_lock(secret: vector<u8>): vector<u8> {
        create_hash_lock_internal(secret)
    }

    public fun get_escrow_info<T>(escrow: &CrossChainEscrow<T>): (
        address, address, u64, u64, vector<u8>, u64, bool, u64, String
    ) {
        (
            escrow.maker,
            escrow.taker,
            escrow.total_amount,
            escrow.remaining_amount,
            escrow.hash_lock,
            escrow.time_lock,
            escrow.is_filled,
            escrow.created_at,
            escrow.ethereum_order_hash
        )
    }
    
    public fun get_remaining_amount<T>(escrow: &CrossChainEscrow<T>): u64 {
        escrow.remaining_amount
    }

    public fun is_expired_public<T>(escrow: &CrossChainEscrow<T>, clock: &Clock): bool {
        is_expired(escrow.time_lock, clock)
    }

    public fun can_fill<T>(escrow: &CrossChainEscrow<T>, clock: &Clock): bool {
        !escrow.is_filled && is_active(escrow.time_lock, clock)
    }

    public fun get_secret<T>(escrow: &CrossChainEscrow<T>): vector<u8> {
        escrow.secret
    }

    public fun is_secret_used(registry: &UsedSecretsRegistry, secret: &vector<u8>): bool {
        let mut i = 0;
        let len = std::vector::length(&registry.used_secrets);
        while (i < len) {
            let used_secret = std::vector::borrow(&registry.used_secrets, i);
            if (used_secret == secret) {
                return true
            };
            i = i + 1;
        };
        false
    }

    public fun get_used_secrets_count(registry: &UsedSecretsRegistry): u64 {
        std::vector::length(&registry.used_secrets)
    }

    public fun create_batch_hash_locks(secrets: vector<vector<u8>>): vector<vector<u8>> {
        create_batch_hash_locks_internal(secrets)
    }

    #[test_only]
    public fun test_hash_lock_functionality() {
        let secret = b"test_secret";
        let hash_lock = create_hash_lock_internal(secret);
        assert!(verify_secret(secret, hash_lock), E_INVALID_SECRET);
        
        let wrong_secret = b"wrong_secret";
        assert!(!verify_secret(wrong_secret, hash_lock), E_INVALID_SECRET);
    }

    #[test_only]
    public fun test_time_lock_functionality(clock: &Clock) {
        let duration = standard_duration();
        let time_lock = create_time_lock(duration, clock);
        
        assert!(is_valid_time_lock(time_lock, clock), E_INVALID_TIME_LOCK);
        assert!(is_active(time_lock, clock), E_TIME_LOCK_EXPIRED);
        assert!(!is_expired(time_lock, clock), E_TIME_LOCK_EXPIRED);
    }
}