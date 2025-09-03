#[starknet::contract]
mod AkiLottoDrawer {
    use cartridge_vrf::{IVrfProviderDispatcher, IVrfProviderDispatcherTrait, Source};
    use core::traits::{Into, TryInto};
    use lotto::events::{
        DoubleOrNothingEvent, DrawEvent, RandomnessCallerEvent, UpgradeEvent, UserConnectEvent,
    };
    use lotto::interface::{IAkiLottoDrawer, ICartridgeVRF, IUpgradeable};
    use lotto::types::{DoubleOrNothingConfig, UserInfo, UserTickets};
    use starknet::storage::{
        Map, MutableVecTrait, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
        Vec,
    };
    use starknet::syscalls::replace_class_syscall;
    use starknet::{
        ClassHash, ContractAddress, get_block_timestamp, get_caller_address,
    };

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
        randomness_caller: Map<ContractAddress, ContractAddress>,
        randomness_caller_rev: Map<ContractAddress, ContractAddress>,
        draw_caller: ContractAddress,
        past_winners: Vec<ContractAddress>,
        winner_set: Map<ContractAddress, bool>,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        DoubleOrNothingEvent: DoubleOrNothingEvent,
        DrawEvent: DrawEvent,
        UserConnectEvent: UserConnectEvent,
        UpgradeEvent: UpgradeEvent,
        RandomnessCallerEvent: RandomnessCallerEvent,
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

    #[external(v0)]
    fn set_draw_caller(ref self: ContractState, caller: ContractAddress) {
        _only_owner(@self);
        self.draw_caller.write(caller);
    }

    #[external(v0)]
    fn get_draw_caller(self: @ContractState) -> ContractAddress {
        self.draw_caller.read()
    }

    #[external(v0)]
    fn has_won(self: @ContractState, user: ContractAddress) -> bool {
        self.winner_set.entry(user).read()
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
            self.draw_caller.write(self.owner.read());

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

        fn add_tickets_batch(ref self: ContractState, user_tickets: Array<UserTickets>) {
            _only_owner(@self);
            assert!(user_tickets.len() > 0, "Batch cannot be empty");

            let mut total_tickets_to_add = 0_u256;
            let mut i = 0_u32;
            let len = user_tickets.len();

            while i < len {
                let user_ticket = *user_tickets.at(i);
                assert!(user_ticket.tickets > 0, "Tickets to add must be greater than zero");
                total_tickets_to_add += user_ticket.tickets;
                i += 1;
            }

            i = 0_u32;
            while i < len {
                let user_ticket = *user_tickets.at(i);
                _check_and_push_user(ref self, user_ticket.user);

                let mut user_info = self.user_info.entry(user_ticket.user).read();
                user_info.tickets += user_ticket.tickets;
                self.user_info.entry(user_ticket.user).write(user_info);
                i += 1;
            }

            self.total_tickets.write(self.total_tickets.read() + total_tickets_to_add);
        }

        fn remove_tickets_batch(ref self: ContractState, user_tickets: Array<UserTickets>) {
            _only_owner(@self);
            assert!(user_tickets.len() > 0, "Batch cannot be empty");

            let mut total_tickets_to_remove = 0_u256;
            let mut i = 0_u32;
            let len = user_tickets.len();

            while i < len {
                let user_ticket = *user_tickets.at(i);
                assert!(user_ticket.tickets > 0, "Tickets to remove must be greater than zero");

                let user_info = self.user_info.entry(user_ticket.user).read();
                assert!(user_info.tickets >= user_ticket.tickets, "Not enough tickets to remove");

                total_tickets_to_remove += user_ticket.tickets;
                i += 1;
            }

            i = 0_u32;
            while i < len {
                let user_ticket = *user_tickets.at(i);
                let mut user_info = self.user_info.entry(user_ticket.user).read();
                user_info.tickets -= user_ticket.tickets;
                self.user_info.entry(user_ticket.user).write(user_info);
                i += 1;
            }

            self.total_tickets.write(self.total_tickets.read() - total_tickets_to_remove);
        }

        fn get_total_tickets(self: @ContractState) -> u256 {
            self.total_tickets.read()
        }

        fn draw(ref self: ContractState) -> (ContractAddress, u256) {
            assert!(
                get_caller_address() == self.draw_caller.read(),
                "Only draw caller can perform this action",
            );
            assert!(self.total_tickets.read() > 0, "No tickets to draw");
            assert!(self.user_list.len() > 0, "No users to draw from");

            _draw_winner(ref self)
        }

        fn set_randomness_caller(ref self: ContractState, random_caller: ContractAddress) {
            let caller = get_caller_address();
            let caller_info = self.user_info.entry(caller).read();

            assert!(
                caller_info.is_connected, "Wallet Connection Required for Double or Nothing Spin",
            );
            assert!(!caller_info.has_spinned, "Already Spinned for Double or Nothing");
            assert!(caller_info.tickets > 0, "No tickets");
            assert!(!caller_info.has_spinned, "Already Spinned for Double or Nothing");

            self.randomness_caller.entry(random_caller).write(caller);
            self.randomness_caller_rev.entry(caller).write(random_caller);

            self.emit(RandomnessCallerEvent { user: caller, caller: random_caller });
        }

        fn get_randomness_caller(self: @ContractState, user: ContractAddress) -> ContractAddress {
            self.randomness_caller_rev.entry(user).read()
        }

        fn double_spin(ref self: ContractState) -> bool {
            assert!(self.is_double_active(), "Double or Nothing is not active");
            let random_caller = get_caller_address();
            let user = self.randomness_caller.entry(random_caller).read();
            let mut user_info = self.user_info.entry(user).read();

            assert!(
                user_info.is_connected, "Wallet Connection Required for Double or Nothing Spin",
            );
            assert!(!user_info.has_spinned, "Already Spinned for Double or Nothing");
            assert!(user_info.tickets > 0, "No tickets");

            _double_spin(ref self)
        }
    }

