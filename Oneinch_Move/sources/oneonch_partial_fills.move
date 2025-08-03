module oneinch_move::partial_fills {
    use std::hash;
    use sui::coin::{Self as coin, Coin};
    use sui::clock::{Self as clock, Clock};
    use sui::event;

    //
    // Error codes
    //
    const ESecretPreimageWrong: u64 = 1;
    const ESecretLengthWrong: u64 = 2;
    const ECancelNotAvailable: u64 = 3;
    const ECancelNotAllowed: u64 = 4;
    const EWithdrawNotAvailable: u64 = 5;
    const EWithdrawNotAllowed: u64 = 6;
    const EAmountTooLarge: u64 = 7;
    const EAmountTooSmall: u64 = 8;
    const EPartialNotAllowed: u64 = 9;
    const EMultipleFillsNotAllowed: u64 = 10;

    //
    // Lock object
    //
    #[allow(lint(coin_field))]
    public struct LockObject<phantom T> has key {
        id: UID,

        // === Timelock + metadata ===
        created_at: u64,
        withdrawal: u64,
        public_withdrawal: u64,
        cancellation: u64,
        public_cancellation: u64,

        // === Hashlock ===
        hashed: vector<u8>,

        // === Participants ===
        refund_adr: address,
        target_adr: address,
        initiator: address,

        // === Secret policy ===
        secret_length: u8,

        // === Value state ===
        coin: Coin<T>,
        safety_deposit: Coin<T>,   // pro-rata paid per partial or final fill

        // === Partial/Multi-fill policy ===
        initial_amount: u64,       // value at creation time
        allow_partial: bool,       // mimic 1inch allowPartialFills
        allow_multiple: bool,      // mimic 1inch allowMultipleFills
        min_partial: u64,          // minimum size of a partial fill
    }

    //
    // Events
    //
    public struct NewLockEvent has copy, drop {
        lock: ID,
        hash: vector<u8>,
        coin: ID,
        refund_adr: address,
        target_adr: address,
        initiator: address,
        withdrawal: u64,
        public_withdrawal: u64,
        cancellation: u64,
        public_cancellation: u64,
        secret_length: u8,
    }

    public struct LockClaimedEvent has copy, drop {
        lock: ID,
        secret: vector<u8>,
        claimer: address,
    }

    public struct LockPartiallyClaimedEvent has copy, drop {
        lock: ID,
        amount: u64,
        remaining: u64,
        claimer: address,
    }

    public struct LockCancelledEvent has copy, drop {
        lock: ID,
        canceller: address,
    }

    public struct SafetyDepositClaimedEvent has copy, drop {
        lock: ID,
        receiver: address,
    }

    ///
    /// Creates a new HTLC-like shared lock object with partial fill support.
    ///
    public entry fun create_lock_object<T>(
        clock_ref: &Clock,

        withdrawal_ms: u64,
        public_withdrawal_ms: u64,
        cancellation_ms: u64,
        public_cancellation_ms: u64,

        hashed: vector<u8>,
        target: address,
        refund: address,

        amount: Coin<T>,
        deposit: Coin<T>,
        secret_length: u8,

        // new flags & minimum partial policy
        allow_partial: bool,
        allow_multiple: bool,
        min_partial: u64,

        ctx: &mut TxContext
    ) {
        let now = clock::timestamp_ms(clock_ref);
        let init_val = coin::value(&amount);

        let lock = LockObject {
            id: object::new(ctx),

            // timelock schedule
            created_at: now,
            withdrawal: now + withdrawal_ms,
            public_withdrawal: now + public_withdrawal_ms,
            cancellation: now + cancellation_ms,
            public_cancellation: now + public_cancellation_ms,

            // hashlock
            hashed,

            // participants
            refund_adr: refund,
            target_adr: target,
            initiator: ctx.sender(),

            // secret policy
            secret_length,

            // locked assets
            coin: amount,
            safety_deposit: deposit,

            // partial/multiple fills policy
            initial_amount: init_val,
            allow_partial,
            allow_multiple,
            min_partial,
        };

        event::emit(NewLockEvent{
            lock: object::id(&lock),
            hash: lock.hashed,
            coin: object::id(&lock.coin),
            refund_adr: refund,
            target_adr: target,
            initiator: lock.initiator,
            withdrawal: lock.withdrawal,
            public_withdrawal: lock.public_withdrawal,
            cancellation: lock.cancellation,
            public_cancellation: lock.public_cancellation,
            secret_length
        });

        transfer::share_object(lock);
    }

    ///
    /// Full withdrawal (claim entire remaining coin).
    /// Equivalent to partial withdraw with `amount = remaining`.
    ///
    public entry fun withdraw_all<T>(
        lock: LockObject<T>,
        clock_ref: &Clock,
        secret: vector<u8>,
        ctx: &mut TxContext
    ) {
        let remaining = coin::value(&lock.coin);
        withdraw_partial<T>(lock, clock_ref, secret, remaining, ctx);
    }

    ///
    /// Partial withdrawal:
    /// - Requires correct secret & timelock window.
    /// - Only `initiator` (resolver) before public window; afterward anyone can withdraw.
    /// - Distributes safety deposit pro-rata to `amount / initial_amount`.
    /// - Re-shares the lock if balance remains; otherwise deletes it.
    ///
    public entry fun withdraw_partial<T>(
        lock: LockObject<T>,
        clock_ref: &Clock,
        secret: vector<u8>,
        amount: u64,
        ctx: &mut TxContext
    ) {
        // Get the lock ID for event emission BEFORE destructuring (ID is required in events)
        let lock_id = object::id(&lock);

        // Now destructure the lock so we can either delete or reconstruct it
        let LockObject {
            id,
            created_at,
            withdrawal,
            public_withdrawal,
            cancellation,
            public_cancellation,
            hashed,
            refund_adr,
            target_adr,
            initiator,
            secret_length,
            coin,
            safety_deposit,
            initial_amount,
            allow_partial,
            allow_multiple,
            min_partial
        } = lock;

        // Time checks
        let now = clock::timestamp_ms(clock_ref);
        assert!(now >= withdrawal, EWithdrawNotAvailable);
        if (now < public_withdrawal) {
            assert!(ctx.sender() == initiator, EWithdrawNotAllowed);
        };

        // Secret validation
        assert!(secret_length as u64 == secret.length(), ESecretLengthWrong);
        assert!(&hash::sha2_256(secret) == &hashed, ESecretPreimageWrong);

        // Policy checks
        assert!(allow_multiple, EMultipleFillsNotAllowed);
        assert!(allow_partial, EPartialNotAllowed);

        // Split and transfer from the main coin balance
        let mut coin_mut = coin;
        let current_val = coin::value(&coin_mut);
        assert!(amount > 0, EAmountTooSmall);
        assert!(amount >= min_partial, EAmountTooSmall);
        assert!(amount <= current_val, EAmountTooLarge);

        let piece = coin::split(&mut coin_mut, amount, ctx);
        transfer::public_transfer(piece, target_adr);

        // Pro-rata safety deposit payout
        let mut dep_mut = safety_deposit;
        let total_dep = coin::value(&dep_mut);
        let share = (total_dep * amount) / initial_amount;
        if (share > 0) {
            let reward = coin::split(&mut dep_mut, share, ctx);
            transfer::public_transfer(reward, ctx.sender());

            event::emit(SafetyDepositClaimedEvent{
                lock: lock_id,            // ✅ of type ID
                receiver: ctx.sender(),
            });
        };

        let remaining_val = coin::value(&coin_mut);

        // Emit claim events
        event::emit(LockClaimedEvent{
            lock: lock_id,               
            secret: secret,
            claimer: ctx.sender(),
        });
        event::emit(LockPartiallyClaimedEvent{
            lock: lock_id,               
            amount: amount,
            remaining: remaining_val,
            claimer: ctx.sender(),
        });
        // Delete the object — we've either fully consumed coin and deposit or we're reconstructing the lock with remaining coin and deposit
        object::delete(id);
        // If the coin is empty, finish and consume remaining deposit
        if (remaining_val == 0) {
        // Transfer remaining deposit to claimer (whatever is left)
        let leftover_dep = coin::value(&dep_mut);
        if (leftover_dep > 0) {
            transfer::public_transfer(dep_mut, ctx.sender());
            event::emit(SafetyDepositClaimedEvent{
                lock: lock_id,        
                receiver: ctx.sender(),
            });
        } else {
            // No leftover deposit: must consume it anyway
            coin::destroy_zero(dep_mut);
        };

        // Consume the zero-valued coin
        coin::destroy_zero(coin_mut);
        return
    };

        // Otherwise, reconstruct lock with remaining coin and deposit and re-share it
        let lock_new = LockObject {
            id : object::new(ctx),
            created_at,
            withdrawal, public_withdrawal,
            cancellation, public_cancellation,
            hashed, refund_adr, target_adr,
            initiator, secret_length,
            coin: coin_mut,
            safety_deposit: dep_mut,
            initial_amount,
            allow_partial,
            allow_multiple,
            min_partial,
        };
        transfer::share_object(lock_new);
    }

    ///
    /// Cancels the lock. After `cancellation` anyone may cancel on the public window, 
    /// otherwise only the initiator can cancel during the exclusive window.
    ///
    public entry fun cancel<T>(
        lock: LockObject<T>,
        clock_ref: &Clock,
        ctx: &mut TxContext
    ) {
        let now = clock::timestamp_ms(clock_ref);

        // capture lock ID before moving it
        let lock_id = object::id(&lock);

        assert!(now >= lock.cancellation, ECancelNotAvailable);
        if (now < lock.public_cancellation) {
            assert!(ctx.sender() == lock.initiator, ECancelNotAllowed);
        };

        event::emit(LockCancelledEvent{
            lock: lock_id,
            canceller: ctx.sender(),
        });

        event::emit(SafetyDepositClaimedEvent{
            lock: lock_id,
            receiver: ctx.sender(),
        });

        let LockObject{
            id, coin, refund_adr, safety_deposit,
            ..
        } = lock;

        // deposit goes to canceller
        transfer::public_transfer(safety_deposit, ctx.sender());
        // remaining coin goes back to refund address
        transfer::public_transfer(coin, refund_adr);
        object::delete(id);
    }
}