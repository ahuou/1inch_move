/// Module: htlc
/// HTLC implementation compatible with <https://github.com/decred/atomicswap> hence with many more projects which conform to it. 
/// Basically this enables [Decred Atomic Swaps](https://docs.decred.org/advanced/atomic-swap/) for any `Coin` on Sui 
/// (with addresses not on deny-list) if somebody would want to implement that.
/// 
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
/// After adding some test code it became clear to me that proper tests for this should involve node RPC calls due to the nature of 
/// the protocol. Hence presented tests are somewhat superficial; and still they're divided in two modules: 
/// one adapts test from an Ethereum project and another checks error handling introduced here.
module oneinch_move::oneinch_move {
    use std::hash;

    use sui::coin::Coin;
    use sui::clock::{Self, Clock};

    use sui::event;


    const ESecretPreimageWrong: u64 = 1;
    const ESecretLengthWrong: u64 = 2;
    const ERefund3rdParty: u64 = 3;
    const ERefundEarly: u64 = 4;
    const ERedeemEarly: u64 = 5;

    // `Coin` is essential here a) to be able to transfer it to user accounts, and b) to be able communicate what kind of asset was indeed locked
    // `Balance` won't be inspectable via a RPC in the same way.
    #[allow(lint(coin_field))] 
    /// Representation of the hash time lock itself.
    // how to prevent from burning the lock (so that refund won't be possible)? should it be shared?
    /*      design decision: it can be either shared or object-owned (by the module itself); the later entites `store` and everything it needs (incl. fees), 
    the former requires sequencing, *but* the wrapped `Coin` do requires that anyway, so this requirements comes for free */
    public struct LockObject<phantom T> has key { // should not have `store` to pin it to the addressant
        id: UID,
        /// timestamp of the instance creation
        created_at: u64,
        /// timestamp after which `redeem` is available
        finality: u64,
        /// timestamp after which `refund` is available
        deadline: u64,
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
        // hash: string::String // could be cool to have different hash variants, but it's always SHA-2 SHA256 in all implementations around
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
        /// timestamp after which `redeem` is available
        finality: u64,
        /// timestamp after which `refund` is available
        deadline: u64,
        /// duration used to lock the `Coin`
        duration: u64,
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
    public struct LockRefundedEvent has copy, drop {
        /// `UID` of the lock refunded
        lock: ID,
        /// address initiated the refund
        signer_: address,
    }

    /// Creates a new hash time lock.
    /// Doesn't `assert` hash length since it should be done by the counterparty anyway.
    public fun create_lock_object<T>(
        clock: &Clock,
        dur: u64, fin_dur: u64,
        hashed: vector<u8>, target: address, refund: address, amount: Coin<T>,
        secret_length: u8,
        ctx: &mut TxContext
    ) {
        let timestamp = clock::timestamp_ms(clock);
        let lock = LockObject{
            id: object::new(ctx),
            created_at: timestamp, 
            deadline: timestamp + dur,
            finality: timestamp + fin_dur,
            hashed, 
            refund_adr: refund,
            target_adr: target,
            initiator: ctx.sender(),
            coin: amount,
            secret_length
        };
        
        event::emit(NewLockEvent{
            lock: sui::object::id(&lock),
            hash: lock.hashed,
            coin: sui::object::id(&lock.coin),
            refund_adr: refund,
            target_adr: target,
            initiator: lock.initiator,
            deadline: lock.deadline,
            duration: dur,
            finality: lock.finality,
            secret_length
        });
        transfer::share_object(lock);
    }
    /// `create_lock_object` which defaults to 48 hours
    /*public fun create_lock_object_48<T>(
        clock: &Clock,
        hashed: vector<u8>, target: address, refund: address, amount: Coin<T>,
        secret_length: u8,
        ctx: &mut TxContext
    ) {
        create_lock_object(
            clock, 
            172800000,
            hashed, target, refund, amount, secret_length, ctx
        );
    }
    /// `create_lock_object` which defaults to 24 hours; useful for answering to another lock
    public fun create_lock_object_24<T>(
        clock: &Clock,
        hashed: vector<u8>, target: address, refund: address, amount: Coin<T>,
        secret_length: u8,
        ctx: &mut TxContext
    ) {
        create_lock_object(
            clock, 
            86400000,
            hashed, target, refund, amount, secret_length, ctx
        );
    }
*/
    /// Redeems the lock. Requires only knowledge of the secret (not restricted to a calling address).
    public fun redeem<T>(lock: LockObject<T>, clock:&Clock, secret: vector<u8>, ctx: &mut TxContext) {
        assert!(lock.secret_length as u64 == secret.length(), ESecretLengthWrong); 
        assert!(&hash::sha2_256(secret) == &lock.hashed, ESecretPreimageWrong);
        assert!(clock.timestamp_ms() >= lock.finality, ERedeemEarly);
        
        event::emit(LockClaimedEvent{
            lock: sui::object::id(&lock),
            secret: secret,
            claimer: ctx.sender()
        });
        let LockObject{id, coin, target_adr, ..} = lock;
        transfer::public_transfer(coin, target_adr);
        object::delete(id);
    }

    /// Refunds the lock. Only addresses which the lock is aware of can call this.
    public fun refund<T>(lock: LockObject<T>, clock: &Clock, ctx: &mut TxContext) {
        assert!(
            &ctx.sender() == &lock.refund_adr
                || &ctx.sender() == &lock.initiator
                || &ctx.sender() == &lock.target_adr,
            ERefund3rdParty
        );
        assert!(clock.timestamp_ms() > lock.deadline, ERefundEarly);

        event::emit(LockRefundedEvent{
            lock: sui::object::id(&lock),
            signer_: ctx.sender()
        });
        let LockObject{id, coin, refund_adr, ..} = lock;
        transfer::public_transfer(coin, refund_adr);
        object::delete(id);
    }
}