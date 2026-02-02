#[starknet::contract]
mod AkiLottoDrawer {
    use cartridge_vrf::{IVrfProviderDispatcher, IVrfProviderDispatcherTrait, Source};
    use core::traits::{Into, TryInto};
    use lotto::events::{
        DoubleOrHalveEvent, DrawCallerEvent, DrawEvent, PoolResetEvent,
        SpinCallerEvent, SpinSignup, UpgradeEvent, UserConnectEvent,
    };
    use lotto::interface::{IAkiLottoDrawer, ICartridgeVRF, IUpgradeable};
    use lotto::types::{
        DoubleOrNothingConfig, DrawCallerInfo, PoolStats, UserInfo, UserTickets,
    };
    use starknet::storage::{
        Map, MutableVecTrait, StoragePathEntry, StoragePointerReadAccess,
        StoragePointerWriteAccess, Vec, VecTrait,
    };
    use starknet::syscalls::replace_class_syscall;
    use starknet::{
        ClassHash, ContractAddress, get_block_timestamp, get_caller_address,
        get_contract_address,
    };



    #[storage]
    struct Storage {
        owner: ContractAddress,
        total_tickets: u256,
        total_draws: u64,

        users: Map<ContractAddress, UserInfo>,
        user_list: Vec<ContractAddress>,
        user_exists: Map<ContractAddress, bool>,

        winners: Vec<ContractAddress>,
        winner_set: Map<ContractAddress, bool>,

        draw_callers: Map<ContractAddress, DrawCallerInfo>,

        double_config: DoubleOrNothingConfig,
        spin_callers: Map<ContractAddress, ContractAddress>,      // vrf_caller -> user
        spin_callers_rev: Map<ContractAddress, ContractAddress>,  // user -> vrf_caller
        spin_signups: Map<ContractAddress, bool>,

        vrf_provider: ContractAddress,
        impl_hash: ClassHash,
        version: u32,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        UpgradeEvent: UpgradeEvent,
        UserConnectEvent: UserConnectEvent,
        DoubleOrHalveEvent: DoubleOrHalveEvent,
        DrawEvent: DrawEvent,
        DrawCallerEvent: DrawCallerEvent,
        SpinCallerEvent: SpinCallerEvent,
        SpinSignup: SpinSignup,
        PoolResetEvent: PoolResetEvent,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        vrf_provider: ContractAddress,
        impl_hash: ClassHash,
    ) {
        self.owner.write(owner);
        self.vrf_provider.write(vrf_provider);
        self.impl_hash.write(impl_hash);
        self.version.write(1);

        // Owner is authorized to draw by default
        self.draw_callers.entry(owner).write(DrawCallerInfo {
            is_authorized: true,
            draw_count: 0,
            last_draw_timestamp: 0,
        });
    }

    /// Reverts if caller is not the owner
    fn assert_owner(self: @ContractState) {
        assert!(
            get_caller_address() == self.owner.read(),
            "Unauthorized: owner only"
        );
    }

    /// Reverts if caller is not an authorized draw caller
    fn assert_draw_caller(self: @ContractState) {
        let caller = get_caller_address();
        let info = self.draw_callers.entry(caller).read();
        assert!(info.is_authorized, "Unauthorized: draw caller only");
    }


    #[external(v0)]
    fn set_owner(ref self: ContractState, new_owner: ContractAddress) {
        assert_owner(@self);
        self.owner.write(new_owner);
    }

    #[external(v0)]
    fn get_owner(self: @ContractState) -> ContractAddress {
        self.owner.read()
    }

    #[external(v0)]
    fn set_spin_caller(ref self: ContractState, vrf_caller: ContractAddress) {
        let user = get_caller_address();
        let info = self.users.entry(user).read();

        assert!(info.is_connected, "Must connect wallet first");
        assert!(!info.has_spinned, "Already spinned");
        assert!(info.tickets > 0, "No tickets");

        self.spin_callers.entry(vrf_caller).write(user);
        self.spin_callers_rev.entry(user).write(vrf_caller);

        self.emit(SpinCallerEvent { user, caller: vrf_caller });
    }

    #[external(v0)]
    fn get_spin_caller(self: @ContractState, user: ContractAddress) -> ContractAddress {
        self.spin_callers_rev.entry(user).read()
    }

