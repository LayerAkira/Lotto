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
    // func to be called by the owner to remove tickets from a user
    fn remove_tickets(ref self: TContractState, user: ContractAddress, tickets: u256);
    fn get_total_tickets(self: @TContractState) -> u256;

    // func to be called by the owner to get the contract address and draw the winner,
    // returns the winner address and the number of tickets and emits a DrawEvent
    fn draw(ref self: TContractState) -> (ContractAddress, u256);

    // func to be called by the owner to set double or nothing interval
    fn set_double_or_nothing_interval(ref self: TContractState, start: u64, end: u64);
    fn is_double_active(self: @TContractState) -> bool;
    fn get_double_interval(self: @TContractState) -> DoubleOrNothingConfig;

    // func for double or nothing, called by the user to double the tickets of a them if they are
    // connected a boolean indicating if the user won
    fn double_spin(ref self: TContractState) -> bool;
}

#[starknet::interface]
pub trait IUpgradeable<TContractState> {
    fn upgrade(ref self: TContractState, new_class_hash: starknet::ClassHash);
    fn get_implementation(self: @TContractState) -> starknet::ClassHash;
    fn get_version(self: @TContractState) -> u32;
}

#[starknet::contract]
mod AkiLottoDrawer {
    use cartridge_vrf::{IVrfProviderDispatcher, IVrfProviderDispatcherTrait, Source};
    use core::traits::{Into, TryInto};
    use starknet::storage::{
        Map, MutableVecTrait, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
        Vec,
    };
    use starknet::syscalls::replace_class_syscall;
    use starknet::{
        ClassHash, ContractAddress, get_block_timestamp, get_caller_address,
    };
    use super::{DoubleOrNothingConfig, IAkiLottoDrawer, IUpgradeable, UserInfo};

