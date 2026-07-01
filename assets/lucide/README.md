# Lucide icons

The complete [Lucide](https://lucide.dev) set (v1.21.0) is baked into
**`src/lucide.zig`** — that generated Zig file is the committed artifact. The
raw SVGs are *not* vendored (1.7k files); `LICENSE` here covers the baked data
(Lucide ISC + Feather MIT).

The app consumes icons two ways (#346 — `src/lucide.zig` is the single source):

- **Curated set** — `ui.IconName` in `src/ui.zig` maps a small enum to
  `lucide.<name>` consts via `curatedIcon`, available through `Ui.icon`. Zig's
  lazy decls mean only those icons compile into size-budgeted builds. To add
  one: add an enum case + switch arm.
- **Full set** — `src/lucide.zig`, one `pub const` per icon, so an app that
  names a few (`lucide.house`) compiles in only those, via `Ui.iconData`.
  See `src/root.zig`.

## Regenerate `src/lucide.zig` (e.g. to bump the version)

```sh
tools/fetch-lucide.sh        # download the SVG pool → assets/lucide/icons/ (gitignored)
zig build gen-lucide         # rebake src/lucide.zig
```

To bump the version, edit `version` in `tools/fetch-lucide.sh`, refresh this
`LICENSE`, then run the two commands above.

## Add an icon to the curated set

Add its sanitized name (`chevron-down` → `chevron_down`) as an `IconName` enum
case + `curatedIcon` switch arm in `src/ui.zig`, pointing at the existing
`lucide.chevron_down` const. No fetch or regeneration needed — the full set is
already baked.
