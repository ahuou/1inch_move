module oneinch_move::pf_test_utils {
    use std::vector;
    use std::hash;
    use std::string::String;

    use sui::clock::{Self as clock, Clock};
    use sui::coin::{Self as coin, Coin, TreasuryCap};
    use sui::tx_context::{Self as tx, TxContext};
    use sui::object::{Self as object, UID};

    //
    // ---- A tiny test coin type we can mint inside test_scenario ----
    //
    public struct TEST_COIN has drop {}

    /// Create a test TreasuryCap for TEST_COIN (test-only pattern)
    public fun create_treasury_cap(ctx: &mut TxContext): TreasuryCap<TEST_COIN> {
        coin::create_currency<TEST_COIN>(
            9,                   // decimals
            b"Test Coin",        // name
            b"TCOIN",            // symbol
            option::none(),      // icon url
            ctx
        )
    }

    /// Mint `amount` of TEST_COIN into a Coin<T>
    public fun mint_test_coin(
        cap: &mut TreasuryCap<TEST_COIN>,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<TEST_COIN> {
        coin::mint(cap, amount, ctx)
    }

    //
    // ---- Merkle helpers (sha2_256, concat) ----
    //
    public fun leaf(secret: &vector<u8>): vector<u8> {
        hash::sha2_256(*secret)
    }

    /// concat(a,b) – byte concatenation
    public fun concat(a: &vector<u8>, b: &vector<u8>): vector<u8> {
        let mut out = vector::empty<u8>();
        let la = vector::length(a);
        let lb = vector::length(b);
        let mut i = 0;
        while (i < la) { vector::push_back(&mut out, *vector::borrow(a, i)); i = i + 1; };
        i = 0;
        while (i < lb) { vector::push_back(&mut out, *vector::borrow(b, i)); i = i + 1; };
        out
    }

    /// Build a 2-leaf Merkle tree:
    /// root = H( H(s0) || H(s1) ) with leaves indexed [0,1]
    /// Returns (root, proofs_for_index0, proofs_for_index1).
    public fun build_merkle_2(
        s0: &vector<u8>, s1: &vector<u8>
    ): (vector<u8>, vector<vector<u8>>, vector<vector<u8>>) {
        let l0 = leaf(s0);
        let l1 = leaf(s1);
        let root = hash::sha2_256(concat(&l0, &l1));

        // Proofs are just the sibling for height 1
        let p0 = vector::singleton<vector<u8>>(l1);
        let p1 = vector::singleton<vector<u8>>(l0);
        (root, p0, p1)
    }

    /// Build a 4-leaf tree with standard left-to-right order.
    /// Indices: 0,1,2,3. We only use small trees for staged proofs in tests.
    /// Returns (root, proofs[0], proofs[1], proofs[2], proofs[3]).
    public fun build_merkle_4(
        s0: &vector<u8>, s1: &vector<u8>, s2: &vector<u8>, s3: &vector<u8>
    ): (
        vector<u8>, vector<vector<u8>>, vector<vector<u8>>, vector<vector<u8>>, vector<vector<u8>>
    ) {
        let l0 = leaf(s0);
        let l1 = leaf(s1);
        let l2 = leaf(s2);
        let l3 = leaf(s3);

        let h01 = hash::sha2_256(concat(&l0, &l1));
        let h23 = hash::sha2_256(concat(&l2, &l3));

        let root = hash::sha2_256(concat(&h01, &h23));

        // proofs:
        let p0 = vector::from_elements<vector<u8>>(vector[l1, h23]); // sibling on level 0 then upper
        let p1 = vector::from_elements<vector<u8>>(vector[l0, h23]);
        let p2 = vector::from_elements<vector<u8>>(vector[l3, h01]);
        let p3 = vector::from_elements<vector<u8>>(vector[l2, h01]);

        (root, p0, p1, p2, p3)
    }
}