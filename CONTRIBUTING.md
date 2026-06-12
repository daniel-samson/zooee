# Contributing to Zooee

Thanks for your interest in contributing! This document describes how the project is developed.

## Branching model (git flow)

- **`main`** — releases only. Every commit on `main` is a tagged, releasable state.
- **`develop`** — integration branch. All feature work merges here first.
- **`feature/<name>`** — branched from `develop`, merged back via pull request.
- **`release/<version>`** — branched from `develop` when preparing a release; merged to `main` (tagged) and back to `develop`.
- **`hotfix/<name>`** — branched from `main` for urgent fixes; merged to both `main` and `develop`.

## Workflow

1. Pick or open an issue describing the change. For significant design work, discuss on the issue first — major design decisions are recorded as issue comments.
2. Branch from `develop`: `git checkout -b feature/my-change develop`
3. Make your changes. Match the existing code style; `zig fmt` is enforced by CI.
4. Add or update tests. All backends are test-driven: terminal output is snapshot-tested, graphical output is verified by offscreen golden-image comparison.
5. Open a pull request against `develop`. CI must pass.

## CI

- **Tier 1** (GitHub-hosted): runs on every PR — format check, build, and tests across Linux, macOS, and Windows.
- **Tier 2** (self-hosted): runs on pushes to `main`/`develop` — real-platform windowing and rendering tests. These do not run on fork PRs.

## Requirements

- Zig 0.16.0 or newer
- No third-party runtime dependencies — part of the project's sub-2MB binary budget. Think twice (and open an issue) before proposing one.

## Commit messages

Imperative mood, concise subject line ("Add terminal cell buffer", not "Added…"). Reference issues where relevant ("…(#7)").
