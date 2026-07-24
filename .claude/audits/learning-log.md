# Audit Learning Log

This log is updated automatically after every audit.

## Trends (as of 2026-07-24, audit #3)

| Metric | Value |
|---|---|
| Total audits | 3 |
| Critical trend (last 3) | 4 -> 2 -> 0 |
| Important trend (last 3) | 8 -> 8 -> 6 |
| Top category (last 5) | Architecture/Concurrency (lifetime/race misuse 4x across three audits) |
| Avg findings/audit | 15 |

**Repeat offenders (>=3):**
- Structured-concurrency/lifetime misuse (4x: unguarded concurrent drops; TaskGroup timeout awaiting children; async-let scope-exit stall; shelf fade show/hide race). Watch every new await/race/animation task for who-awaits-whom and stale completions on early exits.
- Same-diff duplication across parallel surfaces (2x, rising: state mapping and observer loops duplicated between popover and shelf). When a second surface consumes ConvertModel state, check for a shared API first.

---

## Retro — 2026-07-24 — main (audit #3, menubar conversion)

### Statistics
- Critical: 0, Important: 6, Minor: 5 (all fixed); 6 discarded with justification
- New pattern: verifier hallucinated a compile error (FadeState "needs Equatable") disproven by existing green builds — always cross-check verifier claims against real tool output before dispatching a patch.
- Privacy-relevant capability (global drag monitoring) caught by the security dimension and both narrowed and disclosed in the same round.

## Retro — 2026-07-24 — main (audit #2, preview/extraction features)

### Statistics
- Critical: 2, Important: 8, Minor: 1 (all fixed); 4 discarded with justification
- Round 2 caught a fix-introduced regression (async-let cancellation stall) — the lean convergence round pays off
- One fix agent omitted its FIX_RESULT line; git-status cross-check + mandatory verifier covered it

### Pattern worth keeping
- Timeouts around non-cooperative async APIs (LanguageModelSession.respond): TaskGroup races are NOT wall-clock bounds; continuation race + ResumeOnce + withTaskCancellationHandler is the working pattern (InvoiceExtractor.swift).

## Retro — 2026-07-24 — main (audit)

### Statistics
- First audit in the project — no pattern detection possible yet

### Baseline
- Critical: 4, Important: 8, Minor: 6
- Clean dimensions: ui_design, animation (findings discarded as stylistic, no fix needed); seo, typography (N/A, no web pages)
