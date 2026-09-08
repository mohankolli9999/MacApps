# Disk Reclaim for macOS — Design

**Date:** 2026-09-09
**Status:** Approved design, pre-implementation
**Scope:** Single-Mac v1

## Problem

Developer machines fill with build artefacts, package caches and — increasingly — AI model weights. macOS reports most of this as an unactionable "System Data" bucket. Existing tools show the user how many bytes are where, then leave the judgement, and the risk, entirely to them.

Measured on the author's Mac (460GB volume, 91% full, 39GB free):

| Size | Path |
|---|---|
| 21G | `~/Library/Caches` |
| 14G | `~/.ollama` |
| 13G | `~/.cache` |
| 11G | `~/.lmstudio` |
| 8.2G | Docker (`~/Library/Containers/com.docker.docker`) |
| 7.9G | `~/.cache/huggingface` |
| 4.2G | `~/.npm` |
| 3.8G | `~/.gradle` |
| 1.4G | Homebrew cache |
| 1.4G | VS Code application support |
| 919M | pip cache |
| 227M | `~/.bun` |

**~87GB in reclaimable-class artefacts, of which ~33GB is AI model weights** — the single largest category, exceeding Docker, npm and Gradle combined.

A naive `du -shx` over the home directory took over five minutes to complete. Scan performance is a product requirement, not an optimisation.

## Market position

Research conducted 2026-09-09 against the GitHub `disk-analyzer` topic (130 repos, 19 Swift), the cleardisk issue tracker, and Hacker News.

**The field is saturated with near-identical clones.** Of 19 Swift/macOS repos, 13 have zero stars and nearly all were created between February and August 2026. Three projects hold ~1,351 of ~1,365 total stars: cleardisk (687), Neodisk (562), OpenDisk (102). The dominant feature set — treemap or sunburst, a "safe to delete" heuristic, a duplicate finder — is table stakes and carries no differentiation.

**Individuals demonstrably do not pay.** DaisyDisk sets the category ceiling at $9.99 one-time, lifetime, five Macs. "Klarity Disk", pitched explicitly as a $6.99 DaisyDisk alternative, scored 1 point on Hacker News. Across ~25 issues and PRs on cleardisk there is no mention of pricing, licensing, donations or a pro tier.

**Two problems are genuinely unsolved:**

1. **Destructive deletion with no recovery.** cleardisk issue #27 reports a user losing all of their Claude CoWork sessions, unrecoverably. The requested remedy — "a confirmation step or dry-run/backup option before deleting any directory that isn't unambiguously regenerable" — was never implemented. No project in the field offers undo or restore. On Hacker News, `diskard`'s entire stated differentiator was moving files to Trash rather than deleting them.

2. **Incorrect accounting.** Analyzers miscount APFS clones and hardlinks, over-reporting shared `node_modules` and virtualenvs across worktrees. Docker's cache is not a host filesystem path at all and requires CLI interrogation (cleardisk #39).

**Uncovered category.** cleardisk's catalogue is Xcode, node_modules, CocoaPods, SPM, Docker, pip and Cargo. It covers none of Ollama, LM Studio or Hugging Face — the largest category on a modern developer machine.

### Commercial thesis

Safety and correctness are the product; fleet deployment is the business model. Unattended reclaim across an engineering organisation's laptops is only sellable if every action is provably reversible and every detection is provably correct. The individual developer need never pay.

**Named risk:** research found no direct evidence of organisations purchasing tooling in this category — no competitor, no complaints, no discussion. This is equally consistent with an unserved market and with no market. Customer conversations, not code, are the cheapest way to resolve it. v1 is designed to stand alone regardless of the outcome.

## Core insight

Reversibility and reclaiming space are in direct conflict. Trash lives on the same volume, so moving 30GB to Trash frees zero bytes. An APFS snapshot pins the deleted blocks, so it too frees nothing until retention expires.

The resolution: **do not retain the bytes, retain the proof that the bytes can be recreated.**

- Regenerable artefacts are restored from a *recipe* — a lockfile hash, a model digest, a build command. Storage cost is negligible; the real cost is time, which is measured and disclosed.
- Irreplaceable artefacts have no recipe and are therefore never removed automatically.

This yields the product's governing rule:

> **No artefact is touched unless it carries a validated restore recipe, or the user explicitly consents to its loss.**

## Tier model

Every detected artefact resolves to exactly one tier. The tier determines what may happen to it.

| Tier | Meaning | Examples | Default action |
|---|---|---|---|
| **T0 Exact** | Restores byte-identical from a recipe | Ollama model (digest + `pull`); `node_modules` (lockfile + `npm ci`); Hugging Face repo (id + revision) | Auto-reclaim |
| **T1 Costly** | Regenerates deterministically, at measured time cost | Xcode DerivedData; Gradle cache; Cargo `target/` | Reclaim, with time cost disclosed |
| **T2 Irreplaceable** | No recipe exists | Claude CoWork sessions; Docker named volumes holding data; unsaved simulator state | Never automatic. APFS snapshot plus explicit per-item consent |
| **T3 Unknown** | Not present in the catalogue | Any unrecognised directory | Never touched. Reported as "unclassified" only |

T3 is the trust anchor. An unrecognised 20GB directory is reported and never actioned. Issue #27 occurred because unrecognised user data sat inside a swept path; here, unknown means untouchable. The unclassified list doubles as the catalogue roadmap.

Only T0 and T1 are ever actioned without per-item consent.

**Tiering is per sub-artefact, not per tool.** Docker is the clearest case: its build cache is T1 (prunable, regenerates on next build) while its named volumes are T2 (may hold the only copy of data). A catalogue entry therefore describes a specific artefact, never an application. This is the distinction cleardisk #39 asked for and #30 codified — risk describes the consequence of deletion, not the owning app.

