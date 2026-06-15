# TWAP security: manipulation cost and consumer guidance

SigalSwap pairs expose a constant-product cumulative-price (TWAP) accumulator. This document quantifies the cost of skewing that TWAP by an arbitrary amount over an arbitrary window, names the adversary model behind the numbers, and gives concrete pool-sizing recommendations for downstream consumers (lending protocols, peg defenders, derivatives mark prices).

The numbers below are produced by `tools/twap/cost_model.py`. Run that script to regenerate the tables or to plug in your own scenario.

> **⚠️ The numbers below assume ACTIVE ARBITRAGE.** They are the cost an attacker bears when a competent arbitrageur reverses each manipulating trade every block. On a young / arb-sparse network (early Aztec) the binding attacker cost is the **no-arb floor**, which is materially lower and does not grow with window length. The quantitative no-arb floor and the consumer pool-sizing tables derived from it are **omitted here pending external peer review** -- publishing provisional sizing numbers for a liquidation oracle would be unsafe if relied upon. Do not size a production oracle consumer off the with-arb figures alone in the current arb-sparse regime: aggregate multiple oracles and size conservatively. The qualitative threat model and the active-arbitrage figures are unaffected.

## Summary for integrators

If you read nothing else:

- **⚠️ These headline figures assume ACTIVE ARBITRAGE.** With a mature arb market the attacker must re-push every block, so the sustained costs below apply. In the **arb-sparse regime (early Aztec)** the binding cost is much lower and does **not** grow with window length; the quantitative no-arb floor is omitted pending external TWAP peer review (see the caveat above). Size conservatively and aggregate oracles until that regime ends.
- **With active arbs, 30-minute TWAPs on $1M+ pools are robust against a rational attacker.** Forcing a 5% TWAP skew over a 30-min window costs ≈10% of pool TVL — $100k on a $1M pool — and they cannot extract that back from the pool itself. (In the arb-sparse regime the real cost is materially lower — see the caveat above.)
- **Sub-$100k pools are not safe TWAP sources for any high-value consumer.** With arbs, a 5% TWAP skew on a $10k pool costs the attacker ≈$1,000 (and materially less when arbs are sparse); if your protocol's marginal liquidation profit on a single position exceeds that, you have an arbitrage opportunity for the attacker.
- **Longer windows help linearly — but only against an arb-fighting attacker.** With arbs, a 4-hour TWAP is 8x more expensive to manipulate than a 30-min TWAP at the same skew. Against a no-arb swap-and-hold attacker a longer window does NOT raise the round-trip cost (one swap, held longer). Pick the longest window your application can tolerate, but don't rely on window length alone in the arb-sparse regime.
- **Block time has a linear inverse effect on attacker cost.** Aztec's Ignition mainnet is live at ~6s blocks — that is the current network and the basis for the numbers below. Slower blocks mean fewer blocks per window, which makes manipulation *cheaper*; a degraded/slow-network scenario at 72s blocks would cost ≈12x less. Size against the live ~6s column. The 72s column is a conservative lower bound on attacker cost should block production stall.

## What the pair provides

Each SigalSwap pair maintains two cumulative-price accumulators (`price0_cumul`, `price1_cumul`) advanced on every state-changing entry (mint, burn, swap, sync) where time has elapsed:

```
price0_cumulative += (reserve1 / reserve0) * time_elapsed
price1_cumulative += (reserve0 / reserve1) * time_elapsed
```

Reserves used for the update are the *pre-update* values, so the accumulator represents an integral of spot price over the inter-update interval, weighted by the time spent at that price. Consumers compute TWAP as the difference between two reads divided by the elapsed time. Each accumulator is a UQ112x112 split value (`integer + fraction / Q112`): the integer component is stored as a BN254 `Field` (so it wraps modularly at the field order rather than truncating), and the fraction as a `u128` in `[0, Q112)`. Consumers MUST reconstruct the full scaled value `integer * Q112 + fraction` per read before taking the `Field`-subtraction delta -- differencing the integer alone reads TWAP = 0 for any pair whose price ratio is below 1 in that direction (e.g. ETH/USDC, where the integer accumulator stays 0 and the signal lives entirely in the fraction). The full delta is correct for any realistic window (the real accumulated delta is always many orders of magnitude below the field modulus). See `protocol/core/README.md` (oracle section) for the exact reconstruction recipe and the SDK's `SigalSwapPair.twapBetween` helper.

