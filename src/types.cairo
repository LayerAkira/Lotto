use starknet::ContractAddress;

/// User's participation state in the lottery
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Debug)]
pub struct UserInfo {
    pub tickets: u256,
    pub is_connected: bool,
    pub has_spinned: bool,
}

/// Time window configuration for double-or-nothing feature
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Debug)]
pub struct DoubleOrNothingConfig {
    pub start: u64,  // UTC timestamp (seconds)
    pub end: u64,    // UTC timestamp (seconds)
}

/// Batch operation input for ticket modifications
#[derive(Copy, Drop, Serde)]
pub struct UserTickets {
    pub user: ContractAddress,
    pub tickets: u256,
}

/// Statistics for authorized draw callers
#[derive(Copy, Drop, Serde, starknet::Store, PartialEq, Debug)]
pub struct DrawCallerInfo {
    pub is_authorized: bool,
    pub draw_count: u64,
    pub last_draw_timestamp: u64,
}

/// Pool statistics snapshot
#[derive(Copy, Drop, Serde, Debug)]
pub struct PoolStats {
    pub total_tickets: u256,
    pub total_users: u64,
    pub connected_users: u64,
    pub total_draws: u64,
}
