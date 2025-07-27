/// WARNING: It's not possible to check if the hash time locked `Coin` is regulated or its metadata can be altered during the lock-time, 
/// *so it's duty of the downstream off-chain to check* that the `Coin` isn't regulated, frozen, or if the user takes those 
/// risk participating in the deal. *Note, that's equaly important at the audit phase of the protocol.*
/// 
/// During auditing phase a lot of things should be checked: starting from correct assets, amounts, and addresses, 
/// to the fact that counterparty code will actually hash to the agreed value, since there's a risk of a situation when correct 
/// hashed value is asserted with a different algorithm/settings which leads to exposure of the _secret_ via "mempool" without 
/// ability to redeem the asset leaving it to be refunded by the counterparty.
/// 
/// # tests
module oneinch_move::oneinch_move {
    use std::hash;

    use sui::coin::Coin;
    use sui::clock::{Self, Clock};
    use sui::event;


    const ESecretPreimageWrong: u64 = 1;
    const ESecretLengthWrong: u64 = 2;
    const ECancelNotAvailable: u64 = 3;
    const ECancelNotAllowed: u64 = 4;
    const EWithdrawNotAvailable: u64 = 5;
    const EWithdrawNotAllowed: u64 = 6;

    // `Coin` is essential here a) to be able to transfer it to user accounts, and b) to be able communicate what kind of asset was indeed locked
    // `Balance` won't be inspectable via a RPC in the same way.
    #[allow(lint(coin_field))] 
    // Representation of the hash time lock itself.
    // how to prevent from burning the lock (so that refund won't be possible)? should it be shared?
    /*      design decision: it can be either shared or object-owned (by the module itself); the later entites `store` and everything it needs (incl. fees), 
    the former requires sequencing, *but* the wrapped `Coin` do requires that anyway, so this requirements comes for free */
    public struct LockObject<phantom T> has key { // should not have `store` to pin it to the addressant
        id: UID,
        /// timestamp of the instance creation
        created_at: u64,
        /// timestamp after which `withdrawal` is available for resolver
        withdrawal: u64,
        /// timestamp after which `withdrawal` is available for all
        public_withdrawal: u64,
        /// timestamp after which `cancellation` is available for resolver
        cancellation: u64,
        /// timestamp after which `cancellation` is available for resolver
        public_cancellation: u64,
        /// hashed value of the secret
        hashed: vector<u8>,
        /// refunded `Coin` will be addressed to this
        refund_adr: address,
        /// redeemed `Coin` will be addressed to this
        target_adr: address,
        /// address that initiated the lock
        initiator: address,
        /// byte length of the secret
        secret_length: u8,
        /// locked `Coin` 
        coin: Coin<T>,
        /// safety deposit for the lock
        safety_deposit: Coin<T>,
    }

    public struct NewLockEvent has copy, drop {
        /// `UID` of the lock created
        lock: ID,
        /// hash guarding the lock
        hash: vector<u8>,
        /// `Coin` that was locked
        coin: ID,
        /// refund address
        refund_adr: address,
        /// redeem address
        target_adr: address,
        /// address that created the lock
        initiator: address,
        /// timestamp after which `withdrawal` is available for resolver
        withdrawal: u64,
        /// timestamp after which `withdrawal` is available for all
        public_withdrawal: u64,
        /// timestamp after which `cancellation` is available for resolver
        cancellation: u64,
        /// timestamp after which `cancellation` is available for resolver
        public_cancellation: u64,
        /// byte length of the secret
        secret_length: u8,
    }

    public struct LockClaimedEvent has copy, drop {
        /// `UID` of the lock redeemed
        lock: ID,
        /// unlock secret
        secret: vector<u8>,
        /// address initiated the claim
        claimer: address
    }

    public struct LockCancelledEvent has copy, drop {
        /// `UID` of the lock cancelled
        lock: ID,
        /// address initiated the cancellation
        canceller: address,
    }

    public struct SafetyDepositClaimedEvent has copy, drop {
        /// `UID` of the lock
        lock: ID,
        /// address that claimed the safety deposit
        receiver: address,
    }

    /// Creates a new hash time lock.
    /// Doesn't `assert` hash length since it should be done by the counterparty anyway.
    public fun create_lock_object<T>(
        clock: &Clock,
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
        ctx: &mut TxContext
    ) {
        let now = clock::timestamp_ms(clock);
        let lock = LockObject{
            id: object::new(ctx),
            created_at: now, 
            withdrawal: now + withdrawal_ms,
            public_withdrawal: now + public_withdrawal_ms,
            cancellation: now + cancellation_ms,
            public_cancellation: now + public_cancellation_ms,
            hashed, 
            refund_adr: refund,
            target_adr: target,
            initiator: ctx.sender(),
            coin: amount, 
            secret_length,
            safety_deposit: deposit,
        };
        
        event::emit(NewLockEvent{
            lock: sui::object::id(&lock),
            hash: lock.hashed,
            coin: sui::object::id(&lock.coin),
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

    /// Withdraws from the lock. Requires only knowledge of the secret, and proper timelock zone.
    #[allow(lint(self_transfer))]
    public fun withdraw<T>(lock: LockObject<T>, clock:&Clock, secret: vector<u8>, ctx: &mut TxContext) {
        let now = clock::timestamp_ms(clock);
        assert!(now >= lock.withdrawal, EWithdrawNotAvailable);
        if (now < lock.public_withdrawal) {
            assert!(ctx.sender() == lock.initiator, EWithdrawNotAllowed);
        };
        assert!(lock.secret_length as u64 == secret.length(), ESecretLengthWrong); 
        assert!(&hash::sha2_256(secret) == &lock.hashed, ESecretPreimageWrong);
        
        event::emit(LockClaimedEvent{
            lock: sui::object::id(&lock),
            secret: secret,
            claimer: ctx.sender()
        });
        event::emit(SafetyDepositClaimedEvent{
            lock: sui::object::id(&lock),
            receiver: ctx.sender()
        });

        let LockObject{id, coin, target_adr, safety_deposit, ..} = lock;
        transfer::public_transfer(safety_deposit, ctx.sender());
        transfer::public_transfer(coin, target_adr);
        object::delete(id);
    }

    /// Cancels the lock. Everyone can cancel the lock but the initiator has an exclusive time window to cancel the lock before the public.
    #[allow(lint(self_transfer))]
    public fun cancel<T>(lock: LockObject<T>, clock: &Clock, ctx: &mut TxContext) {
        let now = clock::timestamp_ms(clock);
        assert!(now >= lock.cancellation, ECancelNotAvailable);
        if (now < lock.public_cancellation) {
            assert!(ctx.sender() == lock.initiator, ECancelNotAllowed);
        };

        event::emit(LockCancelledEvent{
            lock: sui::object::id(&lock),
            canceller: ctx.sender()
        });

        event::emit(SafetyDepositClaimedEvent{
            lock: sui::object::id(&lock),
            receiver: ctx.sender()
        });

        let LockObject{id, coin, refund_adr, safety_deposit, ..} = lock;
        transfer::public_transfer(safety_deposit, ctx.sender());
        transfer::public_transfer(coin, refund_adr);
        object::delete(id);
    }
}