The pair exposes the accessor:

```
unconstrained fn get_cumulative_prices() -> (Field, u128, Field, u128, u64)
//                                          price0_int, frac, price1_int, frac, block_timestamp_last
```

## Adversary model

The cost numbers below assume an attacker with the following capabilities:

- **Unbounded capital.** The cost result is a floor, not the attacker's budget. We answer "how much money does the attack actually consume," not "how much money does the attacker need."
- **Guaranteed tx inclusion every block.** The attacker can submit a tx each block of the manipulation period; no per-block lottery losses. On Aztec this is realistic for whoever's willing to pay top-of-block priority, since sequencers are not adversarial in the model.
- **No tx-ordering control over others.** The attacker cannot censor arbitrageurs. They can pay for the best inclusion priority but cannot prevent other txs from landing in the same block.
- **One competent arbitrageur per block.** This is the *conservative* assumption — it makes manipulation more expensive. If no arbitrageurs are present (early Aztec, sparse-volume pools), manipulation gets cheaper; we treat this separately as the no-arb **swap-and-hold floor** below.
- **No off-chain side payments.** The attacker doesn't bribe sequencers, doesn't run their own validator, doesn't have a relationship with the proposer. Pure capital attack.

For sequencer-collusion and ordering-manipulation scenarios, see the MEV / front-running analysis (`docs/mev-considerations.md`); those concerns are out of scope here.

## Attack variants

Three patterns the attacker can use to skew the TWAP:

### Variant 1 — single-block spike

The attacker executes one large swap pushing the pool away from the external price by some factor `(1 + δ)`. Arbitrageurs rebalance in the following block, restoring the pool. The accumulator integrates the manipulated price for ≈ one block time `T_b`.

```
TWAP_skew(over window W) = δ * T_b / W
```

The attacker pays the LP fee on the push leg, and loses to whoever arbs back via the price impact of the round-trip.

**Limitation:** to produce a meaningful TWAP skew over a 30-min window with 6-second blocks, the attacker would need a δ of `0.01 * (W/T_b) = 3` (i.e., a 300% spot price displacement, matching the capital-requirement table below) for a 1% TWAP skew. That requires capital comparable to the pool itself. Single-block spikes are practical only for very small TWAP shifts.

### Variant 2 — sustained manipulation

The attacker holds the pool at displacement δ across N blocks of the window. Every block, arbitrageurs take a chunk of the displacement; the attacker re-pushes to maintain it. Each push pays LP fee + LVR.

```
N = T_skew / T_b
TWAP_skew = δ * T_skew / W
cost ≈ N * V * [ f*δ/4 + δ²/8 ]    (linearized; exact form below)
```

For the cheapest attack at a given TWAP skew target S, the attacker spreads displacement across the whole window (`T_skew = W`, `δ = S`). This minimizes the LVR² term while paying the unavoidable LP-fee tax across all `W/T_b` blocks. Closed-form:

```
cost / V = (W/T_b) * S * (f/4 + S/8)
```

This is the formula the tables below use. Numerically, we use the exact one-round-trip LVR (`(sqrt(1+δ)-1)² / sqrt(1+δ)` adjusted for fees) rather than the linearization, which differs from the closed form by a few percent at high δ.

### Variant 3 — donation-then-sync

The attacker transfers tokens directly to the pair (no swap, no fee), then calls `sync()` (or waits for any state-changing entry). The pair updates TWAP using pre-donation reserves and then snaps stored reserves to the post-donation balance. From that moment on, the TWAP integrates the *displaced* price.

