use lotto::Drawer::{
    IAkiLottoDrawerDispatcher, IAkiLottoDrawerDispatcherTrait, IPragmaVRFDispatcher,
    IPragmaVRFDispatcherTrait,
};
use snforge_std::{
    ContractClassTrait, DeclareResultTrait, declare, start_cheat_caller_address_global,
    stop_cheat_caller_address_global,
};
use starknet::{ContractAddress, contract_address_const, get_block_timestamp};

fn deploy_drawer() -> (ContractAddress, IAkiLottoDrawerDispatcher, IPragmaVRFDispatcher) {
    let vrf: ContractAddress = contract_address_const::<'VRFContract'>();
    let owner: ContractAddress = contract_address_const::<'owner'>();
    let contract_class = declare("AkiLottoDrawer").unwrap().contract_class();
    let mut constructor: Array<felt252> = array![
        owner.into(),
        vrf.into(),
        0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7.try_into().unwrap(),
    ];
    let (address, _receipt) = contract_class.deploy(@constructor).unwrap();

    let dispatcher = IAkiLottoDrawerDispatcher { contract_address: address };
    let vrf_dispatcher = IPragmaVRFDispatcher { contract_address: vrf };
    (owner, dispatcher, vrf_dispatcher)
}

#[test]
fn test_add_and_get_user_info() {
    let (owner, dispatcher, _) = deploy_drawer();
    start_cheat_caller_address_global(owner);

    dispatcher.add_wallet();
    let info = dispatcher.get_user_info(owner);

    assert_eq!(info.tickets, 0, "Tickets should be 0");
    assert!(info.is_connected, "is_connected should be true");
}

#[test]
fn test_owner_add_and_remove_tickets() {
    let (owner, dispatcher, _) = deploy_drawer();
    start_cheat_caller_address_global(owner);

    let tickets_to_add = 5_u256;

    dispatcher.add_tickets(owner, tickets_to_add);

    let info = dispatcher.get_user_info(owner);
    assert_eq!(info.tickets, tickets_to_add, "Tickets should match added count");
    assert!(!info.is_connected, "User should not be connected by default");

    dispatcher.remove_tickets(owner, 2);
    let info2 = dispatcher.get_user_info(owner);
    assert_eq!(info2.tickets, tickets_to_add - 2, "Tickets should decrease by removed count");

    let total_tickets = dispatcher.get_total_tickets();
    assert_eq!(total_tickets, tickets_to_add - 2, "Total tickets should match after removal");
}

#[test]
fn test_owner_add_and_remove_tickets_for_others() {
    let (owner, dispatcher, _) = deploy_drawer();
    start_cheat_caller_address_global(owner);

    let non_owner: ContractAddress = contract_address_const::<'non_owner'>();
    let tickets_to_add = 5_u256;

    dispatcher.add_tickets(non_owner, tickets_to_add);

    let info = dispatcher.get_user_info(non_owner);
    assert_eq!(info.tickets, tickets_to_add, "Tickets should match added count");
    assert!(!info.is_connected, "User should not be connected by default");

    dispatcher.remove_tickets(non_owner, 2);
    let info2 = dispatcher.get_user_info(non_owner);
    assert_eq!(info2.tickets, tickets_to_add - 2, "Tickets should decrease by removed count");

    stop_cheat_caller_address_global();
    start_cheat_caller_address_global(non_owner);

    dispatcher.add_wallet();
    let info = dispatcher.get_user_info(non_owner);
    assert_eq!(info.tickets, 3, "Tickets should be 0 for owner after adding wallet as non-owner");
    assert!(
        info.is_connected, "is_connected should be true for owner after adding wallet as non-owner",
    );

    let total_tickets = dispatcher.get_total_tickets();
    assert_eq!(total_tickets, tickets_to_add - 2, "Total tickets should match after removal");
}

#[test]
#[should_panic]
fn test_not_owner_add_and_remove_tickets() {
    let (_, dispatcher, _) = deploy_drawer();
    let non_owner: ContractAddress = contract_address_const::<'non_owner'>();
    start_cheat_caller_address_global(non_owner);
    let tickets_to_add = 5_u256;

    dispatcher.add_tickets(non_owner, tickets_to_add);

    let info = dispatcher.get_user_info(non_owner);
    assert_eq!(info.tickets, tickets_to_add, "Tickets should match added count");
    assert!(!info.is_connected, "User should not be connected by default");
}

#[test]
#[should_panic]
fn test_remove_more_tickets_than_owned() {
    let (owner, dispatcher, _) = deploy_drawer();
    start_cheat_caller_address_global(owner);

    let non_owner: ContractAddress = contract_address_const::<'non_owner'>();
    let tickets_to_add = 5_u256;

    dispatcher.add_tickets(non_owner, tickets_to_add);

    let info = dispatcher.get_user_info(non_owner);
    assert_eq!(info.tickets, tickets_to_add, "Tickets should match added count");
    assert!(!info.is_connected, "User should not be connected by default");

    // Attempt to remove more tickets than owned
    dispatcher.remove_tickets(non_owner, 10);
}


