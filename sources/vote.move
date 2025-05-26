module vote::protocol {
    use std::error;
    use std::signer;
    use std::vector;
    use std::string;
    use std::timestamp;

    // Import Aptos framework modules for fungible token, object store, and metadata
    use aptos_framework::fungible_asset::{Self, FungibleStore, Metadata};
    use aptos_framework::primary_fungible_store;
    use aptos_framework::object::{Self, Object, ExtendRef};
    use aptos_framework::event;

    // Address where the module is deployed
    const MODULE_ADDR: address = @vote;

    // Error codes used throughout the protocol logic
    const EALREADY_INITIALIZED: u64 = 1;
    const EALREADY_VOTED: u64 = 2;
    const EALREADY_STARTED: u64 = 3;
    const EINVALID_START_TIME: u64 = 4;
    const EINVALID_END_TIME: u64 = 5;
    const EINVALID_VOTE_REQUEST: u64 = 6;
    const EINSUFFICIENT_BALANCE: u64 = 7;
    const EINVALID_OPTION_IDX: u64 = 8;

    // Defines how rewards are distributed to voters
    // Additional custom rules can be added here in the future as needed
    enum RewardRule has copy, drop, store {
        FIFO, // reward given to first N voters
        WINNER // reward given to voters who chose winning option(s)
        // CUSTOM rules can be added later for more advanced reward strategies
    }

    #[event]
    struct VoteCreatedEvent has drop, store {
        vote_idx: u64,
        creator: address,
        title: string::String,
        timestamp: u64,
    }

    #[event]
    struct VoteEditedEvent has drop, store {
        vote_idx: u64,
        editor: address,
        title: string::String,
        timestamp: u64,
    }

    #[event]
    struct VoteSubmittedEvent has drop, store {
        vote_idx: u64,
        voter: address,
        option_idx: u64,
        timestamp: u64,
    }

    #[event]
    struct VoteFinalizedEvent has drop, store {
        vote_idx: u64,
        caller: address,
        timestamp: u64
    }

    #[event]
    struct RefundRewardEvent has drop, store {
        vote_idx: u64,
        refunded_to: address,
        amount: u64,
        timestamp: u64
    }

    // Stores admin config for the vote module
    struct VoteConfig has key {
        admin: address
    }

    // Global store holding all votes
    struct VoteStore has key {
        votes: vector<Vote>,
        next_vote_idx: u64
    }

    // Main Vote structure
    struct Vote has key, store {
        creator: address,
        title: string::String,
        start_at: u64,
        end_at: u64,
        reward_rule: RewardRule,
        reward_token: Object<Metadata>,
        reward_per_person: u64,
        reward_max_winners: u64,
        reward_token_store: Object<FungibleStore>,
        reward_token_extend_ref: ExtendRef,
        options: vector<OptionData>,
        actions: vector<VoteSubmitAction>,
        is_finalized: bool
    }

    // Represents each voting option
    struct OptionData has copy, drop, store {
        text: string::String,
        vote_count: u64
    }

    // Records individual vote submissions
    struct VoteSubmitAction has copy, drop, store {
        voter: address,
        option_idx: u64,
        timestamp: u64
    }

    // Tracks which votes a user has submitted to prevent duplicates
    struct VoterStore has key {
        submitted: vector<u64>
    }

    // Initializes the voting module and admin config (must be called once)
    public entry fun init(signer: &signer) {
        assert!(signer::address_of(signer) == MODULE_ADDR, error::permission_denied(1));
        assert!(!exists<VoteConfig>(MODULE_ADDR), EALREADY_INITIALIZED);
        assert!(!exists<VoteStore>(MODULE_ADDR), EALREADY_INITIALIZED);

        move_to(signer, VoteConfig { admin: MODULE_ADDR });

        move_to(
            signer,
            VoteStore { votes: vector::empty(), next_vote_idx: 0 }
        );
    }

    // Changes the module admin address (only callable by current admin)
    public entry fun set_admin(admin: &signer, new_admin: address) acquires VoteConfig {
        let config = borrow_global_mut<VoteConfig>(MODULE_ADDR);
        assert!(signer::address_of(admin) == config.admin, error::permission_denied(1));
        config.admin = new_admin;
    }

    // Maps numeric input to the internal RewardRule enum type
    fun match_reward_rule(reward_rule_val: u8): RewardRule {
        if (reward_rule_val == 0) {
            RewardRule::FIFO
        } else if (reward_rule_val == 1) {
            RewardRule::WINNER
        } else {
            abort EINVALID_VOTE_REQUEST
        }
    }

    // Creates a new vote with reward configuration and options
    // Transfers reward tokens to internal store and registers the vote metadata
    public entry fun create_vote(
        caller: &signer, // Account creating the vote
        vote_idx: u64, // Index of the new vote (must match next_vote_idx)
        title: string::String, // Title of the vote
        start_at: u64, // Voting start time (epoch seconds)
        end_at: u64, // Voting end time (epoch seconds)
        reward_rule: u8, // Reward rule (0: FIFO, 1: WINNER)
        reward_token: Object<Metadata>, // Token used for rewarding voters
        reward_per_person: u64, // Reward amount per voter
        reward_max_winners: u64, // Max number of rewarded voters
        options: vector<string::String> // Text options to choose from
    ) acquires VoteStore {
        // Load and validate the global VoteStore
        let vote_store = borrow_global_mut<VoteStore>(MODULE_ADDR);
        assert!(vote_idx == vote_store.next_vote_idx, EINVALID_VOTE_REQUEST);
        assert!(reward_max_winners > 0, EINVALID_VOTE_REQUEST);

        // Convert string options into OptionData structs
        let option_data = vector::empty<OptionData>();
        let i = 0;
        while (i < vector::length(&options)) {
            let opt_text = *vector::borrow(&options, i);
            vector::push_back(
                &mut option_data, OptionData { text: opt_text, vote_count: 0 }
            );
            i = i + 1;
        };

        // Create a new reward token store for this vote
        let store_constructor = &object::create_object(signer::address_of(caller));
        let reward_token_store =
            fungible_asset::create_store(store_constructor, reward_token);
        let reward_token_extend_ref = object::generate_extend_ref(store_constructor);

        // Ensure the caller has a primary token store for the given token
        let caller_addr = signer::address_of(caller);
        let caller_token_store =
            primary_fungible_store::ensure_primary_store_exists(
                caller_addr, reward_token
            );

        // Check if the caller has enough balance to fund the reward pool
        let balance = fungible_asset::balance(caller_token_store);
        let total_reward_amount = reward_per_person * reward_max_winners;
        assert!(
            balance >= total_reward_amount,
            error::invalid_argument(EINSUFFICIENT_BALANCE)
        );

        // Withdraw and deposit reward tokens to internal store
        let reward =
            fungible_asset::withdraw(caller, caller_token_store, total_reward_amount);
        fungible_asset::deposit(reward_token_store, reward);

        // Construct the Vote struct and register it
        let vote = Vote {
            creator: caller_addr,
            title,
            start_at,
            end_at,
            reward_rule: match_reward_rule(reward_rule),
            reward_token,
            reward_per_person,
            reward_max_winners,
            reward_token_store,
            reward_token_extend_ref,
            options: option_data,
            actions: vector::empty<VoteSubmitAction>(),
            is_finalized: false
        };

        vector::push_back(&mut vote_store.votes, vote);
        vote_store.next_vote_idx = vote_idx + 1;

        event::emit(VoteCreatedEvent {
            vote_idx,
            creator: caller_addr,
            title,
            timestamp: timestamp::now_seconds()
        });
        // Finalize any expired votes at the time of creation
        let i = 0;
        let now = timestamp::now_seconds();
        while (i < vector::length(&vote_store.votes)) {
            let vote_ref_mut = vector::borrow_mut(&mut vote_store.votes, i);
            if (!vote_ref_mut.is_finalized && vote_ref_mut.end_at < now) {
                finalize_vote_internal(vote_ref_mut, i);
            };
            i = i + 1;
        };
    }

    #[view]
    public fun get_vote_info(
        vote_idx: u64
    ): (
        address, // creator
        string::String, // title
        u64, // start_at
        u64, // end_at
        u8, // reward_rule (enum to u8)
        object::Object<Metadata>, // reward_token
        u64, // reward_per_person
        u64, // reward_max_winners
        vector<string::String>, // option texts
        u64 // reward_token_store balance
    ) acquires VoteStore {
        let vote_store = borrow_global<VoteStore>(MODULE_ADDR);
        let vote_ref = vector::borrow(&vote_store.votes, vote_idx);

        let options = vector::empty<string::String>();
        let i = 0;
        while (i < vector::length(&vote_ref.options)) {
            let opt = vector::borrow(&vote_ref.options, i);
            vector::push_back(&mut options, opt.text);
            i = i + 1;
        };

        let reward_rule_num =
            if (vote_ref.reward_rule == RewardRule::FIFO) { 0 }
            else { 1 };

        let reward_store_balance = fungible_asset::balance(vote_ref.reward_token_store);

        (
            vote_ref.creator,
            vote_ref.title,
            vote_ref.start_at,
            vote_ref.end_at,
            reward_rule_num,
            vote_ref.reward_token,
            vote_ref.reward_per_person,
            vote_ref.reward_max_winners,
            options,
            reward_store_balance
        )
    }

    #[view]
    public fun get_vote_option_actions(
        vote_idx: u64,
        option_idx: u64
    ): (vector<address>, vector<u64>) acquires VoteStore {
        let vote_store = borrow_global<VoteStore>(MODULE_ADDR);
        let vote_ref = vector::borrow(&vote_store.votes, vote_idx);

        let voters = vector::empty<address>();
        let timestamps = vector::empty<u64>();

        let i = 0;
        while (i < vector::length(&vote_ref.actions)) {
            let action = vector::borrow(&vote_ref.actions, i);
            if (action.option_idx == option_idx) {
                vector::push_back(&mut voters, action.voter);
                vector::push_back(&mut timestamps, action.timestamp);
            };
            i = i + 1;
        };

        (voters, timestamps)
    }

    // Edits an existing vote's metadata and reward configuration before it starts
    // Can only be called by the vote creator or admin, and only before start time
    public entry fun edit_vote(
        caller: &signer,
        vote_idx: u64,
        title: string::String,
        start_at: u64,
        end_at: u64,
        reward_rule: u8,
        reward_per_person: u64,
        reward_max_winners: u64,
        options: vector<string::String>
    ) acquires VoteStore, VoteConfig {
        let config = borrow_global<VoteConfig>(MODULE_ADDR);
        let signer_addr = signer::address_of(caller);

        let vote_store = borrow_global_mut<VoteStore>(MODULE_ADDR);
        let vote_ref = vector::borrow_mut(&mut vote_store.votes, vote_idx);

        // Allow only creator or admin
        assert!(
            signer_addr == vote_ref.creator || signer_addr == config.admin,
            error::permission_denied(1)
        );

        // Cannot edit once voting has started
        assert!(
            timestamp::now_seconds() < vote_ref.start_at,
            error::invalid_state(EALREADY_STARTED)
        );

        // Calculate current and updated total reward requirement
        let old_total_reward = vote_ref.reward_per_person * vote_ref.reward_max_winners;
        let new_total_reward = reward_per_person * reward_max_winners;

        let reward_token = vote_ref.reward_token;
        let store_signer =
            object::generate_signer_for_extending(&vote_ref.reward_token_extend_ref);
        let reward_store = vote_ref.reward_token_store;

        if (new_total_reward > old_total_reward) {
            let diff = new_total_reward - old_total_reward;
            let user_store =
                primary_fungible_store::ensure_primary_store_exists(
                    signer_addr, reward_token
                );
            let additional = fungible_asset::withdraw(caller, user_store, diff);
            fungible_asset::deposit(reward_store, additional);
        } else if (old_total_reward > new_total_reward) {
            let diff = old_total_reward - new_total_reward;
            let refund = fungible_asset::withdraw(&store_signer, reward_store, diff);
            let user_store =
                primary_fungible_store::ensure_primary_store_exists(
                    signer_addr, reward_token
                );
            fungible_asset::deposit(user_store, refund);
        };

        // Reset option list with new values
        let new_options = vector::empty<OptionData>();
        let i = 0;
        while (i < vector::length(&options)) {
            let text = *vector::borrow(&options, i);
            vector::push_back(
                &mut new_options,
                OptionData { text, vote_count: 0 }
            );
            i = i + 1;
        };

        vote_ref.options = new_options;
        vote_ref.title = title;
        vote_ref.start_at = start_at;
        vote_ref.end_at = end_at;
        vote_ref.reward_rule = match_reward_rule(reward_rule);
        vote_ref.reward_per_person = reward_per_person;
        vote_ref.reward_max_winners = reward_max_winners;

        event::emit(VoteEditedEvent {
            vote_idx,
            editor: signer_addr,
            title,
            timestamp: timestamp::now_seconds()
        });
    }

    // Utility function to check if a vote ID exists in a list of submitted votes
    fun contains_id(ids: &vector<u64>, id: u64): bool {
        let i = 0;
        while (i < vector::length(ids)) {
            if (*vector::borrow(ids, i) == id) {
                return true;
            };
            i = i + 1;
        };
        false
    }

    // Allows a user to submit a vote to a specified vote and option
    // Ensures vote is within the valid period and not duplicated
    public entry fun submit_vote(
        voter: &signer,                  // Voter submitting the vote
        vote_idx: u64,                  // Target vote index
        option_idx: u64                 // Selected option index
    ) acquires VoteStore, VoterStore {
        let voter_addr = signer::address_of(voter);

        if (!exists<VoterStore>(voter_addr)) {
            move_to(voter, VoterStore { submitted: vector::empty() });
        };

        // Check for duplicate submission
        let store = borrow_global_mut<VoterStore>(voter_addr);
        let has_voted = contains_id(&store.submitted, vote_idx);
        assert!(!has_voted, EALREADY_VOTED);

        // Load vote and validate option index
        let vote_store = borrow_global_mut<VoteStore>(MODULE_ADDR);
        let vote_ref = vector::borrow_mut(&mut vote_store.votes, vote_idx);
        assert!(option_idx < vector::length(&vote_ref.options), EINVALID_OPTION_IDX);

        // Check voting time validity
        let now = std::timestamp::now_seconds();
        assert!(now >= vote_ref.start_at, EINVALID_START_TIME);
        assert!(now <= vote_ref.end_at, EINVALID_END_TIME);

        vector::borrow_mut(&mut vote_ref.options, option_idx).vote_count += 1;

        vector::push_back(
            &mut vote_ref.actions,
            VoteSubmitAction { voter: voter_addr, option_idx, timestamp: now }
        );
        vector::push_back(&mut store.submitted, vote_idx);

        event::emit(VoteSubmittedEvent {
            vote_idx,
            voter: voter_addr,
            option_idx,
            timestamp: now
        });
    }

    // Public function to finalize a vote (can be triggered by the vote creator)
    // Also forces vote to end immediately by setting end_at to current timestamp
    public entry fun finalize_vote(caller: &signer, vote_idx: u64) acquires VoteStore {
        let signer_addr = signer::address_of(caller);
        let vote_store = borrow_global_mut<VoteStore>(MODULE_ADDR);
        let vote_ref = vector::borrow_mut(&mut vote_store.votes, vote_idx);

        assert!(
            signer_addr == vote_ref.creator,
            error::permission_denied(1)
        );

        let now = timestamp::now_seconds();
        vote_ref.end_at = now;
        finalize_vote_internal(vote_ref, vote_idx);

        // Emit VoteFinalizedEvent
        event::emit(VoteFinalizedEvent {
            vote_idx,
            caller: signer_addr,
            timestamp: now
        });
    }

    // Internal function to finalize a vote
    fun finalize_vote_internal(vote_ref: &mut Vote, vote_idx: u64) {
        assert!(!vote_ref.is_finalized, error::invalid_state(100));
        distribute_reward(vote_ref);
        vote_ref.is_finalized = true;
        refund_remaining_reward(vote_ref, vote_idx);
    }

    // Distributes reward tokens to eligible voters based on the reward rule
    // Supports FIFO and WINNER strategies
    fun distribute_reward(vote_ref: &Vote) {
        let reward_token = vote_ref.reward_token;
        let reward_per_person = vote_ref.reward_per_person;
        let max_winners = vote_ref.reward_max_winners;

        let store = vote_ref.reward_token_store;
        let store_signer =
            object::generate_signer_for_extending(&vote_ref.reward_token_extend_ref);

        let distributed = 0;

        // FIFO strategy: reward is given to the earliest voters up to max_winners
        if (vote_ref.reward_rule == RewardRule::FIFO) {
            let i = 0;
            while (i < vector::length(&vote_ref.actions) && distributed < max_winners) {
                let action = vector::borrow(&vote_ref.actions, i);
                let reward =
                    fungible_asset::withdraw(&store_signer, store, reward_per_person);
                let to_store =
                    primary_fungible_store::ensure_primary_store_exists(
                        action.voter, reward_token
                    );
                fungible_asset::deposit(to_store, reward);

                distributed = distributed + 1;
                i = i + 1;
            };
        // WINNER strategy: reward is given to voters who selected the most voted option(s)
        } else if (vote_ref.reward_rule == RewardRule::WINNER) {
            let max_votes = find_max_vote_count(&vote_ref.options);

            let i = 0;
            while (i < vector::length(&vote_ref.actions) && distributed < max_winners) {
                let action = vector::borrow(&vote_ref.actions, i);
                let option_idx = action.option_idx;
                let option_ref = vector::borrow(&vote_ref.options, option_idx);

                if (option_ref.vote_count == max_votes) {
                    let reward =
                        fungible_asset::withdraw(&store_signer, store, reward_per_person);
                    let to_store =
                        primary_fungible_store::ensure_primary_store_exists(
                            action.voter, reward_token
                        );
                    fungible_asset::deposit(to_store, reward);

                    distributed = distributed + 1;
                };
                i = i + 1;
            };
        };
    }

    fun find_max_vote_count(options: &vector<OptionData>): u64 {
        let max_votes = 0;
        let i = 0;
        while (i < vector::length(options)) {
            let count = vector::borrow(options, i).vote_count;
            if (count > max_votes) {
                max_votes = count;
            };
            i = i + 1;
        };
        max_votes
    }

    fun refund_remaining_reward(vote_ref: &Vote, vote_idx: u64) {
        let reward_token = vote_ref.reward_token;
        let store = vote_ref.reward_token_store;
        let store_signer =
            object::generate_signer_for_extending(&vote_ref.reward_token_extend_ref);

        let remaining = fungible_asset::balance(store);
        if (remaining > 0) {
            let reward = fungible_asset::withdraw(&store_signer, store, remaining);
            let to_store =
                primary_fungible_store::ensure_primary_store_exists(
                    vote_ref.creator, reward_token
                );
            fungible_asset::deposit(to_store, reward);

            event::emit(RefundRewardEvent {
                vote_idx,
                refunded_to: vote_ref.creator,
                amount: remaining,
                timestamp: timestamp::now_seconds()
            });
        };
    }
}