The donation goes to LPs permanently via K-growth — the attacker gets nothing back. The attack is only useful if:

- No arbitrageurs are present (the donation-induced displacement persists), or
- The attacker only needs a one-block spike and prefers paying donation value over swap-fee + slippage.

In the no-arb case the binding (cheapest) attack is **swap-and-hold**: the attacker swaps to displacement S, holds it across the whole window W (no arbitrageur reverses it), and unwinds *after* the window. The TWAP is skewed by S for the full window while the attacker bears only a single round-trip's cost rather than re-paying every block. The precise no-arb floor is materially below both the donation value and the with-arb sustained cost, and is **omitted here pending external peer review** (see the caveat at the top). The donation figure `S/2 * V` is an *upper* reference for the no-arb regime, not the floor.

## Cost derivation

For the with-arbs case, the per-block cost of pushing the pool from equilibrium to displacement δ (and being arbed back) is the attacker's loss against external prices. Selling `Δy` of token1 into the pool:

```
Δy = u * y                              (u is trade size as fraction of reserve)
Δx = x * Δy * (1-f) / (y + Δy * (1-f))   (constant-product swap output formula)
loss_token1 = Δy * [f*y + Δy*(1-f)] / (y + Δy*(1-f))
```

The price displacement is `m = (1+u)(1+u(1-f))`. To target a given displacement, solve the quadratic for `u`; then loss-per-trade follows. Converted to TVL units (`V = 2y`):

```
cost_per_round_trip / V = u * [u*(1-f) + f] / (2 * (1 + u*(1-f)))
```

The script `tools/twap/cost_model.py` implements this exactly.

## Cost tables

### Skew vs Aztec phase (30-min window, 25-bps LP fee tier)

Cost as a fraction of pool TVL. The three columns are block-time sensitivity points: the live ~6s network (Aztec Ignition mainnet, current), a conservative 72s slow-/degraded-network bound (cheaper to attack — fewer blocks per window), and a ~4s future roadmap target. Size against the live ~6s column.

| TWAP skew | Slow-block 72s (conservative) | Live ~6s (current) | Future ~4s (target) |
|-----------|----------------|------------|---------------|
| 0.1000% | 0.0019% | 0.0225% | 0.0338% |
| 0.5000% | 0.0156% | 0.1868% | 0.2802% |
| 1.00% | 0.0465% | 0.5576% | 0.8364% |
| 2.00% | 0.1534% | 1.84% | 2.76% |
| 5.00% | 0.8194% | 9.83% | 14.75% |
| 10.00% | 2.99% | 35.82% | 53.73% |
| 25.00% | 15.91% | 191% | 286% |

Reading: on a $100k pool on the live ~6s network, forcing a 5% TWAP skew over a 30-min window costs ≈ $9,830.

The live ~6s column is the current network and the one to size against. The 72s column is a conservative bound for a slow / degraded network (fewer blocks per window, so cheaper to attack). The ~4s column shows where the protocol's TWAP becomes most expensive to manipulate as block times tighten (more blocks per window means more LP fees the attacker eats).

### Same table at the other fee tiers (live ~6s network, 30-min window)

| TWAP skew | 5bps tier | 25bps tier | 100bps tier |
|-----------|-----------|------------|-------------|
| 0.1000% | 0.0075% | 0.0225% | 0.0791% |
| 0.5000% | 0.1120% | 0.1868% | 0.4688% |
| 1.00% | 0.4085% | 0.5576% | 1.12% |
| 2.00% | 1.54% | 1.84% | 2.96% |
| 5.00% | 9.11% | 9.83% | 12.56% |
| 10.00% | 34.42% | 35.82% | 41.10% |
| 25.00% | 188% | 191% | 203% |

Higher LP fees make manipulation more expensive — the attacker pays the fee on every push. The difference is meaningful at small skew (≈10x between 5bps and 100bps at 0.1% skew) but small at large skew, where the LVR term dominates the LP-fee term.

### Window-length sensitivity (live ~6s network, 25bps tier)