    fn _double_spin(ref self: ContractState) -> bool {
        let random_caller = get_caller_address();
        let user = self.randomness_caller.entry(random_caller).read();
        let mut user_info = self.user_info.entry(user).read();

        // consume random number from VRF provider, note: request random must be called along with
        // double spin
        let vrf_provider = IVrfProviderDispatcher {
            contract_address: self.vrf_contract_address.read(),
        };
        let random_word: felt252 = vrf_provider.consume_random(Source::Nonce(user));
        let random: u256 = random_word.into();

        // head/tail logic: even → double, odd → nothing
        let win = (random.low & 1) == 0;

        let tickets = if win {
            self.total_tickets.write(self.total_tickets.read() + user_info.tickets);
            user_info.tickets * 2
        } else {
            self.total_tickets.write(self.total_tickets.read() - user_info.tickets);
            0
        };
        user_info.has_spinned = true;
        user_info.tickets = tickets;
        self.user_info.entry(user).write(user_info);

        self
            .emit(
                DoubleOrNothingEvent {
                    user: user, tickets: user_info.tickets, won: win, random_word: random_word,
                },
            );
        win
    }

    fn _draw_winner(ref self: ContractState) -> (ContractAddress, u256) {
        let mut eligible = array![];
        let mut sum = 0_u256;
        let len_u = self.user_list.len();
        for i in 0_u64..len_u {
            let addr: ContractAddress = self.user_list.at(i).read();

            if self.winner_set.entry(addr).read() {
                continue;
            }
            let info: UserInfo = self.user_info.entry(addr).read();
            if info.is_connected && info.tickets > 0 {
                eligible.append(addr);
                sum += info.tickets;
            }
        }

        assert!(sum > 0_u256, "No eligible tickets to draw");

        let vrf_provider = IVrfProviderDispatcher {
            contract_address: self.vrf_contract_address.read(),
        };
        let random: u256 = vrf_provider.consume_random(Source::Nonce(self.owner.read())).into();
        let r: u256 = (random % sum).try_into().unwrap();

        let mut cumulative = 0_u256;
        let len_e = eligible.len();
        let mut i_e = 0_u32;
        let mut chosen: (ContractAddress, u256) = (self.owner.read(), 0_u256);
        while i_e != len_e {
            let addr: ContractAddress = *eligible.at(i_e);
            let info: UserInfo = self.user_info.entry(addr).read();
            cumulative += info.tickets;
            if cumulative > r {
                chosen = (addr, info.tickets);
                break;
            }
            i_e += 1;
        }

        let (winner_addr, winner_tickets) = chosen;
        assert!(winner_addr != self.owner.read() && winner_tickets != 0_u256, "No winner found");

        let mut winner_info = self.user_info.entry(winner_addr).read();
        winner_info.tickets = 0_u256;
        self.user_info.entry(winner_addr).write(winner_info);

        self.total_tickets.write(self.total_tickets.read() - winner_tickets);

        self.winner_set.entry(winner_addr).write(true);
        self.past_winners.push(winner_addr);

        self.emit(DrawEvent { winner: winner_addr, tickets: winner_tickets });

        (winner_addr, winner_tickets)
    }

    #[abi(embed_v0)]
    impl CartridgeVRFOracle of ICartridgeVRF<ContractState> {
        fn set_vrf_provider(ref self: ContractState, new_vrf_provider: ContractAddress) {
            _only_owner(@self);
            self.vrf_contract_address.write(new_vrf_provider);
        }

        fn get_vrf_provider(self: @ContractState) -> ContractAddress {
            self.vrf_contract_address.read()
        }
    }
}