    #[external(v0)]
    fn sign_for_spin(ref self: ContractState, sign: bool) {
        let user = get_caller_address();

        if sign {
            let info = self.users.entry(user).read();
            assert!(info.is_connected, "Must connect wallet first");
            assert!(!info.has_spinned, "Already spinned");
            assert!(info.tickets > 0, "No tickets");
        }

        self.spin_signups.entry(user).write(sign);
        self.emit(SpinSignup { user, sign });
    }

    #[external(v0)]
    fn is_signed_up_for_spin(self: @ContractState, user: ContractAddress) -> bool {
        self.spin_signups.entry(user).read()
    }

    #[external(v0)]
    fn reset_user_spin(ref self: ContractState, user: ContractAddress) {
        assert_owner(@self);
        let mut info = self.users.entry(user).read();
        info.has_spinned = false;
        self.users.entry(user).write(info);
    }

    /// Ensures user is tracked in user_list (O(1) check)
    fn ensure_user_tracked(ref self: ContractState, user: ContractAddress) {
        if !self.user_exists.entry(user).read() {
            self.user_list.push(user);
            self.user_exists.entry(user).write(true);
        }
    }

    /// Consume VRF randomness
    fn consume_vrf(self: @ContractState) -> u256 {
        let vrf = IVrfProviderDispatcher { contract_address: self.vrf_provider.read() };
        let random_felt: felt252 = vrf.consume_random(Source::Nonce(get_contract_address()));
        random_felt.into()
    }

    #[abi(embed_v0)]
    impl UpgradeableImpl of IUpgradeable<ContractState> {
        fn upgrade(ref self: ContractState, new_class_hash: ClassHash) {
            assert_owner(@self);

            let old_hash = self.impl_hash.read();
            replace_class_syscall(new_class_hash).unwrap();

            self.impl_hash.write(new_class_hash);
            let new_version = self.version.read() + 1;
            self.version.write(new_version);

            self.emit(UpgradeEvent {
                old_class_hash: old_hash,
                new_class_hash,
                version: new_version,
            });
        }

        fn get_implementation(self: @ContractState) -> ClassHash {
            self.impl_hash.read()
        }

        fn get_version(self: @ContractState) -> u32 {
            self.version.read()
        }
    }

    #[abi(embed_v0)]
    impl AkiLottoDrawerImpl of IAkiLottoDrawer<ContractState> {
        fn add_wallet(ref self: ContractState) -> bool {
            let user = get_caller_address();
            ensure_user_tracked(ref self, user);

            let mut info = self.users.entry(user).read();
            info.is_connected = true;
            self.users.entry(user).write(info);

            self.emit(UserConnectEvent {
                user,
                tickets: info.tickets,
                has_spinned: info.has_spinned,
            });

            true
        }

        fn get_user_info(self: @ContractState, user: ContractAddress) -> UserInfo {
            self.users.entry(user).read()
        }

        fn add_tickets(ref self: ContractState, user: ContractAddress, tickets: u256) {
            assert_owner(@self);
            assert!(tickets > 0, "Tickets must be > 0");

            ensure_user_tracked(ref self, user);

            let mut info = self.users.entry(user).read();
            info.tickets += tickets;
            self.users.entry(user).write(info);

            self.total_tickets.write(self.total_tickets.read() + tickets);
        }

        fn remove_tickets(ref self: ContractState, user: ContractAddress, tickets: u256) {
            assert_owner(@self);
            assert!(tickets > 0, "Tickets must be > 0");

            let mut info = self.users.entry(user).read();
            assert!(info.tickets >= tickets, "Insufficient tickets");

            info.tickets -= tickets;
            self.users.entry(user).write(info);

            self.total_tickets.write(self.total_tickets.read() - tickets);
        }

