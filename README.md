# aptos-vote-protocol

A aptos module for managing decentralized voting logic on the Aptos blockchain.  
It supports vote creation, editing (before start time), on-chain submission, reward distribution, and refunding logic.

---

## 📦 Package Info

```toml
[package]
name = "Vote"
version = "0.0.1"
authors = ["MilanoM"]

[addresses]
vote = "<deployed_module_address>"
tests = "0xC0FFEE"
std = "0x1"
aptos_std = "0x1"
aptos_framework = "0x1"

[dependencies]
AptosFramework = {
  git = "https://github.com/aptos-labs/aptos-core.git",
  rev = "fac9b40330ac7607179d95385992ef4903bd34c9"  //1.30 Release on Jun 12, 2025
  subdir = "aptos-move/framework/aptos-framework"
}
```

---

## ⚙️ Module: `vote::protocol`

### Structs

- **VoteConfig**  
  Stores the protocol admin address.

- **Vote**  
  Represents a vote with metadata, options, reward logic, and record of submissions.

- **OptionData**  
  Holds the option text and current vote count.

- **VoteStore**  
  Global container storing all created votes and the `next_vote_idx`.

- **VoterStore**  
  Per-user structure that tracks submitted vote indices.

- **VoteSubmitAction**  
  Captures a user's vote submission with voter address, option index, and timestamp.

- **RewardRule** (enum)
  Configures reward distribution logic:
  - `FIFO` (0): First-come-first-served
  - `WINNER` (1): Rewards all voters who chose the most-voted option(s), capped by `max_winners`
  - **TODO** This enum can be extended for custom reward strategies

---

## ⏱️ Reward Distribution Timing

The timing of reward distribution depends on the configured `RewardRule`:

| RewardRule | Distribution Time       | Description                                                                                                                               |
| ---------- | ----------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `FIFO`     | **Immediately** on vote | The first `max_winners` voters receive rewards directly at the time of voting. Later votes are still accepted but do not receive rewards. |
| `WINNER`   | **Upon finalization**   | Rewards are distributed only after calling `finalize_vote`, to voters who selected the most popular option(s), up to `max_winners`.       |

> Reward tokens are pre-funded when creating a vote and refunded if unused.

---

### View Functions

- **`get_vote_info(vote_idx)`**  
   Returns public vote data: creator, time window, reward configuration, option texts, vote actions per option, and current balance in reward pool.

  Example:

  ```
  {
  "creator": "0x...",
  "title": "Which feature first?",
  "start_at": 100,
  "end_at": 200,
  "reward_rule": 0,
  "reward_token": "0xToken",
  "reward_per_person": 10,
  "reward_max_winners": 3,
  "option_texts": ["A", "B", "C"],
  "actions": [[...], [...], [...]],
  "reward_store_balance": 30
  }
  ```

---

### Entry Functions

- **`init(signer)`**
  Initializes protocol by storing `VoteConfig` and empty `VoteStore`.
  Must be called by `@vote` address.

- **`set_admin(admin, new_admin)`**
  Sets a new protocol admin. Only callable by current admin.

- **`create_vote(...)`**
  Creates a new vote and locks reward tokens into the protocol.
  Allocates reward tokens by withdrawing them into a dedicated reward store.
  Note: `start_at` must be earlier than `end_at`.

- **`edit_vote(...)`**
  Allows modifying vote metadata and reward parameters if the vote has not started yet.
  Adjusts reward token balances if the total reward changes.

- **`submit_vote(voter, vote_idx, option_idx)`**
  Submits a vote by a user.
  Enforces one vote per user per vote, ensures it's within time window, and records submission.

- **`finalize_vote(caller, vote_idx)`**
  Manually ends a vote (sets end time to `now`) and triggers reward distribution and refund of unused tokens.

---

### Internal Logic

- **`distribute_reward(vote_ref)`**
  Depending on `RewardRule`, rewards eligible voters:

  - FIFO: earliest submissions up to `max_winners`
  - WINNER: voters who chose the top option(s), capped by `max_winners`

- **`refund_remaining_reward(vote_ref)`**
  Refunds any remaining tokens in the reward store to the vote creator after reward distribution.

---

## 🧪 Testing

Test coverage includes:

- Basic vote creation and info retrieval
- Editing before start time with reward diff adjustment
- FIFO immediate reward distribution
- WINNER-based finalization reward
- Negative tests (duplicate votes, early vote, late vote)
- Balance verification and reward cap enforcement

---

## 🛠 Build & Deploy

```bash
# Set Move.toml
export VOTE_ADDR=0x... # your vote module address

# Compile the package
aptos move compile

# Run the test suite
aptos move test
```

## 🧭 Future Work

- **Support additional reward rule types:**

  - **Proportional**: Distribute rewards in proportion to the number of votes each option receives.  
    _Example_: For a total of 100 points, if Option A has 3 votes and Option B has 1 vote, then users who voted for A receive 75 points, and users who voted for B receive 25 points.
  - **Lottery**: Randomly select up to `max_winners` among all voters to receive the reward.
  - **Custom external logic**:  
    Call an external protocol (e.g., `0xCustom::external_distribution`) to determine how rewards are distributed.  
    This allows communities to define and execute tailored reward strategies.

- **Add vote cancellation and re-submission logic**

- **Add off-chain signature-based vote aggregation (batch mode)**