At 1% TWAP skew:

| Window | Cost (% TVL) | Cost on $10k pool | Cost on $100k | Cost on $1M |
|--------|--------------|-------------------|---------------|-------------|
| 5min | 0.0929% | $9.29 | $92.94 | $929 |
| 15min | 0.2788% | $27.88 | $279 | $2.8k |
| 30min | 0.5576% | $55.76 | $558 | $5.6k |
| 60min | 1.12% | $112 | $1.1k | $11.2k |
| 240min | 4.46% | $446 | $4.5k | $44.6k |

At 5% TWAP skew:

| Window | Cost (% TVL) | Cost on $10k pool | Cost on $100k | Cost on $1M |
|--------|--------------|-------------------|---------------|-------------|
| 5min | 1.64% | $164 | $1.6k | $16.4k |
| 15min | 4.92% | $492 | $4.9k | $49.2k |
| 30min | 9.83% | $983 | $9.8k | $98.3k |
| 60min | 19.66% | $2.0k | $19.7k | $196.6k |
| 240min | 78.66% | $7.9k | $78.7k | $786.6k |

Cost is linear in window length. Doubling the window doubles the attacker cost at the same skew.

### Arb-rich vs arb-sparse (live ~6s network, 25bps, 30-min window)

The attacker always picks the cheaper of the two regimes. In a mature-arb environment, sustained manipulation (the tables above) dominates above ~1% skew. In an arb-sparse environment (early Aztec), the binding cost is the **no-arb floor**: the attacker swaps to the target displacement and holds it across the window, with no arbitrageur to fight, bearing only a single round-trip's cost. That floor is materially below the sustained-with-arbs cost and is **omitted here pending external peer review**. For consumers integrating during the Aztec ecosystem's early, arb-sparse phase: do not rely on the with-arb tables, size pools far larger (or windows far longer) than those tables suggest, and aggregate multiple oracles. (The attacker still needs enough *capital* to move spot by the target — see the capital-requirement table — independent of the cost they ultimately bear.)

### Capital requirement (single-block spike, live ~6s network, 30-min window, 25bps)

Shows what's required for a single-block-spike attack (Variant 1) to achieve a given TWAP skew. The capital column is the fraction of the *token1 reserve* the attacker must commit as trading volume.

| TWAP skew | Delta needed (single-block spike) | Capital (% reserve, single block) | Sustained cost (% TVL) |
|-----------|-----------------------------------|-----------------------------------|------------------------|
| 0.1000% | 30.0% | 14.04% | 0.0225% |
| 0.5000% | 150.0% | 58.19% | 0.1868% |
| 1.00% | 300.0% | 100% | 0.5576% |
| 2.00% | 600.0% | 165% | 1.84% |
| 5.00% | 1500.0% | 300% | 9.83% |

The single-block-spike variant becomes capital-infeasible above ~1% TWAP skew: to push the spot 300% in one block, the attacker has to trade their entire token1 holding into the pool. At 5% TWAP skew via spike, they need 3x the pool's reserve in capital — even before considering the LP fee they'll pay. Practical attackers above ~1% skew use sustained manipulation.

## Worked examples

These translate the abstract cost-percent-of-TVL into specific consumer threat scenarios. Each scenario picks a representative pool size, target skew, and asks "is the attacker rational."

### Example 1 — lending oracle ($1M pool, 30-min TWAP, 25bps)

A lending protocol uses SigalSwap as its collateral-price oracle and triggers liquidations when collateral value falls below 80% of debt. The pool holds $1M total liquidity. A 5% skew downward is enough to trigger erroneous liquidations on positions sitting just above the 80% threshold.

Attacker cost for 5% skew over 30min, with arbs: $98,300.

For the attack to net positive, the attacker's extracted value from the erroneous liquidation must exceed the cost they actually bear. With active arbs that is ~$98,300. In the arb-sparse regime the cost is materially lower (the no-arb floor, omitted here pending review), so an early-Aztec $1M pool can be cheap to skew 5% as long as the attacker has the capital to move spot.

