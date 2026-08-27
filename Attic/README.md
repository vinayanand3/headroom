# Attic

Working, verified code that the current design doesn't use. Not compiled
(SwiftPM only builds `Sources/`). Kept because it all ran correctly — the
capsule was dropped for design reasons, not because it was broken.

- `DrainView.swift` — Wave Meniscus renderer, stacked one row per agent.
  Velocity-driven slosh, spring settle, solid vs dashed meniscus for
  measured vs inferred. Verified at 0.0% CPU idle.
- `Tone.swift` — semantic colour ramp.
- `GaugePanel.swift` — borderless NSPanel at layer 25 (peer of Control Center).
  Contains the `isFloatingPanel`-before-`level` ordering fix and the
  `constrainFrameRect` override.
- `PanelController.swift` — notch placement, contested-space arbitration
  against other status items, left-of-notch fallback with AX measurement.

Why dropped: the capsule doesn't scale past ~3 agents (five agents = five 5pt
bars), and a fill bar next to a number invites "is that used or left?".
