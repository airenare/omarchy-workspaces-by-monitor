# Workspaces by Monitor

An [Omarchy](https://omarchy.org/) shell plugin. A drop-in replacement for
the stock `omarchy.workspaces` bar widget that groups workspace numbers by
monitor, colors each group from the active theme's palette, and draws a
frame around the focused workspace.

A gear icon at the end of the widget opens a settings popup for configuring
everything below — no manual `shell.json` editing needed for day-to-day
changes.

## Using the settings popup

Click the gear icon next to the workspace numbers. Each row configures one
monitor:

- **Monitor** — a dropdown of currently connected outputs (plus whatever
  monitor a row is already set to, even if it's not connected right now).
- **Workspaces** — which workspace numbers belong to that monitor. Accepts
  a comma list (`1,2,3`), a range (`1-5`), a mix (`1-3,7`), or `*` meaning
  "every workspace 1-10 not claimed by another row" — so one monitor can
  pin a handful of workspaces while another picks up everything left over.
- **Color** — a row of clickable swatches, one per color key the active
  theme's `colors.toml` defines, each shown in its actual color. Click one
  to select it; leave "Auto" selected (the "?" swatch) to get a color from
  a built-in rotation instead.

**Add monitor** appends a new row, **Save** writes the groups to this
widget's `shell.json` layout entry, regenerates the matching
`hl.workspace_rule()` pins in `~/.config/hypr/monitors.lua` (see below) and
reloads Hyprland, then closes the popup. **Cancel**, the gear icon, or
clicking outside the popup all close it without saving.

### Bar display vs. actual workspace pinning

The groups above only ever controlled what this bar widget *shows* — they
don't, by themselves, change which monitor `Super+N` actually activates.
That's a separate Hyprland mechanism (`hl.workspace_rule()` in
`~/.config/hypr/monitors.lua`), so the two could silently drift apart:
recoloring workspace 5 into a different monitor's group here did nothing to
where `Super+5` actually goes.

Save now closes that gap itself: it also rewrites the block between these
two marker comments in `~/.config/hypr/monitors.lua` to match, and runs
`hyprctl reload`:

```lua
-- air.workspaces: BEGIN auto-generated workspace pins
...
-- air.workspaces: END auto-generated workspace pins
```

Anything outside those markers (your `hl.monitor()` blocks, other config) is
left alone. If you hand-edit inside the markers, the next Save overwrites
it — change groups from the gear icon instead.

## Configuring monitor groups by hand

Everything the popup writes lives in the `groups` array on this widget's
`shell.json` layout entry, so it's also fine to edit directly. Example (2
monitors, 5 workspaces each):

```json
{
  "id": "air.workspaces",
  "groups": [
    { "monitor": "DP-1", "ids": [1, 2, 3, 4, 5], "colorKey": "red" },
    { "monitor": "DP-2", "ids": "*", "colorKey": "yellow" }
  ]
}
```

- `monitor` — the output name as Hyprland/Wayland reports it. Find yours
  with `hyprctl monitors | grep Monitor`.
- `ids` — an array of workspace numbers, or the string `"*"` for "every
  workspace 1-10 not explicitly claimed by another group."
- `colorKey` — a key from the active theme's `colors.toml` (e.g. `red`,
  `yellow`, `green`, `blue`). Optional — omit it and the group gets a color
  from a built-in rotation instead.

With no `groups` setting at all, every monitor shows workspaces 1-10 as one
ungrouped range (the original `omarchy.workspaces` behavior). A monitor name
not listed in any group falls back to showing the union of all configured
workspace ids, rather than an empty bar.

## Install on another machine

1. Copy this whole directory to `~/.config/omarchy/plugins/<username>.workspaces/`
   (Omarchy plugin ids are `<username>.<name>`; rename the `id` fields in
   `manifest.json` to match if you use a different directory name).
2. In `~/.config/omarchy/shell.json`, point the `left`/`center`/`right` bar
   layout at it (e.g. replace `omarchy.workspaces` with `<username>.workspaces`).
3. Add the two marker comments (see above) somewhere in
   `~/.config/hypr/monitors.lua` — anywhere between them is fair game for
   Save to rewrite, so put them where you'd otherwise hand-write
   `hl.workspace_rule()` calls. Without the markers present, Save just skips
   the Hyprland-pin step (the bar's own display still updates fine).
4. Save the shell config — it hot-reloads plugins and `shell.json`
   automatically. Use the gear icon (or hand-edit `groups`, above) to
   configure it.
