# Lucide icons

The complete [Lucide](https://lucide.dev) set (v1.21.0) is baked into
**`src/lucide.zig`** — that generated Zig file is the committed artifact. The
raw SVGs are *not* vendored (1.7k files); `LICENSE` here covers the baked data
(Lucide ISC + Feather MIT).

The app consumes icons two ways:

- **Curated, shipped set** — the SVGs in the top-level `icons/` directory get
  flattened into `src/generated_icons.zig` and are always available via
  `Ui.icon`. Keep this set small (size-budget note in `tools/svg2icons.zig`).
- **Full set** — `src/lucide.zig`, one `pub const` per icon, so an app that
  names a few (`lucide.house`) compiles in only those. See `src/root.zig`.

## Regenerate `src/lucide.zig` (e.g. to bump the version)

```sh
tools/fetch-lucide.sh        # download the SVG pool → assets/lucide/icons/ (gitignored)
zig build gen-lucide         # rebake src/lucide.zig
```

To bump the version, edit `version` in `tools/fetch-lucide.sh`, refresh this
`LICENSE`, then run the two commands above.

## Add an icon to the curated, shipped set

```sh
tools/add-icon.sh chevron-down star    # auto-fetches the pool if needed
zig build gen-icons                     # regenerate src/generated_icons.zig
```

Then reference it by its sanitized name (`chevron-down` → `.chevron_down`)
through `Ui.icon`.
