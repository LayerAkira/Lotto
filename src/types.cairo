use starknet::ContractAddress;

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
pub struct UserInfo {
    pub tickets: u256, // number of tickets the user has
    pub is_connected: bool, // indicates if the user has connected their wallet
    pub has_spinned: bool // indicates if the user has already spun for double or nothing
}

#[derive(Copy, Drop, Serde, starknet::Store, PartialEq)]
pub struct DoubleOrNothingConfig {
    pub start: u64, // UTC in seconds when the double or nothing starts, 0 means disabled
    pub end: u64 // UTC in seconds when the double or nothing ends, 0 means disabled
}

#[derive(Copy, Drop, Serde)]
pub struct UserTickets {
    pub user: ContractAddress,
    pub tickets: u256,
}
