# Audit Learning Log

This log is updated automatically after every audit.

## Trends (as of 2026-07-24, audit #2)

| Metric | Value |
|---|---|
| Total audits | 2 |
| Critical trend (last 3) | 4 -> 2 |
| Important trend (last 3) | 8 -> 8 |
| Top category (last 5) | Architecture/Concurrency (structured-concurrency misuse 3x across both audits) |
| Avg findings/audit | 16 |

**Repeat offenders (>=3):**
- Structured-concurrency lifetime misuse (3x: unguarded concurrent drops; TaskGroup timeout awaiting children; async-let scope-exit stall). Watch every new await/race for who-awaits-whom on early exits.

---

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
