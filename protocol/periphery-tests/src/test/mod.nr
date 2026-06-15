// Router <-> pair integration tests.
//
// Exercises the cross-contract flow `user -> router (private) -> router
// _execute_one_hop_* (public) -> pair.swap_exact_*_public -> router
// .swap_payment_callback`. Running these as TXE tests (rather than
// SDK-E2E only) gives fast feedback on router-pair coupling -- for
// example, the pair's callback-target blocklist is exercised against
// the router's legitimate `callback == recipient == router` shape here,
// so any overly-broad blocklist change is caught in seconds instead of
// only surfacing in the sandbox.
//
// Deploy model: `utils::setup_*` use `txe_oracles::deploy` with secret=0
// which produces salt=1 + default public keys, exactly matching the
// pair's compile-time LP derivation. Factory-mediated flows (anything
// going through `register_pair`) live in SDK E2E because they need
// user-controlled deploy inputs to satisfy address-match reconstruction.
pub(crate) mod utils;
pub(crate) mod router_integration;
pub(crate) mod quote_utilities;
