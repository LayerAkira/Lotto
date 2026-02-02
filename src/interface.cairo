use lotto::types::{DoubleOrNothingConfig, DrawCallerInfo, PoolStats, UserInfo, UserTickets};
use starknet::ContractAddress;

#[starknet::interface]
pub trait ICartridgeVRF<TContractState> {
    fn set_vrf_provider(ref self: TContractState, provider: ContractAddress);
    fn get_vrf_provider(self: @TContractState) -> ContractAddress;
}

#[starknet::interface]
pub trait IAkiLottoDrawer<TContractState> {
    /// Connect wallet to participate in the lottery
    fn add_wallet(ref self: TContractState) -> bool;

    /// Get user's current state
    fn get_user_info(self: @TContractState, user: ContractAddress) -> UserInfo;

    /// Add tickets to a single user
    fn add_tickets(ref self: TContractState, user: ContractAddress, tickets: u256);

    /// Add tickets to multiple users in one transaction
    fn add_tickets_batch(ref self: TContractState, user_tickets: Array<UserTickets>);

    /// Remove tickets from a single user
    fn remove_tickets(ref self: TContractState, user: ContractAddress, tickets: u256);

    /// Remove tickets from multiple users in one transaction
    fn remove_tickets_batch(ref self: TContractState, user_tickets: Array<UserTickets>);

    /// Execute a draw to select a winner (authorized callers only)
    /// Returns (winner_address, winner_ticket_count)
    fn draw(ref self: TContractState) -> (ContractAddress, u256);

    /// Check if an address has won in any past draw
    fn has_won(self: @TContractState, user: ContractAddress) -> bool;

    /// Set the time window for double-or-nothing (Owner only)
    fn set_double_or_nothing_interval(ref self: TContractState, start: u64, end: u64);

    /// Check if double-or-nothing is currently active
    fn is_double_active(self: @TContractState) -> bool;

    /// Get the double-or-nothing time configuration
    fn get_double_interval(self: @TContractState) -> DoubleOrNothingConfig;

    /// Execute a double-or-nothing spin
    /// Returns true if user won (doubled), false if lost (halved)
    fn double_spin(ref self: TContractState) -> bool;

    /// Reset all user tickets to zero while keeping connections intact
    fn reset_pool(ref self: TContractState);

    /// Get current pool statistics
    fn get_pool_stats(self: @TContractState) -> PoolStats;

    /// Authorize or revoke a draw caller
    fn set_draw_caller(ref self: TContractState, caller: ContractAddress, authorized: bool);

    /// Check if an address is authorized to call draw
    fn is_draw_caller(self: @TContractState, caller: ContractAddress) -> bool;

    /// Get draw caller statistics
    fn get_draw_caller_info(self: @TContractState, caller: ContractAddress) -> DrawCallerInfo;
}

#[starknet::interface]
pub trait IUpgradeable<TContractState> {
    fn upgrade(ref self: TContractState, new_class_hash: starknet::ClassHash);
    fn get_implementation(self: @TContractState) -> starknet::ClassHash;
    fn get_version(self: @TContractState) -> u32;
}
