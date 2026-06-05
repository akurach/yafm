# Feature requests (someday backlog)

Full specs for features that are **not in active development yet** — parked here so
[`ROADMAP.md`](../../ROADMAP.md) stays lean. The roadmap links to these from its
"Someday / backlog" section.

Each file is one self-contained spec: goal, MVP scope, explicit non-goals, architecture,
acceptance criteria. When a feature is picked up, add a short item to the active roadmap
milestone; the detailed spec stays here as the source of truth.

All feature requests were triaged and **closed 2026-06-05** — none are left in an
ambiguous "someday" state. Each row records the decision; the detailed specs stay
as the source of truth.

| File | Feature | Status |
|------|---------|--------|
| [app-shell.md](app-shell.md) | Settings · About · auto-updater · theme (light/dark/system) | ✅ shipped (v0.2.3) |
| [device-detection.md](device-detection.md) | Device Detection & Classification — metadata + device-type/read-only/transport for mounted volumes | ⏸ deferred → post-1.0 |
| [photo-ingest.md](photo-ingest.md) | Photo Ingest — import from camera cards (SD/CFexpress/USB) | ⏸ deferred → post-1.0 (needs device detection) |
