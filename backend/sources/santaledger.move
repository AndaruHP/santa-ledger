module santaledger::santaledger {
    use std::string::String;
    use iota::coin::{Self, Coin};
    use iota::iota::IOTA;
    use iota::balance::{Self, Balance};
    use iota::event;
    use iota::random::{Self, Random};

    // =================== Errors ===================
    const EInvalidDeedType: u64 = 0;
    const ENotAuthorized: u64 = 1;
    const EInsufficientBalance: u64 = 2;

    // =================== Structs ===================
    
    /// Represents a single deed (good or bad)
    public struct Deed has store, copy, drop {
        description: String,
        is_good: bool,
        reported_by: address,
        timestamp: u64,
    }

    /// User's Santa Ledger record
    public struct UserLedger has key, store {
        id: UID,
        owner: address,
        deeds: vector<Deed>,
        good_count: u64,
        bad_count: u64,
        reward_balance: Balance<IOTA>,
    }

    /// Shared Santa Registry
    public struct SantaRegistry has key {
        id: UID,
        admin: address,
        reward_pool: Balance<IOTA>,
    }

    // =================== Events ===================
    
    public struct DeedRecorded has copy, drop {
        user: address,
        deed_description: String,
        is_good: bool,
        reported_by: address,
    }

    public struct RewardClaimed has copy, drop {
        user: address,
        amount: u64,
        good_deeds: u64,
        bad_deeds: u64,
    }

    // =================== Init Function ===================
    
    fun init(ctx: &mut TxContext) {
        let registry = SantaRegistry {
            id: object::new(ctx),
            admin: ctx.sender(),
            reward_pool: balance::zero(),
        };
        transfer::share_object(registry);
    }

    // =================== Public Functions ===================
    
    /// Create a new user ledger and return it (FIXED: removed self-transfer)
    /// Now returns the ledger for better composability
    public fun create_ledger(ctx: &mut TxContext): UserLedger {
        let ledger = UserLedger {
            id: object::new(ctx),
            owner: ctx.sender(),
            deeds: vector::empty(),
            good_count: 0,
            bad_count: 0,
            reward_balance: balance::zero(),
        };
        ledger
    }

    /// Helper function for users who want direct transfer
    /// This can be called by users who don't need composability
    #[allow(lint(self_transfer))]
    public fun create_and_transfer_ledger(ctx: &mut TxContext) {
        let ledger = create_ledger(ctx);
        transfer::transfer(ledger, ctx.sender());
    }

    /// User records their own deed
    public fun record_self_deed(
        ledger: &mut UserLedger,
        description: String,
        is_good: bool,
        ctx: &mut TxContext
    ) {
        let sender = ctx.sender();
        assert!(ledger.owner == sender, ENotAuthorized);
        
        let deed = Deed {
            description,
            is_good,
            reported_by: sender,
            timestamp: ctx.epoch(),
        };
        
        vector::push_back(&mut ledger.deeds, deed);
        
        if (is_good) {
            ledger.good_count = ledger.good_count + 1;
        } else {
            ledger.bad_count = ledger.bad_count + 1;
        };

        event::emit(DeedRecorded {
            user: ledger.owner,
            deed_description: description,
            is_good,
            reported_by: sender,
        });
    }

    /// Another user reports a deed for someone else
    public fun report_deed(
        ledger: &mut UserLedger,
        description: String,
        is_good: bool,
        ctx: &mut TxContext
    ) {
        let reporter = ctx.sender();
        
        let deed = Deed {
            description,
            is_good,
            reported_by: reporter,
            timestamp: ctx.epoch(),
        };
        
        vector::push_back(&mut ledger.deeds, deed);
        
        if (is_good) {
            ledger.good_count = ledger.good_count + 1;
        } else {
            ledger.bad_count = ledger.bad_count + 1;
        };

        event::emit(DeedRecorded {
            user: ledger.owner,
            deed_description: description,
            is_good,
            reported_by: reporter,
        });
    }

    /// FIXED: Made entry function (non-public) to prevent randomness manipulation
    /// Entry functions are called directly and can't be inspected in advance
    entry fun claim_santa_reward(
        ledger: &mut UserLedger,
        registry: &mut SantaRegistry,
        r: &Random,
        ctx: &mut TxContext
    ) {
        let sender = ctx.sender();
        assert!(ledger.owner == sender, ENotAuthorized);
        
        let total_deeds = ledger.good_count + ledger.bad_count;
        assert!(total_deeds > 0, EInvalidDeedType);
        
        // Generate random number between 0 and total_deeds
        let mut generator = random::new_generator(r, ctx);
        let random_num = random::generate_u64_in_range(&mut generator, 0, total_deeds);
        
        // If random number is less than good_count, user is considered "good"
        let is_rewarded = random_num < ledger.good_count;
        
        if (is_rewarded) {
            // Calculate reward based on ratio (simple: 1000 IOTA per good deed percentage point)
            let good_percentage = (ledger.good_count * 100) / total_deeds;
            let reward_amount = good_percentage * 1000; // Reward in MIST (smallest unit)
            
            // Transfer reward from registry pool
            if (balance::value(&registry.reward_pool) >= reward_amount) {
                let reward = coin::take(&mut registry.reward_pool, reward_amount, ctx);
                balance::join(&mut ledger.reward_balance, coin::into_balance(reward));
                
                event::emit(RewardClaimed {
                    user: sender,
                    amount: reward_amount,
                    good_deeds: ledger.good_count,
                    bad_deeds: ledger.bad_count,
                });
            };
        };
    }

    /// Admin function to fund the reward pool
    public fun fund_reward_pool(
        registry: &mut SantaRegistry,
        payment: Coin<IOTA>,
        ctx: &mut TxContext
    ) {
        assert!(ctx.sender() == registry.admin, ENotAuthorized);
        balance::join(&mut registry.reward_pool, coin::into_balance(payment));
    }

    /// Withdraw rewards from user ledger
    public fun withdraw_rewards(
        ledger: &mut UserLedger,
        amount: u64,
        ctx: &mut TxContext
    ): Coin<IOTA> {
        let sender = ctx.sender();
        assert!(ledger.owner == sender, ENotAuthorized);
        assert!(balance::value(&ledger.reward_balance) >= amount, EInsufficientBalance);
        
        coin::take(&mut ledger.reward_balance, amount, ctx)
    }

    // =================== View Functions ===================
    
    /// Get user's deed counts
    public fun get_deed_counts(ledger: &UserLedger): (u64, u64) {
        (ledger.good_count, ledger.bad_count)
    }

    /// Get total deeds
    public fun get_total_deeds(ledger: &UserLedger): u64 {
        vector::length(&ledger.deeds)
    }

    /// Get reward balance
    public fun get_reward_balance(ledger: &UserLedger): u64 {
        balance::value(&ledger.reward_balance)
    }

    /// Calculate winning probability (returns percentage * 100 for precision)
    public fun calculate_good_probability(ledger: &UserLedger): u64 {
        let total = ledger.good_count + ledger.bad_count;
        if (total == 0) return 0;
        
        (ledger.good_count * 10000) / total // Returns percentage * 100 (e.g., 8333 = 83.33%)
    }
}