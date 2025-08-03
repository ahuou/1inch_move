module oneinch_move::partial_fills {
    use std::hash;
    use std::string::String;

    use sui::coin::{Self as coin, Coin};
    use sui::clock::{Self as clock, Clock};
    use sui::event;

    //
    // Error codes
    //
    const ESecretLengthWrong: u64 = 1;
    const ESecretMerkleProofInvalid: u64 = 2;
    const ECancelNotAvailable: u64 = 3;
    const ECancelNotAllowed: u64 = 4;
    const EWithdrawNotAvailable: u64 = 5;
    const EWithdrawNotAllowed: u64 = 6;
    const EAmountTooLarge: u64 = 7;
    const EAmountTooSmall: u64 = 8;
    const EPartialNotAllowed: u64 = 9;
    const EMultipleFillsNotAllowed: u64 = 10;
    const EInvalidStage: u64 = 11;
    const EStageThresholdNotSatisfied: u64 = 13;

    const E_NOT_TAKER: u64 = 101;
    const E_ALREADY_FILLED: u64 = 102;
    const E_SECRET_ALREADY_USED: u64 = 103;

    //
    // Global registry to prevent secret reuse across orders
    //
    public struct UsedSecretsRegistry has key {
        id: UID,
        used_secrets: vector<vector<u8>>,
    }

    /// Initialize a shared UsedSecretsRegistry
    public entry fun init_registry(ctx: &mut TxContext) {
        let reg = UsedSecretsRegistry {
            id: object::new(ctx),
            used_secrets: vector::empty<vector<u8>>(),
        };
        // Because this is called outside the module that declares the type being shared,
        transfer::share_object(reg);
    }

    /// Helper: return true if secret was used globally
    public fun is_secret_used(registry: &UsedSecretsRegistry, secret: &vector<u8>): bool {
        let len = vector::length(&registry.used_secrets);
        let mut i = 0;
        while (i < len) {
            let s = vector::borrow(&registry.used_secrets, i);
            if (s == secret) return true;
            i = i + 1;
        };
        false
    }

    //
    // Lock object
    //
    #[allow(lint(coin_field))]
    public struct LockObject<phantom T> has key {
        id: UID,

        // === Timelocks ===
        created_at: u64,
        withdrawal: u64,           // After this, maker can withdraw
        public_withdrawal: u64,    // After this, anyone can withdraw
        cancellation: u64,         // After this, maker can cancel
        public_cancellation: u64,  // After this, anyone can cancel

        // === Merkle-based secrets ===
        merkle_root: vector<u8>,
        total_stages: u8,
        last_stage_claimed: u8,

        // === Participants ===
        maker: address,
        taker: address,          // @0x0 = anyone
        refund_adr: address,
        target_adr: address,

        // === Secret policy ===
        secret_length: u8,       // expected length in bytes

        // === Value state ===
        coin: Coin<T>,
        safety_deposit: Coin<T>, // pro-rata paid per fill
        initial_amount: u64,     // amount locked at creation
        filled_amount: u64,      // running total
        is_filled: bool,         // true after coin fully withdrawn

        // === Policy ===
        allow_partial: bool,
        allow_multiple: bool,
        min_partial: u64,

        // === Cross-chain metadata ===
        ethereum_order_hash: String,
    }

    //
    // Events
    //
    public struct NewLockEvent has copy, drop {
        lock: ID,
        merkle_root: vector<u8>,
        total_stages: u8,
        coin: ID,

        maker: address,
        taker: address,
        refund_adr: address,
        target_adr: address,
        withdrawal: u64,
        public_withdrawal: u64,
        cancellation: u64,
        public_cancellation: u64,

        secret_length: u8,
        initial_amount: u64,
        allow_partial: bool,
        allow_multiple: bool,
        min_partial: u64,
        ethereum_order_hash: String,
    }

    public struct LockClaimedEvent has copy, drop {
        lock: ID,
        secret: vector<u8>,
        claimer: address,
        ethereum_order_hash: String,
    }

    public struct LockPartiallyClaimedEvent has copy, drop {
        lock: ID,
        amount: u64,
        remaining: u64,
        stage_index: u8,
        claimer: address,
        ethereum_order_hash: String,
    }

    public struct LockFilledEvent has copy, drop {
        lock: ID,
        last_resolver: address,
        secret: vector<u8>,
        ethereum_order_hash: String,
    }

    public struct LockCancelledEvent has copy, drop {
        lock: ID,
        canceller: address,
        ethereum_order_hash: String,
    }

    public struct SafetyDepositClaimedEvent has copy, drop {
        lock: ID,
        receiver: address,
        ethereum_order_hash: String,
    }

    /// Creates a new lock with staged secrets (Merkle), optional taker control, and partial fill policies
    public entry fun create_lock_object<T>(
        clock_ref: &Clock,
        withdrawal_ms: u64,
        public_withdrawal_ms: u64,
        cancellation_ms: u64,
        public_cancellation_ms: u64,

        merkle_root: vector<u8>,
        total_stages: u8,

        maker: address,
        taker: address,              // If @0x0 => anyone can fill
        refund: address,
        target: address,

        secret_length: u8,

        amount: Coin<T>,
        deposit: Coin<T>,

        allow_partial: bool,
        allow_multiple: bool,
        min_partial: u64,

        ethereum_order_hash: String,

        ctx: &mut TxContext
    ) {
        let now = clock::timestamp_ms(clock_ref);
        let init_val = coin::value(&amount);

        let lock = LockObject {
            id: object::new(ctx),

            created_at: now,
            withdrawal: now + withdrawal_ms,
            public_withdrawal: now + public_withdrawal_ms,
            cancellation: now + cancellation_ms,
            public_cancellation: now + public_cancellation_ms,

            merkle_root,
            total_stages,
            last_stage_claimed: 0,

            maker,
            taker,
            refund_adr: refund,
            target_adr: target,

            secret_length,

            coin: amount,
            safety_deposit: deposit,
            initial_amount: init_val,
            filled_amount: 0,
            is_filled: false,

            allow_partial,
            allow_multiple,
            min_partial,

            ethereum_order_hash,
        };

        event::emit(NewLockEvent{
            lock: object::id(&lock),
            merkle_root: lock.merkle_root,
            total_stages: lock.total_stages,
            coin: object::id(&lock.coin),

            maker,
            taker,
            refund_adr: refund,
            target_adr: target,
            withdrawal: lock.withdrawal,
            public_withdrawal: lock.public_withdrawal,
            cancellation: lock.cancellation,
            public_cancellation: lock.public_cancellation,
            secret_length,
            initial_amount: init_val,
            allow_partial,
            allow_multiple,
            min_partial,
            ethereum_order_hash: lock.ethereum_order_hash,
        });

        transfer::share_object(lock);
    }

    /// Full withdrawal — requires secret + Merkle proof + stage threshold at final stage
    public entry fun withdraw_all<T>(
        lock: LockObject<T>,
        registry: &mut UsedSecretsRegistry,
        clock_ref: &Clock,
        secret: vector<u8>,
        proof_path: vector<vector<u8>>,
        stage_index: u8,
        ctx: &mut TxContext
    ) {
        let remaining = coin::value(&lock.coin);
        withdraw_partial<T>(lock, registry, clock_ref, secret, proof_path, stage_index, remaining, ctx);
    }

    /// Partial withdrawal with staged secret proof
    public entry fun withdraw_partial<T>(
        lock: LockObject<T>,
        registry: &mut UsedSecretsRegistry,
        clock_ref: &Clock,
        secret: vector<u8>,
        proof_path: vector<vector<u8>>,
        stage_index: u8,
        amount: u64,
        ctx: &mut TxContext
    ) {
        let lock_id = object::id(&lock);

        let LockObject {
            id,
            created_at,
            withdrawal,
            public_withdrawal,
            cancellation,
            public_cancellation,
            merkle_root,
            total_stages,
            last_stage_claimed,
            maker,
            taker,
            refund_adr,
            target_adr,
            secret_length,
            coin,
            safety_deposit,
            initial_amount,
            filled_amount,
            is_filled,
            allow_partial,
            allow_multiple,
            min_partial,
            ethereum_order_hash,
        } = lock;

        // Taker enforcement (if taker set)
        let sender = ctx.sender();
        if (taker != @0x0) {
            assert!(sender == taker, E_NOT_TAKER);
        };

        assert!(!is_filled, E_ALREADY_FILLED);

        // Timelock checks
        let now = clock::timestamp_ms(clock_ref);
        assert!(now >= withdrawal, EWithdrawNotAvailable);
        if (now < public_withdrawal) {
            // Before public window, maker controls redemption
            assert!(sender == maker, EWithdrawNotAllowed);
        };

        // Secret & registry check
        assert!(secret.length() == (secret_length as u64), ESecretLengthWrong);
        assert!(!is_secret_used(registry, &secret), E_SECRET_ALREADY_USED);

        // Merkle proof verification
        let leaf_hash = hash::sha2_256(secret);
        assert!(
            verify_merkle_proof(&leaf_hash, &proof_path, (stage_index as u64), &merkle_root),
            ESecretMerkleProofInvalid
        );

        // Fill policy
        assert!(allow_multiple, EMultipleFillsNotAllowed);
        assert!(allow_partial, EPartialNotAllowed);
        assert!(amount >= min_partial, EAmountTooSmall);
        assert!(stage_index > last_stage_claimed && stage_index <= total_stages, EInvalidStage);

        // Capacity
        let mut coin_mut = coin;
        let current_val = coin::value(&coin_mut);
        assert!(amount > 0 && amount <= current_val, EAmountTooLarge);

        // Stage threshold must be satisfied in cumulative terms
        let new_filled = filled_amount + amount;
        let threshold_amt = stage_threshold_amount(stage_index, total_stages, initial_amount);
        assert!(new_filled >= threshold_amt, EStageThresholdNotSatisfied);

        // Mark secret used globally
        vector::push_back(&mut registry.used_secrets, secret);

        // Transfer the partial
        let piece = coin::split(&mut coin_mut, amount, ctx);
        transfer::public_transfer(piece, target_adr);

        // Pro-rata safety deposit payout
        let mut dep_mut = safety_deposit;
        let total_dep = coin::value(&dep_mut);
        let share = (total_dep * amount) / initial_amount;
        if (share > 0) {
            let reward = coin::split(&mut dep_mut, share, ctx);
            transfer::public_transfer(reward, sender);

            event::emit(SafetyDepositClaimedEvent{
                lock: lock_id,
                receiver: sender,
                ethereum_order_hash: ethereum_order_hash,
            });
        };

        // Events
        event::emit(LockClaimedEvent{
            lock: lock_id,
            secret: secret,
            claimer: sender,
            ethereum_order_hash: ethereum_order_hash,
        });

        let remaining_val = coin::value(&coin_mut);
        event::emit(LockPartiallyClaimedEvent{
            lock: lock_id,
            amount: amount,
            remaining: remaining_val,
            stage_index: stage_index,
            claimer: sender,
            ethereum_order_hash: ethereum_order_hash,
        });

        // Finish or reshare
        object::delete(id);

        if (remaining_val == 0) {
            let leftover_dep = coin::value(&dep_mut);
            if (leftover_dep > 0) {
                transfer::public_transfer(dep_mut, sender);
                event::emit(SafetyDepositClaimedEvent{
                    lock: lock_id,
                    receiver: sender,
                    ethereum_order_hash: ethereum_order_hash,
                });
            } else {
                coin::destroy_zero(dep_mut);
            };
            coin::destroy_zero(coin_mut);

            event::emit(LockFilledEvent{
                lock: lock_id,
                last_resolver: sender,
                secret: secret,
                ethereum_order_hash: ethereum_order_hash,
            });
        } else {
            let updated_lock = LockObject {
                id: object::new(ctx),

                created_at,
                withdrawal, public_withdrawal,
                cancellation, public_cancellation,

                merkle_root,
                total_stages,
                last_stage_claimed: stage_index,

                maker,
                taker,
                refund_adr,
                target_adr,

                secret_length,

                coin: coin_mut,
                safety_deposit: dep_mut,
                initial_amount,
                filled_amount: new_filled,
                is_filled: false,

                allow_partial,
                allow_multiple,
                min_partial,

                ethereum_order_hash,
            };
            transfer::share_object(updated_lock);
        }
    }

    /// Cancels the lock and returns the assets
    public entry fun cancel<T>(
        lock: LockObject<T>,
        clock_ref: &Clock,
        ctx: &mut TxContext
    ) {
        let lock_id = object::id(&lock);
        let now = clock::timestamp_ms(clock_ref);

        assert!(now >= lock.cancellation, ECancelNotAvailable);
        if (now < lock.public_cancellation) {
            assert!(ctx.sender() == lock.maker, ECancelNotAllowed);
        };

        event::emit(LockCancelledEvent{
            lock: lock_id,
            canceller: ctx.sender(),
            ethereum_order_hash: lock.ethereum_order_hash,
        });

        event::emit(SafetyDepositClaimedEvent{
            lock: lock_id,
            receiver: ctx.sender(),
            ethereum_order_hash: lock.ethereum_order_hash,
        });

        let LockObject {
            id, coin, refund_adr, safety_deposit,
            ..
        } = lock;

        transfer::public_transfer(safety_deposit, ctx.sender());
        transfer::public_transfer(coin, refund_adr);
        object::delete(id);
    }

    //
    // === Helpers ===
    //

    /// Verify Merkle path from leaf to root
    fun verify_merkle_proof(
        leaf_hash: &vector<u8>,
        proof: &vector<vector<u8>>,
        index: u64,
        root: &vector<u8>
    ): bool {
        let mut acc = *leaf_hash;
        let mut idx = index;

        let n = vector::length(proof);
        let mut i = 0;
        while (i < n) {
            let sibling = *vector::borrow(proof, i);
            let pair = if (idx % 2 == 0) { concat(&acc, &sibling) } else { concat(&sibling, &acc) };
            acc = hash::sha2_256(pair);
            idx = idx / 2;
            i = i + 1;
        };
        acc == *root
    }

    fun concat(a: &vector<u8>, b: &vector<u8>): vector<u8> {
        let mut out = vector::empty<u8>();
        let la = vector::length(a);
        let lb = vector::length(b);

        let mut i = 0;
        while (i < la) {
            vector::push_back(&mut out, *vector::borrow(a, i));
            i = i + 1;
        };
        i = 0;
        while (i < lb) {
            vector::push_back(&mut out, *vector::borrow(b, i));
            i = i + 1;
        };
        out
    }

    fun stage_threshold_amount(
        stage_index: u8,
        total_stages: u8,
        initial_amount: u64
    ): u64 {
        (initial_amount * (stage_index as u64)) / (total_stages as u64)
    }
}