#[test]
fn test_set_double_or_nothing_interval() {
    let (owner, dispatcher, _) = deploy_drawer();
    start_cheat_caller_address_global(owner);

    let start = 100_u64;
    let end = 200_u64;
    dispatcher.set_double_or_nothing_interval(start, end);

    let config = dispatcher.get_double_interval();
    assert_eq!(config.start, start, "Start should match set value");
    assert_eq!(config.end, end, "End should match set value");
}

#[test]
#[should_panic]
fn test_set_double_or_nothing_interval_not_owner() {
    let (_, dispatcher, _) = deploy_drawer();

    let non_owner: ContractAddress = contract_address_const::<'non_owner'>();
    start_cheat_caller_address_global(non_owner);
    let start = 100_u64;
    let end = 200_u64;

    // Attempt to set interval as non-owner
    dispatcher.set_double_or_nothing_interval(start, end);
}

#[test]
fn test_is_double_active() {
    let (owner, dispatcher, _) = deploy_drawer();
    start_cheat_caller_address_global(owner);

    let is_active = dispatcher.is_double_active();
    assert!(!is_active, "Double or nothing should not be active within the interval");

    stop_cheat_caller_address_global();

    let is_active = dispatcher.is_double_active();
    assert!(
        !is_active,
        "Double or nothing should not be active outside the interval with others as caller",
    );
}

#[test]
#[should_panic]
fn get_double_interval() {
    let (_, dispatcher, _) = deploy_drawer();

    dispatcher.set_double_or_nothing_interval(100, 200);
    let config = dispatcher.get_double_interval();
    assert_eq!(config.start, 100, "Start should match set value");
    assert_eq!(config.end, 200, "End should match set value");
}

#[test]
#[should_panic] // coz of deploy addr
fn test_vrf_request_and_receive() {
    let (owner, _, vrf) = deploy_drawer();
    start_cheat_caller_address_global(owner);

    // request randomness
    vrf.request_randomness_from_pragma(owner, 1_000_000_u128, 2_u64, 1_u64, array![]);

    // simulate VRF callback after 2 blocks
    let vrf_addr = contract_address_const::<'VRFContract'>();
    start_cheat_caller_address_global(vrf_addr);
    let random_word: Span<felt252> = array![7_u64.into()].span();
    vrf.receive_random_words(owner, 0_u64, random_word, array![]);

    let rand = vrf.get_draw_random_word();
    let res: felt252 = 7_u64.into();
    assert_eq!(rand, res, "Random number should match the one received from VRF");
    stop_cheat_caller_address_global();
}

#[test]
#[should_panic] // coz of deploy addr
fn test_draw_winner_flow() {
    let (owner, dispatcher, vrf) = deploy_drawer();
    start_cheat_caller_address_global(owner);

    let alice: ContractAddress = contract_address_const::<'alice'>();
    dispatcher.add_tickets(owner, 1_u256);
    dispatcher.add_tickets(alice, 3_u256);

    stop_cheat_caller_address_global();
    start_cheat_caller_address_global(contract_address_const::<'VRFContract'>());
    let random_words: Span<felt252> = array![2_u64.into()].span();
    vrf.receive_random_words(owner, 0, random_words, array![]);
    stop_cheat_caller_address_global();

    start_cheat_caller_address_global(owner);
    let (winner, tk) = dispatcher.draw();
    // with random=2, total=4, r=2, cumulative: owner(1)->1<2, alice wins
    assert_eq!(winner, alice);
    assert_eq!(tk, 3_u256, "Alice should win with 3 tickets");
    stop_cheat_caller_address_global();
}

#[test]
#[should_panic] // coz of deploy addr
fn test_double_spin_win_and_lose() {
    let (owner, dispatcher, vrf) = deploy_drawer();
    start_cheat_caller_address_global(owner);

    dispatcher.add_tickets(owner, 2_u256);
    dispatcher.add_wallet();

    dispatcher.set_double_or_nothing_interval(0, 1_000_000_u64);

    stop_cheat_caller_address_global();
    start_cheat_caller_address_global(contract_address_const::<'VRFContract'>());
    let random_words: Span<felt252> = array![4_u64.into()].span();
    vrf.receive_random_words(owner, 0, random_words, array![]);
    stop_cheat_caller_address_global();

    start_cheat_caller_address_global(owner);
    let won = dispatcher.double_spin();
    assert!(won);
    let info = dispatcher.get_user_info(owner);
    assert_eq!(info.tickets, 4_u256);
    stop_cheat_caller_address_global();

    start_cheat_caller_address_global(owner);
    dispatcher.set_double_or_nothing_interval(0, 1_000_000_u64);
    dispatcher.add_tickets(owner, 2_u256);
    dispatcher.add_wallet();
    stop_cheat_caller_address_global();

    start_cheat_caller_address_global(contract_address_const::<'VRFContract'>());
    let random_words: Span<felt252> = array![5_u64.into()].span();
    vrf.receive_random_words(owner, 0, random_words, array![]);
    stop_cheat_caller_address_global();

    start_cheat_caller_address_global(owner);
    let won2 = dispatcher.double_spin();
    assert!(!won2);
    let info2 = dispatcher.get_user_info(owner);
    assert_eq!(info2.tickets, 0_u256);
    stop_cheat_caller_address_global();
}
