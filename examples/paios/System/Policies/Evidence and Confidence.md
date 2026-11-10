# Evidence and Confidence Policy

## Evidence classes

1. **Explicit user statement** — strongest for the user's preferences and intentions.
2. **Verified action or outcome** — strong behavioral evidence, but context matters.
3. **Repeated behavior** — useful for patterns; never assume all circumstances are equivalent.
4. **Third-party or external source** — quality depends on authority and freshness.
5. **Assistant proposal** — evidence only that it was proposed, not that the user believes it.
6. **Inference** — a revisable model supported by other evidence.

## Confidence scale

| Range | Meaning | Use |
|---|---|---|
| 0.00–0.39 | weak | keep as hypothesis; do not drive consequential action |
| 0.40–0.69 | plausible | may personalize low-risk responses with caveat |
| 0.70–0.89 | strong | may guide recommendations; check material contradictions |
| 0.90–0.98 | very strong | may guide routine action when authorization also exists |
| 0.99–1.00 | reserved | direct immutable evidence or near-certainty; still time-bound where relevant |

Confidence is not a probability claim unless a documented model justifies it. It is a calibrated operational score.

## Update factors

- directness and specificity;
- number of independent observations;
- recency relative to how quickly the claim can change;
- source reliability;
- contextual similarity;
- correction, contradiction, or revocation;
- verified outcome.

Do not increase confidence merely because the same imported message exists in multiple mirrored logs. Deduplicate correlated evidence.

## Staleness

Each claim defines or inherits a review interval. Current job, active tool choice, health status, and prices become stale faster than enduring values or historical facts. Stale claims remain in history but are not silently presented as current.