    #[storage]
    struct Storage {
        user_info: Map<ContractAddress, UserInfo>,
        user_list: Vec<ContractAddress>, // to be used for iterating over users
        total_tickets: u256,
        owner: ContractAddress,
        has_drawed: bool, // indicates if the draw has been done
        double_or_nothing_cfg: DoubleOrNothingConfig,
        min_block_number_storage: u64,
        vrf_contract_address: ContractAddress,
        implementation_hash: ClassHash,
        contract_version: u32,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        DoubleOrNothingEvent: DoubleOrNothingEvent,
        DrawEvent: DrawEvent,
        UserConnectEvent: UserConnectEvent,
        UpgradeEvent: UpgradeEvent,
    }

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
    }

    #[derive(Drop, starknet::Event)]
    pub struct DrawEvent {
        pub winner: ContractAddress,
        pub tickets: u256,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        vrf_contract_address: ContractAddress,
        impl_hash: ClassHash,
    ) {
        self.owner.write(owner);
        self.vrf_contract_address.write(vrf_contract_address);

        self.implementation_hash.write(impl_hash);
        self.contract_version.write(1_u32);
    }

    fn _only_owner(self: @ContractState) {
        assert!(get_caller_address() == self.owner.read(), "Only owner can perform this action");
    }

    #[external(v0)]
    fn set_owner(ref self: ContractState, owner: ContractAddress) {
        _only_owner(@self);
        self.owner.write(owner);
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> ContractAddress {
        self.owner.read()
    }

    fn _check_and_push_user(ref self: ContractState, user: ContractAddress) {
        let len = self.user_list.len();
        let mut found = false;
        for i in 0_u64..len {
            if self.user_list.at(i).read() == user {
                found = true;
                break;
            }
        }
        if !found {
            self.user_list.push(user);
        }
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            _only_owner(@self);

            let old_class_hash = self.implementation_hash.read();

            replace_class_syscall(new_class_hash).unwrap();

            self.implementation_hash.write(new_class_hash);
            let new_version = self.contract_version.read() + 1;
            self.contract_version.write(new_version);

            self.emit(UpgradeEvent { old_class_hash, new_class_hash, version: new_version });
        }

        fn get_implementation(self: @ContractState) -> ClassHash {
            self.implementation_hash.read()
        }

        fn get_version(self: @ContractState) -> u32 {
            self.contract_version.read()
        }
    }

    #[abi(embed_v0)]
    impl AkiLottoDrawerImpl of IAkiLottoDrawer<ContractState> {
        fn add_wallet(ref self: ContractState) -> bool {
            let caller = get_caller_address();
            let user = self.user_info.entry(caller).read();
            _check_and_push_user(ref self, caller);

            let updated_user = UserInfo {
                tickets: user.tickets, is_connected: true, has_spinned: false,
            };

            self.user_info.entry(caller).write(updated_user);

            self
                .emit(
                    UserConnectEvent {
                        user: caller,
                        tickets: updated_user.tickets,
                        has_spinned: updated_user.has_spinned,
                    },
                );
            true
        }

        fn get_user_info(self: @ContractState, user: ContractAddress) -> UserInfo {
            self.user_info.entry(user).read()
        }

        fn set_double_or_nothing_interval(ref self: ContractState, start: u64, end: u64) {
            _only_owner(@self);
            assert!(start < end, "Start time must be less than end time");

            self.double_or_nothing_cfg.write(DoubleOrNothingConfig { start: start, end: end });
        }

        fn is_double_active(self: @ContractState) -> bool {
            let now = get_block_timestamp();
            let cfg = self.double_or_nothing_cfg.read();
            cfg.start != 0 && now >= cfg.start && now <= cfg.end
        }

        fn get_double_interval(self: @ContractState) -> DoubleOrNothingConfig {
            self.double_or_nothing_cfg.read()
        }

        fn add_tickets(ref self: ContractState, user: ContractAddress, tickets: u256) {
            _only_owner(@self);
            assert!(tickets > 0, "Tickets to add must be greater than zero");
            _check_and_push_user(ref self, user);

            let mut user_info = self.user_info.entry(user).read();

            user_info.tickets += tickets;
            self.user_info.entry(user).write(user_info);
            self.total_tickets.write(self.total_tickets.read() + tickets);
        }

        fn remove_tickets(ref self: ContractState, user: ContractAddress, tickets: u256) {
            _only_owner(@self);
            assert!(tickets > 0, "Tickets to remove must be greater than zero");

            let mut user_info = self.user_info.entry(user).read();

            assert!(user_info.tickets >= tickets, "Not enough tickets to remove");
            user_info.tickets -= tickets;
            self.user_info.entry(user).write(user_info);
            self.total_tickets.write(self.total_tickets.read() - tickets);
        }

        fn get_total_tickets(self: @ContractState) -> u256 {
            self.total_tickets.read()
        }

        fn draw(ref self: ContractState) -> (ContractAddress, u256) {
            assert!(!self.has_drawed.read(), "Draw has already been done");
            _only_owner(@self);
            assert!(self.total_tickets.read() > 0, "No tickets to draw");
            assert!(self.user_list.len() > 0, "No users to draw from");

            _draw_winner(ref self)
        }

        fn double_spin(ref self: ContractState) -> bool {
            assert!(self.is_double_active(), "Double or Nothing is not active");
            let caller = get_caller_address();
            let mut caller_info = self.user_info.entry(caller).read();

            assert!(
                caller_info.is_connected, "Wallet Connection Required for Double or Nothing Spin",
            );
            assert!(!caller_info.has_spinned, "Already Spinned for Double or Nothing");
            assert!(caller_info.tickets > 0, "No tickets");
            assert!(!self.has_drawed.read(), "Draw has already been done");

            _double_spin(ref self)
        }
    }

    fn _double_spin(ref self: ContractState) -> bool {
        let caller = get_caller_address();
        let mut caller_info = self.user_info.entry(caller).read();

        // consume random number from VRF provider, note: request random must be called along with double spin
        let vrf_provider = IVrfProviderDispatcher { contract_address: self.vrf_contract_address.read() };
        let random: u256 = vrf_provider.consume_random(Source::Nonce(caller)).into();

        // head/tail logic: even → double, odd → nothing
        let win = (random.low & 1) == 0;

        let tickets = if win {
            self.total_tickets.write(self.total_tickets.read() + caller_info.tickets);
            caller_info.tickets * 2
        } else {
            self.total_tickets.write(self.total_tickets.read() - caller_info.tickets);
            0
        };
        caller_info.has_spinned = true;
        caller_info.tickets = tickets;
        self.user_info.entry(caller).write(caller_info);

        self.emit(DoubleOrNothingEvent { user: caller, tickets: caller_info.tickets, won: win });
        win
    }

    fn _draw_winner(ref self: ContractState) -> (ContractAddress, u256) {
        let mut connected_user = array![];
        let mut total_tickets = 0_u256;
        for i in 0_u64..self.user_list.len() {
            let addr: ContractAddress = self.user_list.at(i).read();
            let user_info: UserInfo = self.user_info.entry(addr).read();
            if user_info.is_connected {
                connected_user.append(addr);
                total_tickets += user_info.tickets;
            }
        }

        assert!(total_tickets > 0_u256, "No connected users with tickets");
        assert!(connected_user.len() > 0, "No connected users to draw from");

        let vrf_provider = IVrfProviderDispatcher { contract_address: self.vrf_contract_address.read() };
        let random: u256 = vrf_provider.consume_random(Source::Nonce(get_caller_address())).into();
        let r: u256 = (random % total_tickets).try_into().unwrap();

        let mut cumulative = 0_u256;
        let len = connected_user.len();
        let mut i = 0_u32;

        let mut res: (ContractAddress, u256) = (self.owner.read(), 0_u256);
        while i != len {
            let addr: ContractAddress = *connected_user.at(i);
            let user_info: UserInfo = self.user_info.entry(addr).read();
            cumulative += user_info.tickets;
            if cumulative > r {
                self.emit(DrawEvent { winner: addr, tickets: user_info.tickets });
                res = (addr, user_info.tickets);
                break;
            }
            i += 1;
        }

        let (winner_addr, tickets) = res;
        assert!(winner_addr != self.owner.read() && tickets != 0_u256, "No winner found");
        self.has_drawed.write(true);

        res
    }

    #[abi(embed_v0)]
    impl CartridgeVRFOracle of super::ICartridgeVRF<ContractState> {
        fn set_vrf_provider(ref self: ContractState, new_vrf_provider: ContractAddress) {
            _only_owner(@self);
            self.vrf_contract_address.write(new_vrf_provider);
        }

        fn get_vrf_provider(self: @ContractState) -> ContractAddress {
            self.vrf_contract_address.read()
        }
    }
}
