// Copyright (c) MangoNet Labs Ltd.
// SPDX-License-Identifier: Apache-2.0

module mgo_system::genesis {
    use std::vector;

    use mgo::balance::{Self, Balance};
    use mgo::coin;
    use mgo::object::UID;
    use mgo::mgo::{Self, MGO};
    use mgo_system::mgo_system;
    use mgo::tx_context::{Self, TxContext};
    use mgo_system::validator::{Self, Validator};
    use mgo_system::validator_set;
    use mgo_system::mgo_system_state_inner;
    use mgo_system::stake_subsidy;
    use std::option::{Option, Self};

    struct GenesisValidatorMetadata has drop, copy {
        name: vector<u8>,
        description: vector<u8>,
        image_url: vector<u8>,
        project_url: vector<u8>,

        mgo_address: address,

        gas_price: u64,
        commission_rate: u64,

        protocol_public_key: vector<u8>,
        proof_of_possession: vector<u8>,

        network_public_key: vector<u8>,
        worker_public_key: vector<u8>,

        network_address: vector<u8>,
        p2p_address: vector<u8>,
        primary_address: vector<u8>,
        worker_address: vector<u8>,
    }

    struct GenesisChainParameters has drop, copy {
        protocol_version: u64,
        chain_start_timestamp_ms: u64,
        epoch_duration_ms: u64,

        // Stake Subsidy parameters
        stake_subsidy_start_epoch: u64,
        stake_subsidy_initial_distribution_amount: u64,
        stake_subsidy_period_length: u64,
        stake_subsidy_decrease_rate: u16,

        // Validator committee parameters
        max_validator_count: u64,
        min_validator_joining_stake: u64,
        validator_low_stake_threshold: u64,
        validator_very_low_stake_threshold: u64,
        validator_low_stake_grace_period: u64,
    }

    struct TokenDistributionSchedule {
        stake_subsidy_fund_mango: u64,
        allocations: vector<TokenAllocation>,
    }

    struct TokenAllocation {
        recipient_address: address,
        amount_mango: u64,

        /// Indicates if this allocation should be staked at genesis and with which validator
        staked_with_validator: Option<address>,
    }

    // Error codes
    /// The `create` function was called at a non-genesis epoch.
    const ENotCalledAtGenesis: u64 = 0;
    /// The `create` function was called with duplicate validators.
    const EDuplicateValidator: u64 = 1;

    #[allow(unused_function)]
    /// This function will be explicitly called once at genesis.
    /// It will create a singleton MgoSystemState object, which contains
    /// all the information we need in the system.
    fun create(
        mgo_system_state_id: UID,
        mgo_supply: Balance<MGO>,
        genesis_chain_parameters: GenesisChainParameters,
        genesis_validators: vector<GenesisValidatorMetadata>,
        token_distribution_schedule: TokenDistributionSchedule,
        ctx: &mut TxContext,
    ) {
        // Ensure this is only called at genesis
        assert!(tx_context::epoch(ctx) == 0, ENotCalledAtGenesis);

        let TokenDistributionSchedule {
            stake_subsidy_fund_mango,
            allocations,
        } = token_distribution_schedule;

        let subsidy_fund = balance::split(
            &mut mgo_supply,
            stake_subsidy_fund_mango,
        );
        let storage_fund = balance::zero();

        // Create all the `Validator` structs
        let validators = vector::empty();
        let count = vector::length(&genesis_validators);
        let i = 0;
        while (i < count) {
            let GenesisValidatorMetadata {
                name,
                description,
                image_url,
                project_url,
                mgo_address,
                gas_price,
                commission_rate,
                protocol_public_key,
                proof_of_possession,
                network_public_key,
                worker_public_key,
                network_address,
                p2p_address,
                primary_address,
                worker_address,
            } = *vector::borrow(&genesis_validators, i);

            let validator = validator::new(
                mgo_address,
                protocol_public_key,
                network_public_key,
                worker_public_key,
                proof_of_possession,
                name,
                description,
                image_url,
                project_url,
                network_address,
                p2p_address,
                primary_address,
                worker_address,
                gas_price,
                commission_rate,
                ctx
            );

            // Ensure that each validator is unique
            assert!(
                !validator_set::is_duplicate_validator(&validators, &validator),
                EDuplicateValidator,
            );

            vector::push_back(&mut validators, validator);

            i = i + 1;
        };

        // Allocate tokens and staking operations
        allocate_tokens(
            mgo_supply,
            allocations,
            &mut validators,
            ctx
        );

        // Activate all validators
        activate_validators(&mut validators);

        let system_parameters = mgo_system_state_inner::create_system_parameters(
            genesis_chain_parameters.epoch_duration_ms,
            genesis_chain_parameters.stake_subsidy_start_epoch,

            // Validator committee parameters
            genesis_chain_parameters.max_validator_count,
            genesis_chain_parameters.min_validator_joining_stake,
            genesis_chain_parameters.validator_low_stake_threshold,
            genesis_chain_parameters.validator_very_low_stake_threshold,
            genesis_chain_parameters.validator_low_stake_grace_period,

            ctx,
        );

        let stake_subsidy = stake_subsidy::create(
            subsidy_fund,
            genesis_chain_parameters.stake_subsidy_initial_distribution_amount,
            genesis_chain_parameters.stake_subsidy_period_length,
            genesis_chain_parameters.stake_subsidy_decrease_rate,
            ctx,
        );

        mgo_system::create(
            mgo_system_state_id,
            validators,
            storage_fund,
            genesis_chain_parameters.protocol_version,
            genesis_chain_parameters.chain_start_timestamp_ms,
            system_parameters,
            stake_subsidy,
            ctx,
        );
    }

    fun allocate_tokens(
        mgo_supply: Balance<MGO>,
        allocations: vector<TokenAllocation>,
        validators: &mut vector<Validator>,
        ctx: &mut TxContext,
    ) {

        while (!vector::is_empty(&allocations)) {
            let TokenAllocation {
                recipient_address,
                amount_mango,
                staked_with_validator,
            } = vector::pop_back(&mut allocations);

            let allocation_balance = balance::split(&mut mgo_supply, amount_mango);

            if (option::is_some(&staked_with_validator)) {
                let validator_address = option::destroy_some(staked_with_validator);
                let validator = validator_set::get_validator_mut(validators, validator_address);
                validator::request_add_stake_at_genesis(
                    validator,
                    allocation_balance,
                    recipient_address,
                    ctx
                );
            } else {
                mgo::transfer(
                    coin::from_balance(allocation_balance, ctx),
                    recipient_address,
                );
            };
        };
        vector::destroy_empty(allocations);

        // Provided allocations must fully allocate the mgo_supply and there
        // should be none left at this point.
        balance::destroy_zero(mgo_supply);
    }

    fun activate_validators(validators: &mut vector<Validator>) {
        // Activate all genesis validators
        let count = vector::length(validators);
        let i = 0;
        while (i < count) {
            let validator = vector::borrow_mut(validators, i);
            validator::activate(validator, 0);

            i = i + 1;
        };

    }
}