        fn add_tickets_batch(ref self: ContractState, user_tickets: Array<UserTickets>) {
            assert_owner(@self);
            assert!(user_tickets.len() > 0, "Empty batch");

            let mut total_added: u256 = 0;
            let len = user_tickets.len();
            let mut i: u32 = 0;

            // First pass: validate and sum
            while i < len {
                let ut = *user_tickets.at(i);
                assert!(ut.tickets > 0, "Tickets must be > 0");
                total_added += ut.tickets;
                i += 1;
            };

            // Second pass: apply changes
            i = 0;
            while i < len {
                let ut = *user_tickets.at(i);
                ensure_user_tracked(ref self, ut.user);

                let mut info = self.users.entry(ut.user).read();
                info.tickets += ut.tickets;
                self.users.entry(ut.user).write(info);
                i += 1;
            };

            self.total_tickets.write(self.total_tickets.read() + total_added);
        }

        fn remove_tickets_batch(ref self: ContractState, user_tickets: Array<UserTickets>) {
            assert_owner(@self);
            assert!(user_tickets.len() > 0, "Empty batch");

            let mut total_removed: u256 = 0;
            let len = user_tickets.len();
            let mut i: u32 = 0;

            // First pass: validate
            while i < len {
                let ut = *user_tickets.at(i);
                assert!(ut.tickets > 0, "Tickets must be > 0");

                let info = self.users.entry(ut.user).read();
                assert!(info.tickets >= ut.tickets, "Insufficient tickets");

                total_removed += ut.tickets;
                i += 1;
            };

            // Second pass: apply
            i = 0;
            while i < len {
                let ut = *user_tickets.at(i);
                let mut info = self.users.entry(ut.user).read();
                info.tickets -= ut.tickets;
                self.users.entry(ut.user).write(info);
                i += 1;
            };

            self.total_tickets.write(self.total_tickets.read() - total_removed);
        }

        fn draw(ref self: ContractState) -> (ContractAddress, u256) {
            assert_draw_caller(@self);
            assert!(self.total_tickets.read() > 0, "No tickets in pool");
            assert!(self.user_list.len() > 0, "No users");

            let caller = get_caller_address();

            // Update caller stats
            let mut caller_info = self.draw_callers.entry(caller).read();
            caller_info.draw_count += 1;
            caller_info.last_draw_timestamp = get_block_timestamp();
            self.draw_callers.entry(caller).write(caller_info);

            // Increment total draws
            self.total_draws.write(self.total_draws.read() + 1);

            // Execute weighted random selection
            execute_draw(ref self)
        }

        fn has_won(self: @ContractState, user: ContractAddress) -> bool {
            self.winner_set.entry(user).read()
        }

        fn set_double_or_nothing_interval(ref self: ContractState, start: u64, end: u64) {
            assert_owner(@self);
            assert!(start < end, "Invalid interval: start >= end");
            self.double_config.write(DoubleOrNothingConfig { start, end });
        }

        fn is_double_active(self: @ContractState) -> bool {
            let now = get_block_timestamp();
            let cfg = self.double_config.read();
            cfg.start != 0 && now >= cfg.start && now <= cfg.end
        }

        fn get_double_interval(self: @ContractState) -> DoubleOrNothingConfig {
            self.double_config.read()
        }

        fn double_spin(ref self: ContractState) -> bool {
            assert!(self.is_double_active(), "Double-or-nothing not active");

            let vrf_caller = get_caller_address();
            let user = self.spin_callers.entry(vrf_caller).read();

            assert!(self.spin_signups.entry(user).read(), "Not signed up");

            let mut info = self.users.entry(user).read();
            assert!(info.is_connected, "Wallet not connected");
            assert!(!info.has_spinned, "Already spinned");
            assert!(info.tickets > 0, "No tickets");

            execute_spin(ref self, user)
        }

        fn reset_pool(ref self: ContractState) {
            assert_owner(@self);

            let total_before = self.total_tickets.read();
            let user_count = self.user_list.len();
            let mut affected: u64 = 0;

            // Reset all user tickets while preserving connection status
            let mut i: u64 = 0;
            while i < user_count {
                let user = self.user_list.at(i).read();
                let mut info = self.users.entry(user).read();

                if info.tickets > 0 {
                    info.tickets = 0;
                    info.has_spinned = false;  // Reset spin status for new round
                    self.users.entry(user).write(info);
                    affected += 1;
                }
                i += 1;
            };

            self.total_tickets.write(0);

            self.emit(PoolResetEvent {
                reset_by: get_caller_address(),
                users_affected: affected,
                tickets_cleared: total_before,
                timestamp: get_block_timestamp(),
            });
        }

