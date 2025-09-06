use lotto::types::{DoubleOrNothingConfig, UserInfo, UserTickets};
use starknet::ContractAddress;

#[starknet::interface]
pub trait ICartridgeVRF<TContractState> {
    fn set_vrf_provider(ref self: TContractState, new_vrf_provider: ContractAddress);
    fn get_vrf_provider(self: @TContractState) -> ContractAddress;
}

#[starknet::interface]
pub trait IAkiLottoDrawer<TContractState> {
    fn add_wallet(ref self: TContractState) -> bool;
    fn get_user_info(self: @TContractState, user: ContractAddress) -> UserInfo;

    fn add_tickets(ref self: TContractState, user: ContractAddress, tickets: u256);
    fn add_tickets_batch(ref self: TContractState, user_tickets: Array<UserTickets>);

    // func to be called by the owner to remove tickets from a user
    fn remove_tickets(ref self: TContractState, user: ContractAddress, tickets: u256);
    fn remove_tickets_batch(ref self: TContractState, user_tickets: Array<UserTickets>);

    // func to be called by the owner to get the contract address and draw the winner,
    // returns the winner address and the number of tickets and emits a DrawEvent
    fn draw(ref self: TContractState) -> (ContractAddress, u256);

    // func to be called by the owner to set double or nothing interval
    fn set_double_or_nothing_interval(ref self: TContractState, start: u64, end: u64);
    fn is_double_active(self: @TContractState) -> bool;
    fn get_double_interval(self: @TContractState) -> DoubleOrNothingConfig;

    // func for double or nothing, called by the user to double the tickets of a them if they are
    // connected a boolean indicating if the user won
    fn double_spin(ref self: TContractState, user: ContractAddress) -> bool;
}

#[starknet::interface]
pub trait IUpgradeable<TContractState> {
    fn upgrade(ref self: TContractState, new_class_hash: starknet::ClassHash);
    fn get_implementation(self: @TContractState) -> starknet::ClassHash;
    fn get_version(self: @TContractState) -> u32;
}