## The guarantee: validate before destroy

Before any deletion, the restore recipe is **executed against reality and confirmed**, never assumed:

| Artefact | Validation performed |
|---|---|
| Ollama model | Daemon reachable; digest resolvable in registry |
| `node_modules` | Lockfile present, parseable, fully pinned |
| Hugging Face repo | Repo id and revision resolvable |
| DerivedData | Project still exists; build command known |
| Homebrew cache | Formula resolvable at recorded version |

**If validation fails, the artefact is downgraded to T2 and skipped.** Nothing is deleted that has not just been proven recoverable. This is the differentiating guarantee and the precondition for unattended fleet operation.

Network-dependent validation is **enabled by default**. The lookups are read-only registry queries, and disabling them would downgrade Ollama and Hugging Face artefacts — the largest reclaimable category — permanently to T2, defeating the product's purpose. It remains switchable for air-gapped machines. When the network is unavailable, affected artefacts downgrade to T2 rather than proceeding.

## Architecture

A SwiftPM core library with a thin SwiftUI shell. The core is headlessly testable without Xcode, signing or an Apple Developer account, so the valuable and risky engineering can be proven before any spend.

### Components

**Catalogue** — Artefact definitions expressed as *data*, not code: detector, tier, recipe template, validator reference. Versioned and updatable independently of the app binary, so new toolchains ship without a release. This is the moat and the primary maintenance burden.

**Scanner** — Filesystem enumeration via `getattrlistbulk`. Target: full home directory in under 30 seconds, against `du`'s observed five-plus minutes. Keyed by inode so APFS clones and hardlinks are counted once; reports logical and physical size separately.

**Probes** — Interrogate artefacts that are not filesystem paths. Docker and Ollama are queried via their CLIs rather than walked.

**Classifier** — Maps a discovered path or probe result to a catalogue entry, yielding a tier.

**Validator** — Proves a recipe before execution. Owns the downgrade-to-T2 decision.

**Executor** — Performs reclaim. Takes an APFS snapshot first for anything in T2. Atomic per artefact.

**Restore engine** — Replays recipes from the manifest.

**Manifest store** — Append-only JSON log of every operation: artefact, tier, timestamp, bytes freed, validated restore command, snapshot reference where applicable. Written to Application Support, never inside a reclaimable path.

**UI shell** — SwiftUI menu-bar item plus main window. Presents scan results by tier, dry-run diffs, disclosed time costs, and restore history.

### Data flow

```
Scanner ─┐
         ├─→ Classifier ─→ Validator ─→ Executor ─→ Manifest
Probes  ─┘                     │
                               └─→ (validation failed) ─→ T2, skipped

Manifest ─→ Restore engine ─→ recipe replay
```

## Safety rules

- Dry-run is the default for a first run and always available thereafter.
- Refuse to act on a path with a running build or a live process holding it.
- Do not act in Low Power Mode without consent; scanning runs at `.utility` QoS on efficiency cores (cleardisk #28 was a battery complaint, #44 its fix).
- Each artefact is reclaimed atomically; a mid-run failure leaves a consistent manifest.
- Full Disk Access is required to scan `~/Library`. The TCC probe path has moved between macOS releases (cleardisk #40/#41) — detect capability by attempting a read, never by probing `TCC.db`.

## Testing

Test-driven throughout.

- **Catalogue entries are data**, so classification and detection are table-driven tests.
- **Round-trip tests are the critical class**: create fixture → reclaim → restore from recipe → assert byte-identical. **A catalogue entry without a passing round-trip test cannot ship as T0.**
- Validator tests cover the failure path explicitly: unreachable daemon, unpinned lockfile, missing revision, absent network — each must produce a T2 downgrade, never a deletion.
- Scanner tests cover APFS clone and hardlink accounting against constructed fixtures.

## Build and distribution

**Currently blocked for distribution.** The environment has the Swift 6.2 toolchain via Command Line Tools, but no Xcode, no code-signing identity, and no `notarytool`.

Shipping requires Xcode, Apple Developer Program membership ($99/yr), notarization, and a Full Disk Access entitlement on a signed bundle.

The SwiftPM-core/SwiftUI-shell split is chosen so that the core library — scanner, catalogue, classifier, validator, executor, restore engine — is fully implementable and testable today, with the shell and distribution deferred until the account exists.

## Non-goals for v1

Stated explicitly, because each is what the undifferentiated clones build:

- Duplicate file finder
- Treemap or sunburst visualisation as the primary interface
- General "system junk" cleaning, browser caches, RAM optimisation
- Application uninstallers
- Fleet management, central policy, dashboards (v2, contingent on demand validation)
- Windows or Linux support

## v1 catalogue

The initial catalogue covers the artefacts measured on the reference machine, prioritised by reclaimable size:

| Artefact | Tier | Recipe |
|---|---|---|
| Ollama models | T0 | name + digest → `ollama pull` |
| LM Studio models | T0 | repo id + revision → re-download |
| Hugging Face cache | T0 | repo id + revision → re-download |
| `node_modules` | T0 | lockfile hash → `npm ci` / `pnpm i --frozen-lockfile` |
| Homebrew cache | T0 | formula + version → refetch |
| pip cache | T0 | requirement + version → refetch |
| Xcode DerivedData | T1 | project path + build command |
| Gradle cache | T1 | project + `gradle build` |
| Cargo `target/` | T1 | crate path + `cargo build` |
| Docker build cache | T1 | `docker builder prune`; regenerates on next build |
| Docker named volumes | T2 | none — never automatic |
| iOS DeviceSupport / simulators | T1 | re-downloaded or regenerated by Xcode |

Each entry ships only once its round-trip test passes.

## Open questions

- Product name — undecided.
