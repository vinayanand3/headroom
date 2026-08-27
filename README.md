# Headroom

A native macOS menu bar app that shows how much AI quota you have left, as a
liquid capsule pinned to the right edge of the camera notch.

**Status: v0.3.** Menu bar gauge needle + a live drop-down with animated drain
capsules per agent. The notch panel was dropped (see `Attic/`).

```bash
./scripts/bundle.sh          # unsigned .app, for local dev
```

```bash
./scripts/release.sh         # signed .app + .dmg, ready to notarise
```

```bash
./scripts/release.sh notarize   # the above, then notarise + staple
```

```bash
./.build/release/Headroom --probe
```

`--probe` prints what the providers can actually see and exits. When a vendor
changes a log format, this is the fastest way to find out what broke.

---

## What works

- **Codex quota, server-authoritative.** Read straight from
  `~/.codex/sessions/**/rollout-*.jsonl`. No network, no credentials, no API keys.
- **Claude quota, estimated.** Weighted token ledger over rolling 5h/7d windows,
  binary-searched to the cutoff — **78 ms across 128 MB**. Self-calibrates from
  observed rate-limit rejections.
- **A variable-value gauge needle** in the menu bar (`gauge.with.dots.needle`
  sweeps continuously) plus the single worst number across all agents.
- **Live drain capsules in the drop-down.** One row per agent per window, with
  the Wave Meniscus animation replaying each time the menu opens — an explicit
  user action, so the motion marks something real and costs nothing when closed.
  Solid meniscus = measured, dashed = inferred.
- **Manual calibration** against Claude's own usage page, which is the only way
  to see usage from claude.ai and the desktop app.
- **Notch-adjacent panel** at CGWindow layer 25 — the same layer Control Center's
  own items occupy. Verified in place at x=962, y=0 on a 16" MacBook Pro.
- **Wave Meniscus animation** with velocity-driven slosh and spring settle.
- **0.0% CPU idle and 0.0% during a live agent session**, ~46 MB RSS. Measured, not asserted.
- Adaptive width, live FSEvents refresh, status item fallback with menu.

## Architecture

| File | Role |
| --- | --- |
| `Model/Reading.swift` | `Reading` enum — the epistemics of a number |
| `Providers/CodexProvider.swift` | Reverse-tail parser (authoritative) |
| `Providers/ClaudeProvider.swift` | Binary-search ledger (estimated) |
| `Providers/Calibration.swift` | Learns the limit Claude never writes down |
| `Watch/FileWatcher.swift` | One shared FSEvents stream |
| `Render/DrainView.swift` | Wave Meniscus renderer |
| `Panel/GaugePanel.swift` | Borderless `NSPanel` at `.statusBar` |
| `Panel/PanelController.swift` | Placement and contested-space arbitration |

### Why `Reading` is not a `Double`

Codex hands you a server-computed percentage. Claude hands you raw token counts
and hides the denominator. Collapsing both into one `percent: Double` forces you
to invent numbers for Claude, which is how these tools end up lying. So a reading
is `.authoritative`, `.estimated` (rendered with a dashed meniscus), or
`.unavailable` — and the UI always shows which.

---

## Things learned the hard way

Each of these was a real bug found by running against live data, not a
hypothetical:

1. **Session files reach 72 MB.** Never parse forward. Reverse tail from the end
   parses in ~8 ms.
2. **Codex emits two kinds of `rate_limits`.** `limit_id: "codex"` carries the
   percentages; `limit_id: "premium"` carries credits and leaves `primary`
   **null**. Taking the last `token_count` event shows an empty gauge about half
   the time. Scan backward for the last event with a non-null `primary`.
3. **An expired `resetsAt` is worse than no data.** These logs only advance while
   Codex runs. Once the reset passes, a cached "100%" tells someone with a fresh
   window that they're blocked. Report the reset instead.
4. **`isFloatingPanel` overwrites `level`.** Assign it *before* `level`, or the
   panel silently drops from layer 25 to layer 3 — where AppKit refuses to let it
   overlap the menu bar at all.
5. **AppKit constrains windows out of the menu bar.** Override
   `constrainFrameRect(_:to:)` to return the frame unchanged.
6. **A transparent window doesn't erase itself.** Without `ctx.clear(dirtyRect)`
   the label composites onto its own ghost every frame.
7. **Every status item is owned by the `Control Center` process** — yours and
   every third-party app's. Filtering the window list by your own PID excludes
   nothing.
8. **The panel counts itself as a neighbour.** Its own layer-25 window sits in the
   strip it's measuring, so it computes negative clear space and hides one frame
   after appearing. Exclude by window number.
9. **Everything shows *remaining*, never *used*.** The capsule once filled to
   "remaining" while its label read "used" — two contradictory statements at
   once, and no way for the reader to tell which. `Reading` now exposes
   `percentUsed` and `percentRemaining` separately, and only the latter is ever
   displayed.
