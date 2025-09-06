use starknet::{ClassHash, ContractAddress};

#[derive(Drop, starknet::Event)]
pub struct UpgradeEvent {
    pub old_class_hash: ClassHash,
    pub new_class_hash: ClassHash,
    pub version: u32,
}

#[derive(Drop, starknet::Event)]
pub struct UserConnectEvent {
    pub user: ContractAddress,
    pub tickets: u256,
    pub has_spinned: bool,
}

#[derive(Drop, starknet::Event)]
pub struct DoubleOrNothingEvent {
    pub user: ContractAddress,
    pub tickets: u256,
    pub won: bool,
    pub random_word: felt252
}

#[derive(Drop, starknet::Event)]
pub struct DrawEvent {
    pub winner: ContractAddress,
    pub tickets: u256,
}

#[derive(Drop, starknet::Event)]
pub struct SpinCallerEvent {
    pub caller: ContractAddress,
}

#[derive(Drop, starknet::Event)]
pub struct DrawCallerEvent {
    pub caller: ContractAddress,
}

#[derive(Drop, starknet::Event)]
pub struct SpinSignup {
    pub user: ContractAddress,
    pub sign: bool
}
