#!/usr/bin/env python3
"""TWAP manipulation cost model for SigalSwap pairs.

Computes attacker cost (in pool-TVL units) to skew a constant-product
cumulative-price TWAP by a target percentage over a given observation
window. Closed-form derivations and exact one-shot LVR are both supported.

Run with no args to regenerate every table referenced by docs/twap-security.md.
Pass --print-md to also print the markdown tables to stdout.

Model summary
-------------
A constant-product TWAP integrates spot price over time. To shift the
TWAP-over-W by fraction S, an attacker displaces spot by some delta for some
sub-interval T, fighting arbitrageurs at every block. Three regimes:

  1. Continuous sustained attack (perfect arbs each block):
       cost / V = (W / T_b) * S * (f/4 + S/8)        [TVL units]
     Derived by spreading displacement evenly across N = W/T_b blocks,
     paying LP fee + LVR per round-trip, taking the asymptotic limit.

  2. Donation attack (no arbs, displacement persists):
       cost / V = S / 2                              [TVL units]
     Attacker transfers tokens to pair, calls sync, displacement stays
     until someone trades. Lower bound on attacker cost; relevant when
     arb infrastructure is sparse (early Aztec).

  3. One-shot maximum displacement (single-block spike):
       given attacker capital C, compute achievable delta exactly via
       the constant-product swap formula, then TWAP_skew = delta * T_b / W.

The "true" cost lies between (2) and (1) depending on how aggressive the
arb landscape is at attack time.

Units convention
----------------
- TVL V is in numeraire (USD); reserves x, y in token units.
- For a balanced pool at external price, V = 2 * y * price_token1_in_USD.
- Costs are reported as fraction-of-TVL; multiply by V for dollar values.

This script has zero non-stdlib dependencies; runs on stock CPython 3.8+.
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from dataclasses import dataclass
from pathlib import Path

# Block-time sensitivity points (seconds). Cost scales linearly with W / T_b, so
# SLOWER blocks (fewer blocks per observation window) make manipulation CHEAPER.
# Aztec's Ignition mainnet is LIVE at ~6s blocks (see docs/mev-considerations.md),
# so 6s is the current network. The 72s point is a conservative slow- / degraded-
# network sensitivity bound, NOT the current network; ~4s is a future roadmap
# target. Source: forum.aztec.network/t/8210 and roadmap.
SLOW_BLOCK_T_B = 72.0       # conservative slow-block sensitivity (NOT current)
LIVE_T_B = 6.0              # Aztec Ignition mainnet -- current / live
FUTURE_TARGET_T_B = 4.0     # roadmap target (tighter blocks)

# Fee tiers exposed by the factory. Whitelisted, expressed in basis points (1bp = 0.01%).
FEE_TIER_5_BPS = 5
FEE_TIER_25_BPS = 25
FEE_TIER_100_BPS = 100


@dataclass(frozen=True)
class Params:
    """Inputs that fully determine a sustained-attack cost."""

    skew: float           # TWAP displacement S, fraction (0.01 = 1%)
    window_s: float       # observation window W, seconds
    block_time_s: float   # T_b, seconds
    fee_bps: int          # LP fee in basis points; protocol fee is additive on top

    @property
    def f(self) -> float:
        """LP fee fraction (e.g. 0.0025 for 25bps)."""
        return self.fee_bps / 10_000.0

    @property
    def blocks_in_window(self) -> float:
        return self.window_s / self.block_time_s


def sustained_cost_fraction(p: Params) -> float:
    """Sustained-attack cost as fraction of pool TVL.

    Closed form: V * (W/T_b) * S * (f/4 + S/8). Linearization is exact in the
    small-S limit and conservative (overestimates attacker cost) at large S
    because the LVR term is the linearized version of (sqrt(1+S)-1)^2 / sqrt(1+S).
    See `sustained_cost_fraction_exact` for the exact per-block LVR.
    """
    return p.blocks_in_window * p.skew * (p.f / 4.0 + p.skew / 8.0)


def one_shot_lvr_fraction(delta: float, f: float) -> float:
    """Exact one-round-trip LVR + LP-fee as fraction of TVL.

    Returns cost / V where V = 2y. Attacker pushes spot by factor (1+delta),
    pays delta-dependent LP fee on the push leg, and loses LVR to whoever
    arbs back at external price.

    Derivation: trade size u = Delta_y / y solves
        (1 + delta) = (1 + u) * (1 + u(1-f))
    quadratic in u; pick the positive root. Then
        loss_token1 = Delta_y * [Delta_y(1-f) + f*y] / (y + Delta_y(1-f))
        cost / V   = loss_token1 / (2y)
    """
    if delta <= 0.0:
        return 0.0
    # (1-f) u^2 + (2-f) u + (1 - (1+delta)) = 0
    a = 1.0 - f
    b = 2.0 - f
    c = -delta
    disc = b * b - 4.0 * a * c
    u = (-b + math.sqrt(disc)) / (2.0 * a)
    # cost in token1 units:
    loss = u * (u * (1.0 - f) + f) / (1.0 + u * (1.0 - f))
    # convert to TVL units (V = 2y, loss-in-tvl = loss-in-token1 * y / V = loss/2):
    return loss / 2.0


def sustained_cost_fraction_exact(p: Params) -> float:
    """Sum of one_shot_lvr_fraction over N blocks at displacement delta = S.

    The 'continuous-attack limit' result assumes spreading skew across N = W/T_b
    blocks at delta = S throughout. Exact per-block cost uses the closed-form
    LVR rather than the linearization.
    """
    return p.blocks_in_window * one_shot_lvr_fraction(p.skew, p.f)


def held_swap_no_arb_cost_fraction(skew: float, f: float) -> float:
    """Swap-and-hold no-arb cost estimate (one round-trip LVR+fee).

    WARNING -- UNDER EXTERNAL REVIEW; OVER-STATES THE TRUE FLOOR. This returns the
    one-shot LVR, which is the WITH-arb round-trip cost (the attacker loses the LVR
    to whoever arbs back). In a genuine no-arb regime the attacker self-unwinds into
    the still-displaced pool and recaptures most of that LVR, so the real no-arb
    floor is materially lower (closer to the round-trip fees). Do NOT use this for
    production oracle sizing; the corrected floor is pending external TWAP peer
    review, and docs/twap-security.md omits the numbers this produces for that reason.

    Mechanically: in the no-arb regime a single SWAP to displacement S persists
    untouched for the whole window (no arbitrageur reverses it), so the TWAP is
    skewed by S for the full window -- but the cost the attacker actually bears is
    below the value returned here.
    """
    return one_shot_lvr_fraction(skew, f)


def donation_cost_fraction(skew: float) -> float:
    """Donation attack: attacker transfers tokens to the pair, calls sync, and
    the displacement persists. Cost = donation value = skew * V / 2.

    NOTE: this is NOT the floor on attacker cost. A rational no-arb attacker uses
    swap-and-hold (`held_swap_no_arb_cost_fraction`), which is far cheaper. The
    donation figure is retained only as an UPPER reference for the no-arb regime
    (the cost an attacker pays if they donate outright instead of swapping)."""
    return skew / 2.0


def trade_size_for_delta(delta: float, f: float) -> float:
    """Fraction of token1 reserve the attacker must commit to push spot
    by factor (1+delta). Useful for the 'attacker capital needed' column."""
    if delta <= 0.0:
        return 0.0
    a = 1.0 - f
    b = 2.0 - f
    c = -delta
    disc = b * b - 4.0 * a * c
    return (-b + math.sqrt(disc)) / (2.0 * a)


# --------------------------------------------------------------------------
# Table generation
# --------------------------------------------------------------------------


PHASE_LABELS = [
    ("Slow-block 72s (conservative)", SLOW_BLOCK_T_B),
    ("Live ~6s (current)", LIVE_T_B),
    ("Future ~4s (target)", FUTURE_TARGET_T_B),
]

SKEW_LADDER = [0.001, 0.005, 0.01, 0.02, 0.05, 0.10, 0.25]
WINDOW_LADDER_S = [5 * 60, 15 * 60, 30 * 60, 60 * 60, 4 * 3600]
FEE_LADDER = [FEE_TIER_5_BPS, FEE_TIER_25_BPS, FEE_TIER_100_BPS]
TVL_EXAMPLES = [10_000, 100_000, 1_000_000]


def fmt_pct(x: float) -> str:
    """Format a fraction as percent with sensible precision; values >1 keep their tail."""
    if x >= 1.0:
        return f"{x * 100:.0f}%"
    if x >= 0.01:
        return f"{x * 100:.2f}%"
    return f"{x * 100:.4f}%"


def fmt_usd(x: float) -> str:
    if x >= 1_000_000_000:
        return f"${x / 1e9:.1f}B"
    if x >= 1_000_000:
        return f"${x / 1e6:.2f}M"
    if x >= 1_000:
        return f"${x / 1e3:.1f}k"
    if x >= 100:
        return f"${x:.0f}"
    return f"${x:.2f}"


def build_skew_table(window_s: float, fee_bps: int) -> list[list[str]]:
    """Cost as % of TVL across (skew, phase) for fixed window + fee."""
    head = ["TWAP skew"] + [name for name, _ in PHASE_LABELS]
    rows = [head]
    for s in SKEW_LADDER:
        row = [fmt_pct(s)]
        for _, t_b in PHASE_LABELS:
            p = Params(skew=s, window_s=window_s, block_time_s=t_b, fee_bps=fee_bps)
            row.append(fmt_pct(sustained_cost_fraction_exact(p)))
        rows.append(row)
    return rows


def build_window_table(skew: float, fee_bps: int, t_b: float) -> list[list[str]]:
    """Cost as % of TVL across (window, capital-needed) for fixed skew + fee + phase."""
    rows = [["Window", "Cost (% TVL)", "Cost on $10k pool", "Cost on $100k", "Cost on $1M"]]
    for w in WINDOW_LADDER_S:
        p = Params(skew=skew, window_s=w, block_time_s=t_b, fee_bps=fee_bps)
        frac = sustained_cost_fraction_exact(p)
        rows.append(
            [
                f"{int(w / 60)}min",
                fmt_pct(frac),
                fmt_usd(frac * 10_000),
                fmt_usd(frac * 100_000),
                fmt_usd(frac * 1_000_000),
            ]
        )
    return rows


def build_fee_tier_table(window_s: float, t_b: float) -> list[list[str]]:
    head = ["TWAP skew"] + [f"{bp}bps tier" for bp in FEE_LADDER]
    rows = [head]
    for s in SKEW_LADDER:
        row = [fmt_pct(s)]
        for bp in FEE_LADDER:
            p = Params(skew=s, window_s=window_s, block_time_s=t_b, fee_bps=bp)
            row.append(fmt_pct(sustained_cost_fraction_exact(p)))
        rows.append(row)
    return rows


def build_arb_vs_no_arb_table(window_s: float, t_b: float, fee_bps: int) -> list[list[str]]:
    """Compare sustained-attack (with arbs) cost vs the no-arb floor.

    The no-arb FLOOR is swap-and-hold (one round-trip LVR), NOT the donation
    value -- a rational no-arb attacker swaps to S and holds rather than donating.
    Donation is shown only as an upper reference for the no-arb regime."""
    f = fee_bps / 10_000.0
    rows = [["TWAP skew", "Sustained (with arbs)", "No-arb floor (swap-and-hold)", "Donation (upper ref)"]]
    for s in SKEW_LADDER:
        p = Params(skew=s, window_s=window_s, block_time_s=t_b, fee_bps=fee_bps)
        with_arbs = sustained_cost_fraction_exact(p)
        no_arb_floor = held_swap_no_arb_cost_fraction(s, f)
        donation = donation_cost_fraction(s)
        rows.append(
            [
                fmt_pct(s),
                fmt_pct(with_arbs),
                fmt_pct(no_arb_floor),
                fmt_pct(donation),
            ]
        )
    return rows


def build_capital_requirement_table(t_b: float, window_s: float, fee_bps: int) -> list[list[str]]:
    """For each skew, show the attacker capital fraction needed for single-block spike
    AND for sustained-attack cumulative capital flow."""
    rows = [["TWAP skew", "Delta needed (single-block spike)", "Capital (% reserve, single block)", "Sustained cost (% TVL)"]]
    f = fee_bps / 10_000.0
    for s in SKEW_LADDER:
        # single-block: delta = S * W / T_b (large displacement for one block)
        delta_spike = s * window_s / t_b
        capital_frac = trade_size_for_delta(delta_spike, f) if delta_spike < 100.0 else float("inf")
        p = Params(skew=s, window_s=window_s, block_time_s=t_b, fee_bps=fee_bps)
        sustained = sustained_cost_fraction_exact(p)
        cap_str = "infeasible" if capital_frac == float("inf") or capital_frac > 100 else fmt_pct(capital_frac)
        delta_str = "infeasible" if delta_spike > 1000 else f"{delta_spike * 100:.1f}%"
        rows.append([fmt_pct(s), delta_str, cap_str, fmt_pct(sustained)])
    return rows


# --------------------------------------------------------------------------
# Markdown / CSV output
# --------------------------------------------------------------------------


def to_markdown(rows: list[list[str]]) -> str:
    head, body = rows[0], rows[1:]
    out = ["| " + " | ".join(head) + " |"]
    out.append("|" + "|".join(["-" * (len(c) + 2) for c in head]) + "|")
    for r in body:
        out.append("| " + " | ".join(r) + " |")
    return "\n".join(out)


def to_csv(rows: list[list[str]], path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", newline="") as fh:
        writer = csv.writer(fh)
        writer.writerows(rows)


# --------------------------------------------------------------------------
# Main: regenerate all tables for the doc
# --------------------------------------------------------------------------


def emit_all(out_dir: Path) -> dict[str, str]:
    """Returns a dict of table-key -> markdown for inline use in the doc.
    CSV files are written to `out_dir` for re-import / spreadsheet workflows."""

    tables: dict[str, str] = {}

    # Headline skew-vs-phase tables at each fee tier (W = 30min).
    for bp in FEE_LADDER:
        key = f"skew_phase_w30_fee{bp}"
        rows = build_skew_table(30 * 60, bp)
        tables[key] = to_markdown(rows)
        to_csv(rows, out_dir / f"{key}.csv")

    # Window sensitivity at S=1%, S=5% (live ~6s network, fee=25bps).
    for s, label in [(0.01, "s1pct"), (0.05, "s5pct")]:
        key = f"window_{label}_live_fee25"
        rows = build_window_table(s, FEE_TIER_25_BPS, LIVE_T_B)
        tables[key] = to_markdown(rows)
        to_csv(rows, out_dir / f"{key}.csv")

    # Fee-tier comparison (live ~6s network, W=30min).
    key = "fee_tier_w30_live"
    rows = build_fee_tier_table(30 * 60, LIVE_T_B)
    tables[key] = to_markdown(rows)
    to_csv(rows, out_dir / f"{key}.csv")

    # Arb-vs-no-arb (live ~6s network, W=30min, fee=25bps).
    key = "arb_vs_no_arb_live_w30_fee25"
    rows = build_arb_vs_no_arb_table(30 * 60, LIVE_T_B, FEE_TIER_25_BPS)
    tables[key] = to_markdown(rows)
    to_csv(rows, out_dir / f"{key}.csv")

    # Single-block capital requirement (live ~6s network, W=30min, fee=25bps).
    key = "capital_live_w30_fee25"
    rows = build_capital_requirement_table(LIVE_T_B, 30 * 60, FEE_TIER_25_BPS)
    tables[key] = to_markdown(rows)
    to_csv(rows, out_dir / f"{key}.csv")

    return tables


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--out",
        type=Path,
        default=Path(__file__).parent / "tables",
        help="Directory to write CSV tables (default: tools/twap/tables/).",
    )
    parser.add_argument(
        "--print-md",
        action="store_true",
        help="Print all markdown tables to stdout (for paste-into-doc workflow).",
    )
    args = parser.parse_args(argv)

    tables = emit_all(args.out)

    if args.print_md:
        for key, md in tables.items():
            print(f"\n## {key}\n")
            print(md)

    print(f"\nWrote {len(tables)} CSV tables to {args.out}.", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
