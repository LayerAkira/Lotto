# AkiLottoDrawer

A Starknet Cairo contract for a lottery with an owner-driven **draw** and user-driven **double-or-nothing** spins.
Integrates with **Pragma VRF** for secure randomness and **ERC20** for fee handling.

---

## Overview

- **Owner-controlled draw**:
  Picks a winner using VRF randomness and a ticket-weighted mechanism.
- **User double-or-nothing**:
  Each connected user may gamble their tickets once per draw window, doubling or losing them based on the parity of a VRF-provided random word.
- **Concurrency-safe**:
  Separate randomness storage for draws vs. per-user spins to prevent overlap.
- **Wallet integration**:
  Tracks ticket balance (`u256`), connection state, and spin state per user.
- **Fees handled via ERC20**:
  Charges VRF provider fees via a token, using OpenZeppelin’s ERC20 dispatcher.

---

## Dependencies

- `pragma_lib` – Integration with a zero-knowledge VRF oracle (Pragma VRF). Used for requesting/receiving randomness securely.
- `openzeppelin_token` – ERC20 dispatcher interface for fee payments.

---

## Design & Security Considerations

### Randomness Architecture

- **Per-user randomness** (`user_spin_random: Map<ContractAddress, felt252>`):
  Prevents concurrency issues by storing each user’s randomness separately.
- **Single draw randomness** (`draw_random_word: felt252`):
  Held centrally and used only once during the owner’s draw process.

### Access Control

- Methods like `set_owner`, `add_tickets`, `draw`, `double_spin` are restricted by appropriate asserts.
- Each user may only spin once per draw window — tracked by `has_spinned`.
- Draws cannot be repeated once marked by `has_drawed`.

### Ticket Management

- Ticket counts use `u256` to prevent overflow during doubling.
- Total tickets maintained consistently both per-user and globally.

### VRF & Fee Workflow

1. Owner calls `request_randomness_from_pragma` (includes fee approval).
2. On callback, randomness is stored in either `draw_random_word` (owner draw) or `user_spin_random` (user spin).
3. Nonces are cleared after consumption to prevent reuse.

### Workflow

- **User Spin**:
  1. User requests owner for randomness.
  2. User calls `double_spin`.
  4. Then checks parity of the random word:
    - If even, doubles the tickets.
    - If odd, burns the tickets.
  5. Updates user state and emits event.

- **Owner Draw**:
  1. Owner requests randomness.
  2. Upon callback, calculates winner based on ticket weight.
  3. Owner can then call `draw` to finalize the draw.
  4. Emits `Drawn` event with winner details.