10. **AppKit disables menu items that have no action**, so a menu full of data
    rows renders entirely greyed out. `menu.autoenablesItems = false`.
11. **Debouncing isn't enough while an agent is running.** Its log is written
    continuously, so a 400 ms debounce still fired several times a second at
    ~75 ms per scan — measured at 17% of a core. A hard floor between scans
    (6 s) drops it to 0%. The gauge may lag a few seconds; it may not spin your fans.
12. **The strip beside the notch is contested.** macOS lays status items out
   leftward from the screen edge. On a busy menu bar there may be under 50pt free.
   The panel measures what's genuinely clear and drops the text label, then hides,
   rather than drawing over a neighbour.

## Placement: right vs left of the notch

Both strips are contested, but by different owners — and that asymmetry decides
which one to prefer:

| | Right of notch | Left of notch |
| --- | --- | --- |
| Owned by | status items | frontmost app's menus |
| Changes when | you add/remove a menu bar app | **every app switch** |
| Measurable | exactly, via the window server | only with Accessibility |
| Here | ~104pt clear | ~200pt+ clear, if measurable |

Right is preferred even when it's tighter, because it's *knowable*. Left is used
only as a fallback, and it's genuinely useful **only if Accessibility is
granted** — `AXUIElementCopyAttributeValue(kAXMenuBarAttribute)` returns
`kAXErrorAPIDisabled` (-25211) without it, leaving us to assume a 720pt menu
extent, which yields barely more room than the right strip. The app never
triggers the permission prompt on its own; the menu offers it.

## Agent support

| Agent | Source | Accuracy |
| --- | --- | --- |
| Codex | `~/.codex/sessions/**/rollout-*.jsonl` | **exact** — vendor-computed `used_percent` |
| Claude | `~/.claude/projects/**/*.jsonl` | **estimated** — token ledger ÷ learned capacity |
| Gemini | — | none: no CLI installed, and Antigravity writes no quota to disk |

Codex needs no calibration and cannot be calibrated: it reports the same
percentage the server enforces. Claude has to be calibrated because its logs
carry a numerator with no denominator.

Agents that are detected but unreadable get one explanatory line in the menu,
so an absent agent reads as "looked for, here's why" rather than as a bug.

## Distribution

`scripts/release.sh` builds, signs with Developer ID, hardens the runtime, adds a
secure timestamp and produces a drag-to-Applications `.dmg`.

Notarisation needs an App Store Connect credential in your keychain. Create it
once — it takes your Apple ID and an app-specific password from
appleid.apple.com, and nothing in this repo ever sees either:

```bash
export HEADROOM_IDENTITY="Developer ID Application: Your Name (TEAMID)"
export HEADROOM_TEAM_ID="TEAMID"
xcrun notarytool store-credentials "Headroom" --apple-id "you@example.com" --team-id "$HEADROOM_TEAM_ID"
```

Find your identity with `security find-identity -v -p codesigning`.

Then `./scripts/release.sh notarize`. Until that runs, `spctl` reports
`rejected — Unnotarized Developer ID`, which is expected.

The script notarises **twice**, deliberately: once for the `.app` before it is
wrapped, and again for the finished `.dmg`. Stapling only the DMG leaves the app
itself without a ticket, so once a teammate drags it to `/Applications` Gatekeeper
falls back to an online lookup — fine at a desk, a hang or a failure on a plane or
a restricted network. Stapling the app first makes it work offline.

**Gotcha:** Anaconda ships its own `codesign` that shadows Apple's on `PATH` and
fails with "arguments were not expected". The script calls `/usr/bin/codesign`
and friends by absolute path for exactly this reason.

## Known limitations

- **Claude's plan limit is shared with claude.ai and the desktop app.** The local
  logs only ever contain Claude Code, so anything done in the web or desktop app
  counts against the real limit and is invisible here. This is structural, not a
  bug — it's why manual calibration exists.
- **The weekly window is modelled as rolling 7 days, but Claude's is a fixed
  calendar window** (e.g. "Resets Fri 6:00 AM"). Wrong shape.
- **Temporary limit boosts distort calibration.** A capacity learned during a
  promotion expires with it.
- **Claude's capacity seed is a guess.** Anthropic doesn't publish the limit and
  Claude Code doesn't log it, so until a real rejection is observed the gauge runs
  on a placeholder constant at confidence 0.25 and renders a dashed meniscus. The
  first rejection replaces it with a measured value.
- **Calibration needs a rejection to bootstrap.** A user who never hits their
  limit never calibrates — acceptable, since they don't need the gauge, but the
  number stays a rough estimate until then.
- **Placement re-checks only on refresh**, not when a neighbour appears. There's
  no notification for status item layout changes.