        fn get_pool_stats(self: @ContractState) -> PoolStats {
            let user_count = self.user_list.len();
            let mut connected: u64 = 0;

            let mut i: u64 = 0;
            while i < user_count {
                let user = self.user_list.at(i).read();
                let info = self.users.entry(user).read();
                if info.is_connected {
                    connected += 1;
                }
                i += 1;
            };

            PoolStats {
                total_tickets: self.total_tickets.read(),
                total_users: user_count,
                connected_users: connected,
                total_draws: self.total_draws.read(),
            }
        }

        fn set_draw_caller(ref self: ContractState, caller: ContractAddress, authorized: bool) {
            assert_owner(@self);

            let mut info = self.draw_callers.entry(caller).read();
            info.is_authorized = authorized;
            self.draw_callers.entry(caller).write(info);

            self.emit(DrawCallerEvent { caller, authorized });
        }

        fn is_draw_caller(self: @ContractState, caller: ContractAddress) -> bool {
            self.draw_callers.entry(caller).read().is_authorized
        }

        fn get_draw_caller_info(self: @ContractState, caller: ContractAddress) -> DrawCallerInfo {
            self.draw_callers.entry(caller).read()
        }
    }

    #[abi(embed_v0)]
    impl CartridgeVRFImpl of ICartridgeVRF<ContractState> {
        fn set_vrf_provider(ref self: ContractState, provider: ContractAddress) {
            assert_owner(@self);
            self.vrf_provider.write(provider);
        }

        fn get_vrf_provider(self: @ContractState) -> ContractAddress {
            self.vrf_provider.read()
        }
    }

    /// Execute double-or-half spin for a user
    fn execute_spin(ref self: ContractState, user: ContractAddress) -> bool {
        let mut info = self.users.entry(user).read();

        // Get randomness
        let random = consume_vrf(@self);
        let random_felt: felt252 = (random % 0x100000000_u256).try_into().unwrap();

        // Even = win (double), Odd = lose (halve)
        let won = (random.low & 1) == 0;

        let old_tickets = info.tickets;
        if won {
            info.tickets *= 2;
            self.total_tickets.write(self.total_tickets.read() + old_tickets);
        } else {
            info.tickets /= 2;
            self.total_tickets.write(self.total_tickets.read() - old_tickets / 2);
        }

        info.has_spinned = true;
        self.users.entry(user).write(info);

        self.emit(DoubleOrHalveEvent {
            user,
            tickets: info.tickets,
            won,
            random_word: random_felt,
        });

        won
    }

    /// Execute weighted random draw to select a winner
    fn execute_draw(ref self: ContractState) -> (ContractAddress, u256) {
        // Build eligible list (connected users with tickets)
        let mut eligible: Array<ContractAddress> = array![];
        let mut eligible_sum: u256 = 0;

        let user_count = self.user_list.len();
        let mut i: u64 = 0;

        while i < user_count {
            let addr = self.user_list.at(i).read();
            let info = self.users.entry(addr).read();

            if info.is_connected && info.tickets > 0 {
                eligible.append(addr);
                eligible_sum += info.tickets;
            }
            i += 1;
        };

        assert!(eligible_sum > 0, "No eligible tickets");

        // Get random value and compute target
        let random = consume_vrf(@self);
        let target: u256 = random % eligible_sum;

        // Find winner using cumulative sum
        let mut cumulative: u256 = 0;
        let eligible_len = eligible.len();
        let mut j: u32 = 0;
        let mut winner = (self.owner.read(), 0_u256);  // Fallback

        while j < eligible_len {
            let addr = *eligible.at(j);
            let info = self.users.entry(addr).read();
            cumulative += info.tickets;

            if cumulative > target {
                winner = (addr, info.tickets);
                break;
            }
            j += 1;
        };

        let (winner_addr, winner_tickets) = winner;
        assert!(winner_tickets > 0, "Draw failed: no winner selected");

        // Record winner
        self.winner_set.entry(winner_addr).write(true);
        self.winners.push(winner_addr);

        self.emit(DrawEvent {
            winner: winner_addr,
            tickets: winner_tickets
        });

        (winner_addr, winner_tickets)
    }
}
