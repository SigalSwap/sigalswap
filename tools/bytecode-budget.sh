#!/usr/bin/env bash
# Measure each contract's packed public bytecode size in BN254 field
# elements, and fail if any exceeds the per-contract budget. The hard
# protocol cap is MAX_PACKED_PUBLIC_BYTECODE_SIZE_IN_FIELDS = 3000, enforced
# on-chain as a STRICT `bytecodeLength < 3000` (so the largest deployable
# payload is 2999 fields, not 3000). This check trips earlier (2500) so a
# bloat regression surfaces with headroom rather than after the cap is already
# exhausted. A missing artifact is a FAIL, not a skip -- a build that produced
# no artifact has measured nothing and must not report green.
#
# Formula: packed_fields = ceil(decoded_public_dispatch_bytecode_bytes / 31).
# BN254 field elements hold 31 bytes of payload safely (the modulus is
# < 2^254, so 32 bytes won't pack lossless).
#
# Run after `aztec compile` in every protocol/<pkg>/. CI wires this into
# the contract build job so a public_dispatch growth regression fails
# the build instead of being discovered post-merge.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUDGET_FIELDS="${BUDGET_FIELDS:-2500}"
HARD_CAP_FIELDS=3000

check_contract() {
  local label="$1"
  local artifact="$2"

  if [ ! -f "$artifact" ]; then
    echo "MISSING $label (artifact not built: $artifact) -- run 'aztec compile' first"
    return 1
  fi

  local bytes
  bytes=$(jq -r '.functions[] | select(.name == "public_dispatch") | .bytecode' "$artifact" | base64 -d | wc -c | tr -d ' ')

  # A present-but-public_dispatch-less artifact yields 0 bytes (jq empty match).
  # That measures nothing -- treat as FAIL, not a 0-field green pass.
  if [ "$bytes" -eq 0 ]; then
    echo "FAIL $label (no public_dispatch bytecode in artifact: $artifact)"
    return 1
  fi

  # Bash integer ceil: (a + b - 1) / b
  local fields=$(( (bytes + 30) / 31 ))
  local pct_of_cap=$(( fields * 100 / HARD_CAP_FIELDS ))

  printf '%-30s %6d bytes -> %5d fields (%2d%% of cap, budget %d)' \
    "$label" "$bytes" "$fields" "$pct_of_cap" "$BUDGET_FIELDS"

  if [ "$fields" -gt "$BUDGET_FIELDS" ]; then
    echo "  FAIL"
    return 1
  fi
  echo "  ok"
}

status=0
check_contract "SigalSwapPair (core)" \
  "$PROJECT_ROOT/protocol/core/target/sigalswap_core-SigalSwapPair.json" || status=1
check_contract "SigalSwapLPToken" \
  "$PROJECT_ROOT/protocol/lp-token/target/sigalswap_lp_token-SigalSwapLPToken.json" || status=1
check_contract "SigalSwapFactory" \
  "$PROJECT_ROOT/protocol/factory/target/sigalswap_factory-SigalSwapFactory.json" || status=1
check_contract "SigalSwapRouter (periphery)" \
  "$PROJECT_ROOT/protocol/periphery/target/sigalswap_periphery-SigalSwapRouter.json" || status=1

exit "$status"