**Implication:** the lending protocol must size against the *arb-sparse* cost, not the with-arb cost. Single-position liquidation upside must be bounded far below the attacker's true cost in the prevailing arb regime, OR (realistically) the pool must be much larger / the window much longer / the oracle aggregated.

### Example 2 — stablecoin peg defense ($100k pool, 60-min TWAP, 5bps)

A stablecoin issuer uses a SigalSwap TWAP to detect peg deviations and trigger PSM rebalancing. The relevant skew threshold is ~0.5% (a 0.5% peg deviation sustained for an hour is the trigger).

Attacker cost for 0.5% skew over 60min, live ~6s network, 5bps: 0.224% TVL = $224.

This is alarmingly cheap. A would-be attacker spends $224 and triggers the PSM to act. Whether this nets positive for the attacker depends on what the PSM does:

- If the PSM swaps reserves at the manipulated price, the attacker can profit by being on the other side. Use a different oracle, or use the TWAP only for detection (not for execution price).
- If the PSM uses the TWAP as a *signal* and executes at fresh spot, the manipulation just causes a misfire — the attacker burns $224 to make the issuer act once. This is denial-of-service economics, not theft.

**Implication:** for any consumer that *executes value* against the TWAP-derived price, $100k pools are insufficient. For *signal-only* consumers, the per-misfire cost ($224) bounds DoS spam: the issuer can afford to misfire up to its operating budget per period.

### Example 3 — derivatives mark price ($1M pool, 240-min TWAP, 25bps)

A perpetual futures venue uses a 4-hour SigalSwap TWAP as its mark-price input for funding-rate calculations. The relevant skew threshold is 1% (a 1% miscount of mark price meaningfully shifts the funding rate).

Attacker cost for 1% skew over 240min, with arbs: 4.46% TVL = $44,600. In the arb-sparse regime the cost is materially lower and does NOT grow with the 4-hour window — the no-arb attacker swaps once and holds, so a longer window raises their capital-lockup time but not the cost they pay; the precise floor is omitted here pending review.

Funding-rate manipulation profits depend on the attacker's perp position size. For a typical centralized-perp venue with $10M+ OI, even a 1% funding-rate skew can produce ~$100k+ of arbitrage. The on-chain attack cost — much lower in the arb-sparse regime, up to $44,600 with mature arbs — is cheap relative to that off-chain extraction surface, a serious concern.

**Implication:** derivatives venues should not single-source TWAP from a single SigalSwap pool unless the pool TVL is >> 10x the maximum funding-extraction surface. A multi-oracle aggregator (SigalSwap TWAP + Chainlink + spot exchanges) is the correct architecture; SigalSwap alone is appropriate only for low-stakes mark-price uses.

## Consumer guidance

Concrete pool-sizing recommendations, derived from the tables above:

### Minimum pool size by attacker-cost target

Concrete `min_pool_TVL` tables (sizing a pool so an attacker must spend at least `$X` to skew the TWAP by `S`) depend on the no-arb floor and are **omitted here pending external peer review** — publishing provisional sizing numbers for a liquidation oracle would be unsafe if relied upon. The qualitative conclusion is robust: absent active arbitrage, a single SigalSwap TWAP is not an economically robust oracle for high-value, low-skew thresholds unless the pool is very large or the window is very long. Size against the arb-sparse regime, lengthen the window (cost scales linearly with window against an arb-fighting attacker), and/or aggregate multiple oracles. Once a mature arb market exists, the with-arb tables above apply and required pools shrink accordingly.

### Window-length scaling

To get the same protection on a *smaller* pool, lengthen the window proportionally:

```
required_window = 30min * (target_attacker_cost / table_cost_at_30min)
```

A 4-hour window on a $250k pool gives equivalent protection to a 30-min window on a $2M pool. Use the longest window your application's freshness requirements allow. **Caveat (arb-sparse):** this linear window-scaling holds only against an attacker who must fight arbitrageurs each block. Against a no-arb swap-and-hold attacker, lengthening the window does not raise the round-trip LVR they pay (it only lengthens their capital lockup), so window length is not a substitute for pool depth or oracle aggregation when arbs are sparse.

