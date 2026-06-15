#!/usr/bin/env bash
# Stage external contract artifacts into each protocol/* package's target/.
#
# Why this exists: `aztec compile` in a protocol/* package only produces
# THAT package's contract artifact. Tests in the package that
# `env.deploy("@external_pkg/Contract")` need the external contract's
# transpiled artifact present in the SAME target/. Without it, TXE
# crashes (`ENOENT: no such file or directory`) or fails to deploy
# ("Contract's public bytecode has not been transpiled").
#
# Run this once after `aztec compile` for any protocol/* package, before
# `nargo test` or any mutation testing campaign. It's idempotent.
#
# Source paths (where transpiled artifacts come from):
#   - Aztec stdlib contracts: ~/.aztec/current/node_modules/@aztec/
#       noir-contracts.js/artifacts/
#     Shipped with the aztec install; already transpiled. Override via
#     STDLIB_ARTIFACTS env var if needed.
#   - Project test contracts: protocol/test-contracts/<pkg>/target/
#     Produced by running `aztec compile` in each test-contracts subdir.
#   - Project app contracts: protocol/<pkg>/target/
#     Produced by `aztec compile` in each protocol/<pkg>/.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STDLIB_ARTIFACTS="${STDLIB_ARTIFACTS:-$HOME/.aztec/current/node_modules/@aztec/noir-contracts.js/artifacts}"

# Mapping from package -> list of external artifacts it needs in its target/.
# Each external artifact is sourced from one canonical location.

stage_artifact() {
  local src="$1"
  local dst_dir="$2"
  if [ ! -f "$src" ]; then
    echo "MISSING: $src" >&2
    return 1
  fi
  mkdir -p "$dst_dir"
  cp -f "$src" "$dst_dir/"
  echo "  staged $(basename "$src") -> $dst_dir/"
}

# NOTE: the TXE integration tests live in the sibling *-tests crates (so the
# test-fixture contracts stay out of the production build graphs). Each *-tests
# crate deploys its contract-under-test + fixtures by their @-artifact, so the
# artifacts are staged into the *-tests crate's target/, not the production
# crate's. (The production crates keep only inline pure unit tests, which deploy
# nothing.) lp-token still hosts its own tests in-crate and needs no externals.

echo "Staging external artifacts for protocol/core-tests/target/..."
stage_artifact "$STDLIB_ARTIFACTS/token_contract-Token.json" "$PROJECT_ROOT/protocol/core-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/core/target/sigalswap_core-SigalSwapPair.json" "$PROJECT_ROOT/protocol/core-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/lp-token/target/sigalswap_lp_token-SigalSwapLPToken.json" "$PROJECT_ROOT/protocol/core-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/test-contracts/flash-borrower/target/flash_borrower-FlashBorrower.json" "$PROJECT_ROOT/protocol/core-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/test-contracts/self-address-test/target/self_address_test-SelfAddressTest.json" "$PROJECT_ROOT/protocol/core-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/test-contracts/hostile-token/target/hostile_token-HostileToken.json" "$PROJECT_ROOT/protocol/core-tests/target"

echo "Staging external artifacts for protocol/factory-tests/target/..."
stage_artifact "$STDLIB_ARTIFACTS/token_contract-Token.json" "$PROJECT_ROOT/protocol/factory-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/factory/target/sigalswap_factory-SigalSwapFactory.json" "$PROJECT_ROOT/protocol/factory-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/core/target/sigalswap_core-SigalSwapPair.json" "$PROJECT_ROOT/protocol/factory-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/lp-token/target/sigalswap_lp_token-SigalSwapLPToken.json" "$PROJECT_ROOT/protocol/factory-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/test-contracts/mock-pair-v2/target/mock_pair_v2-MockPairV2.json" "$PROJECT_ROOT/protocol/factory-tests/target"

echo "Staging external artifacts for protocol/periphery-tests/target/..."
stage_artifact "$STDLIB_ARTIFACTS/token_contract-Token.json" "$PROJECT_ROOT/protocol/periphery-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/periphery/target/sigalswap_periphery-SigalSwapRouter.json" "$PROJECT_ROOT/protocol/periphery-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/core/target/sigalswap_core-SigalSwapPair.json" "$PROJECT_ROOT/protocol/periphery-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/lp-token/target/sigalswap_lp_token-SigalSwapLPToken.json" "$PROJECT_ROOT/protocol/periphery-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/factory/target/sigalswap_factory-SigalSwapFactory.json" "$PROJECT_ROOT/protocol/periphery-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/test-contracts/mock-factory/target/mock_factory-MockFactory.json" "$PROJECT_ROOT/protocol/periphery-tests/target"
stage_artifact "$PROJECT_ROOT/protocol/test-contracts/abusive-pair/target/abusive_pair-AbusivePair.json" "$PROJECT_ROOT/protocol/periphery-tests/target"

echo "Done. Run 'aztec test' in the *-tests crates (or mutation campaigns) now."
