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
pub trait IPragmaVRF<TContractState> {
    fn get_spin_random_word(self: @TContractState, user: ContractAddress) -> felt252;
    fn get_draw_random_word(self: @TContractState) -> felt252;
    fn request_randomness_from_pragma(
        ref self: TContractState,
        callback_address: ContractAddress,
        callback_fee_limit: u128,
        publish_delay: u64,
        num_words: u64,
        calldata: Array<felt252>,
    );
    fn receive_random_words(
        ref self: TContractState,
        requester_address: ContractAddress,
        request_id: u64,
        random_words: Span<felt252>,
        calldata: Array<felt252>,
    );
    fn withdraw_extra_fee_fund(ref self: TContractState, receiver: ContractAddress);
    fn set_vrf_provider(ref self: TContractState, new_vrf_provider: ContractAddress);
    fn clear_draw_random_number(ref self: TContractState);
    fn clear_spin_random_number(ref self: TContractState, user: ContractAddress);
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

#[starknet::contract]
mod AkiLottoDrawer {
    use core::traits::{Into, TryInto};
    use openzeppelin_token::erc20::interface::{ERC20ABIDispatcher, ERC20ABIDispatcherTrait};
    use pragma_lib::abi::{IRandomnessDispatcher, IRandomnessDispatcherTrait};
    use starknet::storage::{
        Map, MutableVecTrait, StoragePathEntry, StoragePointerReadAccess, StoragePointerWriteAccess,
        Vec,
    };
    use starknet::{
        ContractAddress, get_block_number, get_block_timestamp, get_caller_address,
        get_contract_address,
    };
    use super::{DoubleOrNothingConfig, IAkiLottoDrawer, UserInfo};

    #[storage]
    struct Storage {
        user_info: Map<ContractAddress, UserInfo>,
        user_list: Vec<ContractAddress>, // to be used for iterating over users
        user_spin_random: Map<
            ContractAddress, felt252,
        >, // to store user random numbers for double or nothing
        total_tickets: u256,
        owner: ContractAddress,
        has_drawed: bool, // indicates if the draw has been done
        double_or_nothing_cfg: DoubleOrNothingConfig,
        min_block_number_storage: u64,
        draw_random_word: felt252,
        pragma_vrf_contract_address: ContractAddress,
        eth_address: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        DoubleOrNothingEvent: DoubleOrNothingEvent,
        DrawEvent: DrawEvent,
        UserConnectEvent: UserConnectEvent,
        ReceiveRandomEvent: ReceiveRandomEvent,
    }

    #[derive(Drop, starknet::Event)]
    pub struct ReceiveRandomEvent {
        pub random_word: felt252,
        pub calldata: Array<felt252>,
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
        pragma_vrf_contract_address: ContractAddress,
        eth_address: ContractAddress,
    ) {
        self.owner.write(owner);
        self.pragma_vrf_contract_address.write(pragma_vrf_contract_address);
        self.eth_address.write(eth_address);
    }

    #[external(v0)]
    fn set_eth_address(ref self: ContractState, eth_address: ContractAddress) {
        assert!(get_caller_address() == self.owner.read(), "Only owner can set the ETH address");
        self.eth_address.write(eth_address);
    }

    #[external(v0)]
    fn set_owner(ref self: ContractState, owner: ContractAddress) {
        assert!(get_caller_address() == self.owner.read(), "Only owner can set the owner");
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
            assert!(get_caller_address() == self.owner.read(), "Only owner can set the interval");
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
            assert!(get_caller_address() == self.owner.read(), "Only owner can add tickets");
            assert!(tickets > 0, "Tickets to add must be greater than zero");
            _check_and_push_user(ref self, user);

            let mut user_info = self.user_info.entry(user).read();

            user_info.tickets += tickets;
            self.user_info.entry(user).write(user_info);
            self.total_tickets.write(self.total_tickets.read() + tickets);
        }

        fn remove_tickets(ref self: ContractState, user: ContractAddress, tickets: u256) {
            assert!(get_caller_address() == self.owner.read(), "Only owner can remove tickets");
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
            assert!(get_caller_address() == self.owner.read(), "Only owner can draw");
            assert!(self.total_tickets.read() > 0, "No tickets to draw");
            assert!(self.draw_random_word.read() != 0, "No Random Number Yet");
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
            assert!(
                self.user_spin_random.entry(caller).read() != 0,
                "No Random Number Yet for double spin",
            );
            assert!(!self.has_drawed.read(), "Draw has already been done");

            _double_spin(ref self)
        }
    }