### When to NOT use a SigalSwap TWAP

If any of the following are true, use a different oracle (or a multi-oracle aggregator):

1. **Sub-minute price sensitivity.** SigalSwap TWAP needs at least a 5-minute window to be meaningful; anything below that is essentially the spot price (trivially manipulable by a single swap).
2. **Settlement / execution at the TWAP price.** TWAPs are appropriate for *thresholds* (liquidation triggers, peg detection), not for *prices at which the protocol executes a trade*. Settle on fresh spot or a separate quote source.
3. **The downstream protocol's per-event extraction surface is comparable to the pool TVL.** If a single liquidation can extract $50k from a $100k pool's TWAP, the attacker just sandwiched you.
4. **The pool is on a young network without active arbitrage.** When arbs are sparse, the no-arb floor — far below the sustained-attack cost — sets your cost, so arb-sparse pools must be far larger (or windows far longer) than the with-arb numbers suggest. The precise arb-sparse floor is pending external review; until then, treat the with-arb tables as optimistic and aggregate oracles.

## Things this analysis does NOT cover

To be explicit about non-claims:

- **Volatile-pair noise.** All numbers assume the "true" external price is constant over the manipulation window. For token-token (not stable-stable) pairs, external price moves create noise the attacker can hide in. The cost model is conservative in the sense that the attacker can opportunistically time their attack with adverse moves to reduce LVR — this is a roughly constant-factor effect (~2x cheaper in volatile regimes), not an order-of-magnitude one.
- **Sequencer ordering attacks.** A malicious sequencer can give the attacker preferential ordering or censor arbs, breaking the "one arb per block" assumption. This is covered in `docs/mev-considerations.md`. For now: assume Aztec's sequencer is honest.
- **Cross-pair arbitrage during the attack.** A sophisticated attacker may also arb the same asset across other pools (CEX, other DEXes) during the window. This pushes the attacker's cost down by capturing arb spread off-platform; the model doesn't credit them this.
- **Capital-cost of capital.** The model treats attacker capital as free. In reality there's opportunity cost (could have been earning yield elsewhere). For short attack windows this is negligible.
- **Donation amplification via reflexive trading.** If the attacker's donation moves the price enough to trigger reflexive trading (other users see the displaced price and act on it), the attacker may not need to maintain the displacement. Not modeled.

## How to reproduce / extend

The numbers in this document come from `tools/twap/cost_model.py`. The script has no non-stdlib dependencies; runs on any Python 3.8+. To regenerate:

```bash
python3 tools/twap/cost_model.py --print-md
```

CSV outputs land in `tools/twap/tables/` for spreadsheet workflows.

To explore your own scenario:

```python
from cost_model import Params, sustained_cost_fraction_exact, donation_cost_fraction
p = Params(skew=0.03, window_s=3600, block_time_s=6, fee_bps=25)
print(f"sustained: {sustained_cost_fraction_exact(p) * 100:.2f}% TVL")
print(f"donation:  {donation_cost_fraction(0.03) * 100:.2f}% TVL")
```

## References

- Aztec block-time / slot phasing: [forum.aztec.network/t/8210](https://forum.aztec.network/t/defining-block-timestamps-on-the-aztec-network/8210), and the Aztec roadmap.
- SigalSwap accumulator implementation: `protocol/core/src/math/fixed_point.nr`, `protocol/core/src/main.nr` (TWAP update sites at Step 6/7 of each state-changing entry).
- The linearized sustained-cost form `cost / V ~ (W/T_b) * S * (f/4 + S/8)` and the donation *upper reference* `cost / V ~ S/2` are derived in the "Cost derivation" section above. The binding no-arb floor (swap-and-hold) is below the donation value and is pending external peer review. These cost forms are well-trodden in the constant-product-AMM oracle-cost literature.
