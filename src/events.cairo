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
pub struct DoubleOrHalveEvent {
    pub user: ContractAddress,
    pub tickets: u256,
    pub won: bool,
    pub random_word: felt252,
}

#[derive(Drop, starknet::Event)]
pub struct DrawEvent {
    pub winner: ContractAddress,
    pub tickets: u256,
}

#[derive(Drop, starknet::Event)]
pub struct SpinCallerEvent {
    pub caller: ContractAddress,
    pub user: ContractAddress,
}

#[derive(Drop, starknet::Event)]
pub struct DrawCallerEvent {
    pub caller: ContractAddress,
    pub authorized: bool,
}

#[derive(Drop, starknet::Event)]
pub struct SpinSignup {
    pub user: ContractAddress,
    pub sign: bool,
}

#[derive(Drop, starknet::Event)]
pub struct PoolResetEvent {
    pub reset_by: ContractAddress,
    pub users_affected: u64,
    pub tickets_cleared: u256,
    pub timestamp: u64,
}
