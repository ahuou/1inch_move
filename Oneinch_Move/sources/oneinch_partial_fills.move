module oneinch_move::partial_fills {
    use std::string::String;
    use std::vector;
    use sui::event;

    use sui::hash;
    use sui::clock;
    use sui::tx_context;
    use sui::transfer;

    /// Errors actually used by the module.
    const ESecretPreimageWrong: u64 = 1;
    const ESecretLengthWrong: u64 = 2;
    const ECancelNotAvailable: u64 = 3;
    const ECancelNotAllowed: u64 = 4;
    const EWithdrawNotAvailable: u64 = 5;
    const EWithdrawNotAllowed: u64 = 6;
    const EInvalidSecret: u64 = 12;
    const EInsufficientRemainingAmount: u64 = 16;
    const EInvalidFillAmount: u64 = 17;
    const EEmptySecret: u64 = 18;

    /// Track hashes of secrets that have been revealed/used.
    public struct UsedSecretsRegistry has key {
        id: sui::object::UID,
        used_hashes: vector<vector<u8>>,
    }

    /// Create and share the registry.
    fun init(ctx: &mut tx_context::TxContext) {
        let registry = UsedSecretsRegistry {
            id: sui::object::new(ctx),
            used_hashes: std::vector::empty(),
        };
        transfer::share_object(registry);
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut tx_context::TxContext) { init(ctx) }

    /// Hash-timelock with partial fills. Store fungible value as Balance<T>.
    public struct LockObject<phantom T> has key, store {
        id: sui::object::UID,

        // timing
        created_at: u64,
        withdrawal: u64,
        public_withdrawal: u64,
        cancellation: u64,
        public_cancellation: u64,

        // secret/hash
        hashed: vector<u8>,
        secret_length: u8,

        // participants
        refund_adr: address,
        target_adr: address,
        initiator: address,

        // value
        coin: sui::balance::Balance<T>,
        safety_deposit: sui::balance::Balance<T>,

        // state
        remaining_amount: u64,
        is_filled: bool,

        // reference data
        ethereum_order_hash: String,
    }

    // -------- Events --------

    public struct NewLockEvent has copy, drop {
        lock: sui::object::ID,
        hash: vector<u8>,
        amount_locked: u64,
        refund_adr: address,
        target_adr: address,
        initiator: address,
        withdrawal: u64,
        public_withdrawal: u64,
        cancellation: u64,
        public_cancellation: u64,
        secret_length: u8,
        ethereum_order_hash: String,
    }

    public struct LockClaimedEvent has copy, drop {
        lock: sui::object::ID,
        secret: vector<u8>,
        claimer: address,
        ethereum_order_hash: String,
    }

    public struct LockPartiallyClaimedEvent has copy, drop {
        lock: sui::object::ID,
        amount: u64,
        remaining_amount: u64,
        claimer: address,
        ethereum_order_hash: String,
    }

    public struct LockCancelledEvent has copy, drop {
        lock: sui::object::ID,
        canceller: address,
        ethereum_order_hash: String,
    }

    public struct SafetyDepositClaimedEvent has copy, drop {
        lock: sui::object::ID,
        receiver: address,
    }

    // -------- Entry functions --------

    /// Create and share a new lock. Incoming coins are converted to balances for storage.
    public entry fun createLockObject<T>(
        clock_obj: &clock::Clock,
        withdrawal_ms: u64,
        public_withdrawal_ms: u64,
        cancellation_ms: u64,
        public_cancellation_ms: u64,
        hashed: vector<u8>,
        target: address,
        refund: address,
        amount: sui::coin::Coin<T>,
        deposit: sui::coin::Coin<T>,
        secret_length: u8,
        ethereum_order_hash: String,
        ctx: &mut tx_context::TxContext
    ) {
        let now = clock::timestamp_ms(clock_obj);
        let amount_bal = sui::coin::into_balance(amount);
        let deposit_bal = sui::coin::into_balance(deposit);

        let lock = LockObject {
            id: sui::object::new(ctx),
            created_at: now,
            withdrawal: now + withdrawal_ms,
            public_withdrawal: now + public_withdrawal_ms,
            cancellation: now + cancellation_ms,
            public_cancellation: now + public_cancellation_ms,
            hashed,
            refund_adr: refund,
            target_adr: target,
            initiator: tx_context::sender(ctx),
            secret_length,
            remaining_amount: sui::balance::value(&amount_bal),
            coin: amount_bal,
            safety_deposit: deposit_bal,
            is_filled: false,
            ethereum_order_hash,
        };

        // Emit event before sharing.
        event::emit(NewLockEvent {
            lock: sui::object::uid_to_inner(&lock.id),
            hash: lock.hashed,
            amount_locked: sui::balance::value(&lock.coin),
            refund_adr: refund,
            target_adr: target,
            initiator: lock.initiator,
            withdrawal: lock.withdrawal,
            public_withdrawal: lock.public_withdrawal,
            cancellation: lock.cancellation,
            public_cancellation: lock.public_cancellation,
            secret_length,
            ethereum_order_hash: lock.ethereum_order_hash,
        });

        transfer::share_object(lock);
    }

    /// Withdraw the full remaining amount if the hash-preimage and time window are valid.
    public entry fun withdraw<T>(
        lock: &mut LockObject<T>,
        registry: &mut UsedSecretsRegistry,
        clock_obj: &clock::Clock,
        secret: vector<u8>,
        ctx: &mut tx_context::TxContext
    ) {
        let now = clock::timestamp_ms(clock_obj);
        assert!(now >= lock.withdrawal, EWithdrawNotAvailable);
        if (now < lock.public_withdrawal) {
            assert!(tx_context::sender(ctx) == lock.initiator, EWithdrawNotAllowed);
        };
        assert!(lock.secret_length as u64 == std::vector::length(&secret), ESecretLengthWrong);
        assert!(hash::keccak256(&secret) == lock.hashed, ESecretPreimageWrong);

        // Record the used hash the first time we see it.
        let h = hash::keccak256(&secret);
        if (!is_hash_used(registry, &h)) {
            std::vector::push_back(&mut registry.used_hashes, h);
        };

        // Drain remaining amount.
        let to_send = lock.remaining_amount;
        lock.remaining_amount = 0;
        lock.is_filled = true;

        // Emit events.
        event::emit(LockClaimedEvent {
            lock: sui::object::uid_to_inner(&lock.id),
            secret,
            claimer: tx_context::sender(ctx),
            ethereum_order_hash: lock.ethereum_order_hash,
        });
        event::emit(SafetyDepositClaimedEvent {
            lock: sui::object::uid_to_inner(&lock.id),
            receiver: tx_context::sender(ctx),
        });

        // Move funds out of the shared object and transfer.
        let bal = sui::balance::split(&mut lock.coin, to_send);
        let coin = sui::coin::from_balance(bal, ctx);
        transfer::public_transfer(coin, lock.target_adr);

        let dep = sui::balance::value(&lock.safety_deposit);
        if (dep > 0) {
            let sd_bal = sui::balance::split(&mut lock.safety_deposit, dep);
            let sd = sui::coin::from_balance(sd_bal, ctx);
            transfer::public_transfer(sd, tx_context::sender(ctx));
        };
        // Do not delete shared objects; leave it marked as filled.
    }

    /// Partially withdraw a specified `amount`. No return value; transfer the split coin.
    public entry fun withdrawPartial<T>(
        lock: &mut LockObject<T>,
        registry: &mut UsedSecretsRegistry,
        clock_obj: &clock::Clock,
        secret: vector<u8>,
        amount: u64,
        ctx: &mut tx_context::TxContext
    ) {
        let now = clock::timestamp_ms(clock_obj);
        assert!(now >= lock.withdrawal, EWithdrawNotAvailable);
        if (now < lock.public_withdrawal) {
            assert!(tx_context::sender(ctx) == lock.initiator, EWithdrawNotAllowed);
        };
        assert!(lock.secret_length as u64 == std::vector::length(&secret), ESecretLengthWrong);
        assert!(hash::keccak256(&secret) == lock.hashed, ESecretPreimageWrong);
        assert!(amount > 0, EInvalidFillAmount);
        assert!(amount <= lock.remaining_amount, EInsufficientRemainingAmount);

        // Record the used hash once.
        let h = hash::keccak256(&secret);
        if (!is_hash_used(registry, &h)) {
            std::vector::push_back(&mut registry.used_hashes, h);
        };

        // Update remaining and split out the requested amount.
        lock.remaining_amount = lock.remaining_amount - amount;
        let is_completed = lock.remaining_amount == 0;
        if (is_completed) {
            lock.is_filled = true;
        };

        let part_bal = sui::balance::split(&mut lock.coin, amount);
        let part = sui::coin::from_balance(part_bal, ctx);

        if (is_completed) {
            event::emit(LockClaimedEvent {
                lock: sui::object::uid_to_inner(&lock.id),
                secret,
                claimer: tx_context::sender(ctx),
                ethereum_order_hash: lock.ethereum_order_hash,
            });
        } else {
            event::emit(LockPartiallyClaimedEvent {
                lock: sui::object::uid_to_inner(&lock.id),
                amount,
                remaining_amount: lock.remaining_amount,
                claimer: tx_context::sender(ctx),
                ethereum_order_hash: lock.ethereum_order_hash,
            });
        };

        // (Do not touch the safety deposit here; claim it only on full withdraw/cancel.)
        transfer::public_transfer(part, tx_context::sender(ctx));
    }

    /// Cancel the lock and refund to `refund_adr` if in the allowed time window.
    public entry fun cancel<T>(
        lock: &mut LockObject<T>,
        clock_obj: &clock::Clock,
        ctx: &mut tx_context::TxContext
    ) {
        let now = clock::timestamp_ms(clock_obj);
        assert!(now >= lock.cancellation, ECancelNotAvailable);
        if (now < lock.public_cancellation) {
            assert!(tx_context::sender(ctx) == lock.initiator, ECancelNotAllowed);
        };

        event::emit(LockCancelledEvent {
            lock: sui::object::uid_to_inner(&lock.id),
            canceller: tx_context::sender(ctx),
            ethereum_order_hash: lock.ethereum_order_hash,
        });
        event::emit(SafetyDepositClaimedEvent {
            lock: sui::object::uid_to_inner(&lock.id),
            receiver: tx_context::sender(ctx),
        });

        // Refund principal and safety deposit.
        let amt = sui::balance::value(&lock.coin);
        if (amt > 0) {
            let c_bal = sui::balance::split(&mut lock.coin, amt);
            let c = sui::coin::from_balance(c_bal, ctx);
            transfer::public_transfer(c, lock.refund_adr);
        };
        let dep = sui::balance::value(&lock.safety_deposit);
        if (dep > 0) {
            let sd_bal = sui::balance::split(&mut lock.safety_deposit, dep);
            let sd = sui::coin::from_balance(sd_bal, ctx);
            transfer::public_transfer(sd, tx_context::sender(ctx));
        };
        // Do not delete shared objects.
    }

    // -------- Utilities --------

    public fun verifySecret(secret: vector<u8>, hash_lock: vector<u8>): bool {
        if (std::vector::is_empty(&secret)) { return false };
        let computed = hash::keccak256(&secret);
        computed == hash_lock
    }

    public fun createHashLock(secret: vector<u8>): vector<u8> {
        assert!(!std::vector::is_empty(&secret), EEmptySecret);
        hash::keccak256(&secret)
    }

    public fun isExpired(time_lock: u64, clock_obj: &clock::Clock): bool {
        clock::timestamp_ms(clock_obj) > time_lock
    }

    public fun isValidTimeLock(time_lock: u64, clock_obj: &clock::Clock): bool {
        time_lock > clock::timestamp_ms(clock_obj)
    }

    public fun isActive(time_lock: u64, clock_obj: &clock::Clock): bool {
        !isExpired(time_lock, clock_obj)
    }

    public fun getRemainingTime(time_lock: u64, clock_obj: &clock::Clock): u64 {
        let now = clock::timestamp_ms(clock_obj);
        if (now >= time_lock) { 0 } else { time_lock - now }
    }

    public fun createTimeLock(duration: u64, clock_obj: &clock::Clock): u64 {
        clock::timestamp_ms(clock_obj) + duration
    }

    // Durations
    public fun standardDuration(): u64 { 3_600_000 }   // 1 hour
    public fun extendedDuration(): u64 { 86_400_000 }  // 24 hours
    public fun shortDuration(): u64 { 900_000 }        // 15 minutes

    public fun is_hash_used(registry: &UsedSecretsRegistry, h: &vector<u8>): bool {
        let mut i = 0;
        let n = std::vector::length(&registry.used_hashes);
        while (i < n) {
            let seen = std::vector::borrow(&registry.used_hashes, i);
            if (seen == h) { return true };
            i = i + 1;
        };
        false
    }

    public fun getUsedHashesCount(registry: &UsedSecretsRegistry): u64 {
        std::vector::length(&registry.used_hashes)
    }

    public fun createBatchHashLocks(secrets: vector<vector<u8>>): vector<vector<u8>> {
        let mut out = std::vector::empty();
        let mut i = 0;
        let n = std::vector::length(&secrets);
        while (i < n) {
            let sref = std::vector::borrow(&secrets, i);
            let h = hash::keccak256(sref);
            std::vector::push_back(&mut out, h);
            i = i + 1;
        };
        out
    }

    #[test_only]
    public fun testHashLockFunctionality() {
        let secret = b"test_secret";
        let lock_h = createHashLock(secret);
        assert!(verifySecret(secret, lock_h), EInvalidSecret);

        let wrong = b"wrong_secret";
        assert!(!verifySecret(wrong, lock_h), EInvalidSecret);
    }
}