    fn _double_spin(ref self: ContractState) -> bool {
        let caller = get_caller_address();
        let mut caller_info = self.user_info.entry(caller).read();
        let random: u256 = self.user_spin_random.entry(caller).read().into();

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
        self.user_spin_random.entry(caller).write(0);
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

        let random: u256 = self.draw_random_word.read().into();
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
        self.draw_random_word.write(0);
        assert!(winner_addr != self.owner.read() && tickets != 0_u256, "No winner found");
        self.has_drawed.write(true);

        res
    }

    #[abi(embed_v0)]
    impl PragmaVRFOracle of super::IPragmaVRF<ContractState> {
        fn get_draw_random_word(self: @ContractState) -> felt252 {
            let last_random = self.draw_random_word.read();
            last_random
        }

        fn get_spin_random_word(self: @ContractState, user: ContractAddress) -> felt252 {
            self.user_spin_random.entry(user).read()
        }

        fn request_randomness_from_pragma(
            ref self: ContractState,
            callback_address: ContractAddress,
            callback_fee_limit: u128,
            publish_delay: u64,
            num_words: u64,
            calldata: Array<felt252>,
        ) {
            assert!(get_caller_address() == self.owner.read(), "Only owner can request randomness");
            assert!(!self.has_drawed.read(), "Draw has already been done");
            assert!(callback_fee_limit > 0, "Callback fee limit must be greater than zero");
            assert!(publish_delay > 0, "Publish delay must be greater than zero");
            assert!(num_words > 0, "Number of words must be greater than zero");

            if let Some(x) = calldata.get(0) {
                let user: felt252 = *x.unbox();
                assert!(
                    !self.user_info.entry(user.try_into().unwrap()).read().has_spinned,
                    "User has already spun for double or nothing",
                );
            }

            let randomness_contract_address = self.pragma_vrf_contract_address.read();
            let randomness_dispatcher = IRandomnessDispatcher {
                contract_address: randomness_contract_address,
            };

            let eth_dispatcher = ERC20ABIDispatcher { contract_address: self.eth_address.read() };
            eth_dispatcher
                .approve(
                    randomness_contract_address,
                    (callback_fee_limit + callback_fee_limit / 5).into(),
                );

            let seed: u64 = get_block_timestamp();
            randomness_dispatcher
                .request_random(
                    seed, callback_address, callback_fee_limit, publish_delay, num_words, calldata,
                );

            let current_block_number = get_block_number();
            self.min_block_number_storage.write(current_block_number + publish_delay);
        }

        fn receive_random_words(
            ref self: ContractState,
            requester_address: ContractAddress,
            request_id: u64,
            random_words: Span<felt252>,
            calldata: Array<felt252>,
        ) {
            let caller_address = get_caller_address();
            assert!(
                caller_address == self.pragma_vrf_contract_address.read(),
                "caller not randomness contract",
            );
            assert!(requester_address == get_contract_address(), "requester address mismatch");

            let current_block_number = get_block_number();
            let min_block_number = self.min_block_number_storage.read();
            assert!(min_block_number <= current_block_number, "block number issue");

            let random_word = *random_words.at(0);
            match calldata.get(0) {
                Some(x) => {
                    let user: felt252 = *x.unbox();
                    self.user_spin_random.entry(user.try_into().unwrap()).write(random_word);
                },
                None => { self.draw_random_word.write(random_word); },
            }

            self.emit(ReceiveRandomEvent { random_word: random_word, calldata: calldata });
        }

        fn withdraw_extra_fee_fund(ref self: ContractState, receiver: ContractAddress) {
            assert!(
                get_caller_address() == self.owner.read(), "Only owner can withdraw extra fee fund",
            );

            let eth_dispatcher = ERC20ABIDispatcher { contract_address: self.eth_address.read() };
            let balance = eth_dispatcher.balance_of(get_contract_address());
            eth_dispatcher.transfer(receiver, balance);
        }

        fn set_vrf_provider(ref self: ContractState, new_vrf_provider: ContractAddress) {
            assert!(get_caller_address() == self.owner.read(), "Only owner can set VRF provider");
            self.pragma_vrf_contract_address.write(new_vrf_provider);
        }

        fn clear_draw_random_number(ref self: ContractState) {
            assert!(
                get_caller_address() == self.owner.read(), "Only owner can clear random number",
            );
            self.draw_random_word.write(0);
        }

        fn clear_spin_random_number(ref self: ContractState, user: ContractAddress) {
            assert!(
                get_caller_address() == self.owner.read(), "Only owner can clear random number",
            );
            self.user_spin_random.entry(user).write(0);
        }
    }
}
