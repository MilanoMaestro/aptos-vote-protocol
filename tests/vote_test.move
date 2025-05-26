module tests::vote_test {

    use std::string;
    use std::timestamp;
    use std::option;
    use std::signer;
    use std::vector;

    use aptos_framework::object::{Self};
    use aptos_framework::fungible_asset::{Self, Metadata};
    use aptos_framework::primary_fungible_store;
    use vote::protocol;

    #[test(creator = @vote)]
    public fun test_init(creator: &signer) {
        protocol::init(creator);
    }

    #[test_only]
    fun create_test_fungible_asset(
        creator: &signer
    ): (object::ConstructorRef, object::Object<Metadata>) {
        let constructor = object::create_named_object(creator, b"TEST_TOKEN");
        primary_fungible_store::create_primary_store_enabled_fungible_asset(
            &constructor,
            option::none(),
            string::utf8(b"My Token"),
            string::utf8(b"MTK"),
            6,
            string::utf8(b"http://icon.uri"),
            string::utf8(b"http://project.uri")
        );
        let metadata = object::object_from_constructor_ref<Metadata>(&constructor);
        (constructor, metadata)
    }

    #[test(creator = @vote, framework = @0x1)]
    fun test_create_vote_basic(creator: &signer, framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1);

        protocol::init(creator);

        let (constructor, token) = create_test_fungible_asset(creator);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        let minted = fungible_asset::mint(&mint_ref, 1500);

        let store =
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(creator), token
            );
        fungible_asset::deposit(store, minted);

        let options = vector[string::utf8(b"A"), string::utf8(b"B")];
        protocol::create_vote(
            creator, // caller: &signer
            0, // vote_idx: u64
            string::utf8(b"Vote"), // title: string
            100, // start_at: u64
            200, // end_at: u64
            0, // reward_rule: u8
            token, // reward_token: Object<Metadata>
            10, // reward_per_person: u64
            100, // reward_max_winners: u64
            options // options: vector<string::String>
        );

        let (
            creator_addr,
            title,
            start_at,
            end_at,
            reward_rule,
            reward_token,
            reward_per_person,
            reward_max_winners,
            option_texts,
            reward_store_balance
        ) = protocol::get_vote_info(0);

        assert!(creator_addr == signer::address_of(creator), 100);
        assert!(title == string::utf8(b"Vote"), 101);
        assert!(start_at == 100, 102);
        assert!(end_at == 200, 103);
        assert!(reward_rule == 0, 104);
        assert!(reward_token == token, 105);
        assert!(reward_per_person == 10, 106);
        assert!(reward_max_winners == 100, 107);
        assert!(vector::length(&option_texts) == 2, 108);
        assert!(*vector::borrow(&option_texts, 0) == string::utf8(b"A"), 109);
        assert!(*vector::borrow(&option_texts, 1) == string::utf8(b"B"), 110);
        assert!(
            reward_store_balance == reward_per_person * reward_max_winners,
            111
        );

        let creator_store =
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(creator), token
            );
        let creator_balance = fungible_asset::balance(creator_store);

        assert!(reward_store_balance == 1000, 211); // 10 * 1000

        assert!(creator_balance == 500, 212); // 1500 - 1000
    }

    #[test(
        admin = @vote, user1 = @0x2, user2 = @0x3, framework = @0x1
    )]
    fun test_vote_submission_and_finish(
        admin: &signer,
        user1: &signer,
        user2: &signer,
        framework: &signer
    ) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1);

        protocol::init(admin);

        let (constructor, token) = create_test_fungible_asset(admin);

        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        let minted = fungible_asset::mint(&mint_ref, 200);
        let store =
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(admin), token
            );
        fungible_asset::deposit(store, minted);

        timestamp::update_global_time_for_test_secs(10);

        let options = vector[string::utf8(b"Yes"), string::utf8(b"No")];
        protocol::create_vote(
            admin,
            0, // vote_idx
            string::utf8(b"Vote"), // title
            10, // start_at
            50, // end_at
            0, // reward_rule (0 = FIFO)
            token, // reward_token
            2, // reward_per_person
            100, // reward_max_winners
            options // options
        );

        timestamp::update_global_time_for_test_secs(15);

        protocol::submit_vote(user1, 0, 0); // returns u64
        protocol::submit_vote(user2, 0, 0);

        timestamp::update_global_time_for_test_secs(21);
        protocol::finalize_vote(admin, 0);
    }

    #[test(admin = @vote, framework = @0x1)]
    fun test_edit_vote_before_start(admin: &signer, framework: &signer) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test(1);

        protocol::init(admin);
        let (constructor, token) = create_test_fungible_asset(admin);

        let reward_token_store =
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(admin), token
            );
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        let minted = fungible_asset::mint(&mint_ref, 3000);
        fungible_asset::deposit(reward_token_store, minted);

        let options = vector[string::utf8(b"X")];

        protocol::create_vote(
            admin,
            0,
            string::utf8(b"Before Edit"),
            100,
            200,
            1, // reward_rule (1 = WINNER)
            token, // reward_token
            500, // reward_per_person
            3, // reward_max_winners
            options

        );

        let new_options = vector[string::utf8(b"Y"), string::utf8(b"Z")];

        protocol::edit_vote(
            admin,
            0,
            string::utf8(b"Edited"),
            100,
            300,
            1, // reward_rule
            600, // reward_per_person
            4, // reward_max_winners
            new_options
        );

        let (
            creator_addr,
            title,
            start_at,
            end_at,
            reward_rule,
            reward_TEST_TOKENfter,
            reward_per_person,
            reward_max_winners,
            option_texts,
            reward_store_balance
        ) = protocol::get_vote_info(0);

        assert!(creator_addr == signer::address_of(admin), 200);
        assert!(title == string::utf8(b"Edited"), 201);
        assert!(start_at == 100, 202);
        assert!(end_at == 300, 203);
        assert!(reward_rule == 1, 204); // WINNER
        assert!(reward_TEST_TOKENfter == token, 205);
        assert!(reward_per_person == 600, 206);
        assert!(reward_max_winners == 4, 207);
        assert!(vector::length(&option_texts) == 2, 208);
        assert!(*vector::borrow(&option_texts, 0) == string::utf8(b"Y"), 209);
        assert!(*vector::borrow(&option_texts, 1) == string::utf8(b"Z"), 210);

        let admin_store =
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(admin), token
            );
        let admin_balance = fungible_asset::balance(admin_store);

        assert!(reward_store_balance == 2400, 211); // 600 * 4
        assert!(admin_balance == 600, 212); // 3000 - 2400
    }

    #[test(admin = @vote, user1 = @0x2, framework = @0x1)]
    #[expected_failure(abort_code = 2, location = vote::protocol)]
    fun test_duplicate_vote_should_fail(
        admin: &signer, user1: &signer, framework: &signer
    ) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1);
        protocol::init(admin);

        let (constructor, token) = create_test_fungible_asset(admin);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        fungible_asset::deposit(
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(admin), token
            ),
            fungible_asset::mint(&mint_ref, 100)
        );

        timestamp::update_global_time_for_test_secs(10);
        let options = vector[string::utf8(b"A")];
        protocol::create_vote(
            admin,
            0,
            string::utf8(b"Test"),
            10,
            50,
            0,
            token,
            10,
            10,
            options
        );

        timestamp::update_global_time_for_test_secs(15);
        protocol::submit_vote(user1, 0, 0);
        protocol::submit_vote(user1, 0, 0); // duplicate submit abort 2
    }

    #[test(admin = @vote, user1 = @0x2, framework = @0x1)]
    #[expected_failure(abort_code = 4, location = vote::protocol)]
    fun test_vote_before_start_should_fail(
        admin: &signer, user1: &signer, framework: &signer
    ) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(5);
        protocol::init(admin);

        let (constructor, token) = create_test_fungible_asset(admin);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        fungible_asset::deposit(
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(admin), token
            ),
            fungible_asset::mint(&mint_ref, 100)
        );

        let options = vector[string::utf8(b"A")];
        protocol::create_vote(
            admin,
            0,
            string::utf8(b"Early Vote"),
            10,
            50,
            0,
            token,
            10,
            10,
            options
        );

        protocol::submit_vote(user1, 0, 0); // early submit abort 4
    }

    #[test(admin = @vote, user1 = @0x2, framework = @0x1)]
    #[expected_failure(abort_code = 5, location = vote::protocol)]
    fun test_vote_after_end_should_fail(
        admin: &signer, user1: &signer, framework: &signer
    ) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1);
        protocol::init(admin);

        let (constructor, token) = create_test_fungible_asset(admin);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        fungible_asset::deposit(
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(admin), token
            ),
            fungible_asset::mint(&mint_ref, 100)
        );

        timestamp::update_global_time_for_test_secs(10);
        let options = vector[string::utf8(b"A")];
        protocol::create_vote(
            admin,
            0,
            string::utf8(b"Late Vote"),
            10,
            20,
            0,
            token,
            10,
            10,
            options
        );

        timestamp::update_global_time_for_test_secs(21);
        protocol::submit_vote(user1, 0, 0); // after submit abort 5
    }

    #[test(admin = @vote, user1 = @0x2, framework = @0x1)]
    #[expected_failure(abort_code = 8, location = vote::protocol)]
    fun test_invalid_option_idx_should_fail(
        admin: &signer, user1: &signer, framework: &signer
    ) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1);
        protocol::init(admin);

        let (constructor, token) = create_test_fungible_asset(admin);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        fungible_asset::deposit(
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(admin), token
            ),
            fungible_asset::mint(&mint_ref, 100)
        );

        timestamp::update_global_time_for_test_secs(10);
        let options = vector[string::utf8(b"A")];
        protocol::create_vote(
            admin,
            0,
            string::utf8(b"Invalid Option"),
            10,
            50,
            0,
            token,
            10,
            10,
            options
        );

        timestamp::update_global_time_for_test_secs(15);
        protocol::submit_vote(user1, 0, 1); // wrong option idx abort 8
    }

    #[test(
        admin = @vote, user1 = @0x2, user2 = @0x3, framework = @0x1
    )]
    fun test_fifo_under_limit(
        admin: &signer,
        user1: &signer,
        user2: &signer,
        framework: &signer
    ) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1);

        protocol::init(admin);

        let (constructor, token) = create_test_fungible_asset(admin);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        let minted = fungible_asset::mint(&mint_ref, 100);
        let admin_store =
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(admin), token
            );
        fungible_asset::deposit(admin_store, minted);

        timestamp::update_global_time_for_test_secs(10);

        let options = vector[string::utf8(b"Yes"), string::utf8(b"No")];
        protocol::create_vote(
            admin,
            0,
            string::utf8(b"Test FIFO Vote"),
            10,
            50,
            0, // reward_rule = FIFO
            token, // reward_token
            33, // reward_per_person
            3, // reward_max_winners
            options
        );

        timestamp::update_global_time_for_test_secs(15);
        protocol::submit_vote(user1, 0, 0);
        protocol::submit_vote(user2, 0, 0);

        timestamp::update_global_time_for_test_secs(60);
        protocol::finalize_vote(admin, 0);

        let user1_store =
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(user1), token
            );
        let user2_store =
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(user2), token
            );

        let user1_balance = fungible_asset::balance(user1_store);
        let user2_balance = fungible_asset::balance(user2_store);
        let admin_balance = fungible_asset::balance(admin_store);

        assert!(user1_balance == 33, 1001);
        assert!(user2_balance == 33, 1002);
        assert!(admin_balance == 34, 1003);
    }

    #[test(
        admin = @vote, user1 = @0x2, user2 = @0x3, user3 = @0x4, framework = @0x1
    )]
    fun test_fifo_over_limit(
        admin: &signer,
        user1: &signer,
        user2: &signer,
        user3: &signer,
        framework: &signer
    ) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1);
        protocol::init(admin);

        let (constructor, token) = create_test_fungible_asset(admin);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        let minted = fungible_asset::mint(&mint_ref, 100);
        let admin_store =
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(admin), token
            );
        fungible_asset::deposit(admin_store, minted);

        timestamp::update_global_time_for_test_secs(10);
        let options = vector[string::utf8(b"A"), string::utf8(b"B")];
        protocol::create_vote(
            admin,
            0,
            string::utf8(b"Test FIFO Vote"),
            10,
            50,
            0, // reward_rule = FIFO
            token, // reward_token
            50, // reward_per_person
            2, // reward_max_winners
            options
        );

        timestamp::update_global_time_for_test_secs(15);
        protocol::submit_vote(user1, 0, 0);
        protocol::submit_vote(user2, 0, 0);
        protocol::submit_vote(user3, 0, 0);

        timestamp::update_global_time_for_test_secs(60);
        protocol::finalize_vote(admin, 0);

        let user1_balance =
            fungible_asset::balance(
                primary_fungible_store::ensure_primary_store_exists(
                    signer::address_of(user1), token
                )
            );
        let user2_balance =
            fungible_asset::balance(
                primary_fungible_store::ensure_primary_store_exists(
                    signer::address_of(user2), token
                )
            );
        let user3_balance =
            fungible_asset::balance(
                primary_fungible_store::ensure_primary_store_exists(
                    signer::address_of(user3), token
                )
            );

        // Only first 2 get reward, each 45
        assert!(user1_balance == 50, 1101);
        assert!(user2_balance == 50, 1102);
        assert!(user3_balance == 0, 1103);
    }

    #[test(
        admin = @vote, user1 = @0x2, user2 = @0x3, user3 = @0x4, framework = @0x1
    )]
    fun test_winner_distribution(
        admin: &signer,
        user1: &signer,
        user2: &signer,
        user3: &signer,
        framework: &signer
    ) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1);
        protocol::init(admin);

        let (constructor, token) = create_test_fungible_asset(admin);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        let minted = fungible_asset::mint(&mint_ref, 100);
        let admin_store =
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(admin), token
            );
        fungible_asset::deposit(admin_store, minted);

        timestamp::update_global_time_for_test_secs(10);
        let options = vector[string::utf8(b"A"), string::utf8(b"B")];
        protocol::create_vote(
            admin,
            0,
            string::utf8(b"Test Winner Vote"),
            10,
            50,
            1, // reward_rule = WINNER
            token, // reward_token
            50, // reward_per_person
            2, // reward_max_winners
            options
        );

        timestamp::update_global_time_for_test_secs(15);
        protocol::submit_vote(user1, 0, 0); // A
        protocol::submit_vote(user2, 0, 0); // A
        protocol::submit_vote(user3, 0, 1); // B

        timestamp::update_global_time_for_test_secs(60);
        protocol::finalize_vote(admin, 0);

        // Only A side gets reward, 2 winners => 45 each
        let user1_balance =
            fungible_asset::balance(
                primary_fungible_store::ensure_primary_store_exists(
                    signer::address_of(user1), token
                )
            );
        let user2_balance =
            fungible_asset::balance(
                primary_fungible_store::ensure_primary_store_exists(
                    signer::address_of(user2), token
                )
            );
        let user3_balance =
            fungible_asset::balance(
                primary_fungible_store::ensure_primary_store_exists(
                    signer::address_of(user3), token
                )
            );

        assert!(user1_balance == 50, 1201);
        assert!(user2_balance == 50, 1202);
        assert!(user3_balance == 0, 1203);
    }

    #[test(
        admin = @vote, user1 = @0x2, user2 = @0x3, user3 = @0x4, framework = @0x1
    )]
    fun test_winner_over_limit(
        admin: &signer,
        user1: &signer,
        user2: &signer,
        user3: &signer,
        framework: &signer
    ) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1);
        protocol::init(admin);

        let (constructor, token) = create_test_fungible_asset(admin);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        let minted = fungible_asset::mint(&mint_ref, 100);
        let admin_store =
            primary_fungible_store::ensure_primary_store_exists(
                signer::address_of(admin), token
            );
        fungible_asset::deposit(admin_store, minted);

        timestamp::update_global_time_for_test_secs(10);
        let options = vector[string::utf8(b"A"), string::utf8(b"B")];
        protocol::create_vote(
            admin,
            0,
            string::utf8(b"Test Winner Vote"),
            10,
            50,
            1, // reward_rule = WINNER
            token, // reward_token
            50, // reward_per_person
            2, // reward_max_winners
            options
        );

        timestamp::update_global_time_for_test_secs(15);
        protocol::submit_vote(user1, 0, 0); // A
        protocol::submit_vote(user2, 0, 0); // A
        protocol::submit_vote(user3, 0, 0); // A

        timestamp::update_global_time_for_test_secs(60);
        protocol::finalize_vote(admin, 0);

        // Only first 2 get reward, each 45
        let user1_balance =
            fungible_asset::balance(
                primary_fungible_store::ensure_primary_store_exists(
                    signer::address_of(user1), token
                )
            );
        let user2_balance =
            fungible_asset::balance(
                primary_fungible_store::ensure_primary_store_exists(
                    signer::address_of(user2), token
                )
            );
        let user3_balance =
            fungible_asset::balance(
                primary_fungible_store::ensure_primary_store_exists(
                    signer::address_of(user3), token
                )
            );

        assert!(user1_balance == 50, 1301);
        assert!(user2_balance == 50, 1302);
        assert!(user3_balance == 0, 1303);
    }

    #[test(admin = @vote, user1 = @0x2, user2 = @0x3, framework = @0x1)]
    fun test_vote_info_action_grouping(
        admin: &signer, user1: &signer, user2: &signer, framework: &signer
    ) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1);
        protocol::init(admin);

        let (constructor, token) = create_test_fungible_asset(admin);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        let minted = fungible_asset::mint(&mint_ref, 100);
        fungible_asset::deposit(
            primary_fungible_store::ensure_primary_store_exists(signer::address_of(admin), token),
            minted
        );

        timestamp::update_global_time_for_test_secs(10);
        let options = vector[string::utf8(b"A"), string::utf8(b"B")];
        protocol::create_vote(
            admin, 0, string::utf8(b"Test Grouping"),
            10, 50, 0, token, 10, 10, options
        );

        timestamp::update_global_time_for_test_secs(15);
        protocol::submit_vote(user1, 0, 0);
        protocol::submit_vote(user2, 0, 1);

        let (voters_0, timestamps_0) = protocol::get_vote_option_actions(0, 0);
        let (voters_1, timestamps_1) = protocol::get_vote_option_actions(0, 1);

        assert!(vector::length(&voters_0) == 1, 100);
        assert!(vector::length(&timestamps_0) == 1, 101);
        assert!(vector::length(&voters_1) == 1, 102);
        assert!(vector::length(&timestamps_1) == 1, 103);

        assert!(*vector::borrow(&voters_0, 0) == signer::address_of(user1), 110);
        assert!(*vector::borrow(&voters_1, 0) == signer::address_of(user2), 111);
    }

    #[test(admin = @vote, user1 = @0x2, framework = @0x1)]
    fun test_finalize_vote_internal_state_change(
        admin: &signer, user1: &signer, framework: &signer
    ) {
        timestamp::set_time_has_started_for_testing(framework);
        timestamp::update_global_time_for_test_secs(1);
        protocol::init(admin);

        let (constructor, token) = create_test_fungible_asset(admin);
        let mint_ref = fungible_asset::generate_mint_ref(&constructor);
        let minted = fungible_asset::mint(&mint_ref, 100);
        let admin_store = primary_fungible_store::ensure_primary_store_exists(signer::address_of(admin), token);
        fungible_asset::deposit(admin_store, minted);

        timestamp::update_global_time_for_test_secs(10);
        let options = vector[string::utf8(b"A")];
        protocol::create_vote(
            admin, 0, string::utf8(b"Finalize Test"),
            10, 20, 0, token, 50, 1, options
        );

        timestamp::update_global_time_for_test_secs(15);
        protocol::submit_vote(user1, 0, 0);

        timestamp::update_global_time_for_test_secs(25);
        protocol::finalize_vote(admin, 0);

        let user1_store =
            primary_fungible_store::ensure_primary_store_exists(signer::address_of(user1), token);
        let user1_balance = fungible_asset::balance(user1_store);

        let admin_balance = fungible_asset::balance(admin_store);

        // One voter rewarded 50, remaining 0 should be refunded.
        assert!(user1_balance == 50, 200);
        assert!(admin_balance == 50, 201); // Total reward = 50, refunded 0
    }
}
