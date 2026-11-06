import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Hyprland
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "omarchy.workspaces"

  // The id this widget's shell.json layout entry is registered under
  // (manifest.json's "id"). Settings writes must target this, not
  // `moduleName` above (kept as "omarchy.workspaces" for Hyprland/IPC
  // identity) — see manifest.json and updateEntryInline() in shell.qml.
  readonly property string settingsId: "air.workspaces"

  // ------------------------------------------------------------------ schemes
  //
  // "classic"     — the original Hyprland model: one global set of workspaces
  //                 1-10. Super+N goes to workspace N, Super+Shift+N moves the
  //                 window there, and `groups` (below) pins workspaces to
  //                 monitors.
  // "per-monitor" — Omarchy's own per-monitor model: every monitor has
  //                 workspaces 1-10 of its own (Hyprland numbers them in a
  //                 block of ten per monitor), and Super+N means "the Nth
  //                 workspace of the monitor I'm on".
  //
  // The scheme is a Hyprland-side choice as much as a bar one: Save rewrites
  // the managed block in ~/.config/hypr/monitors.lua (see "Hyprland sync"
  // below) so the key bindings and Omarchy's workspace manager follow it.
  readonly property string scheme: root.setting("scheme", "classic") === "per-monitor" ? "per-monitor" : "classic"
  readonly property bool perMonitor: root.scheme === "per-monitor"

  // Per-monitor workspace groups for the classic scheme, configured via the
  // gear icon's settings popup below (persisted into this widget's shell.json
  // layout entry) — see README.md for the on-disk shape. e.g.:
  //   { "id": "air.workspaces", "scheme": "classic", "groups": [
  //       { "monitor": "DP-1", "ids": [1,2,3,4,5], "colorKey": "red" },
  //       { "monitor": "DP-2", "ids": "*", "colorKey": "yellow" }
  //   ] }
  // `ids` is either an explicit array of workspace numbers, or "*" meaning
  // "every workspace 1-10 not explicitly claimed by another group". With no
  // "groups" setting, every monitor shows workspaces 1-10 as one ungrouped
  // range.
  readonly property var defaultColorKeys: ["red", "yellow", "green", "blue", "magenta", "cyan"]
  readonly property var groups: root.setting("groups", [])

  // Number colors in the per-monitor scheme: { "DP-1": "red", "DP-2": "#ff8800" }.
  // A value is a key from the theme's colors.toml, or a "#rrggbb" color.
  readonly property var monitorColors: root.setting("monitorColors", {})

  // Color of the frame around the focused workspace. Empty means "same as that
  // workspace's number color".
  readonly property string frameColorKey: String(root.setting("frameColor", ""))

  // `root.bar` is one shared object across every monitor's bar surface, so
  // it can't tell us which screen this widget instance is on. QtQuick's
  // plain `Screen` attached property doesn't resolve correctly inside
  // Quickshell's layer-shell PanelWindow surfaces either. `QsWindow.window
  // .screen` (used the same way elsewhere in this shell, e.g. Bar.qml's
  // tooltip anchoring) is the reliable path to this item's actual hosting
  // screen.
  function screenName() {
    var win = root.QsWindow ? root.QsWindow.window : null
    return win && win.screen ? String(win.screen.name || "") : ""
  }

  readonly property var monitor: {
    var win = root.QsWindow ? root.QsWindow.window : null
    var screen = win ? win.screen : null
    return screen ? Hyprland.monitorFor(screen) : Hyprland.focusedMonitor
  }
  readonly property string monitorName: root.monitor ? root.monitor.name : root.screenName()

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  // ---------------------------------------------------------- classic: groups

  function groupForScreen() {
    var name = root.screenName()
    for (var i = 0; i < root.groups.length; i++) {
      if (root.groups[i].monitor === name) return root.groups[i]
    }
    return null
  }

  // Every workspace number explicitly claimed by a non-wildcard group,
  // across all configured groups — used to compute what a "*" group means.
  function explicitIdsUnion() {
    var ids = []
    for (var i = 0; i < root.groups.length; i++) {
      var g = root.groups[i]
      if (g.ids === "*" || !g.ids) continue
      for (var j = 0; j < g.ids.length; j++) {
        if (ids.indexOf(g.ids[j]) === -1) ids.push(g.ids[j])
      }
    }
    return ids
  }

  function remainderIds() {
    var claimed = root.explicitIdsUnion()
    var result = []
    for (var n = 1; n <= 10; n++) {
      if (claimed.indexOf(n) === -1) result.push(n)
    }
    return result
  }

  function groupIdsResolved(group) {
    if (!group || !group.ids) return []
    if (group.ids === "*") return root.remainderIds()
    return group.ids.slice()
  }

  function baseIdsForScreen() {
    var group = root.groupForScreen()
    if (group) return root.groupIdsResolved(group)
    if (root.groups.length === 0) return [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]

    // Screen isn't listed in any configured group: show the union of every
    // configured group instead of leaving this monitor's bar empty.
    var ids = []
    for (var i = 0; i < root.groups.length; i++) {
      var groupIds = root.groupIdsResolved(root.groups[i])
      for (var j = 0; j < groupIds.length; j++) {
        if (ids.indexOf(groupIds[j]) === -1) ids.push(groupIds[j])
      }
    }
    return ids
  }

  function classicWorkspaceIds() {
    var ids = root.baseIdsForScreen()
    var values = Hyprland.workspaces.values

    // Workspaces outside the configured range (say a stray 12) are listed too,
    // but one that another monitor's group claims stays off this bar.
    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && ids.indexOf(id) === -1 && root.groupIndexForWorkspace(id) === -1) ids.push(id)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function groupIndexForWorkspace(id) {
    for (var i = 0; i < root.groups.length; i++) {
      if (root.groupIdsResolved(root.groups[i]).indexOf(id) !== -1) return i
    }
    return -1
  }

  // ------------------------------------------------------- per-monitor: blocks
  //
  // Hyprland numbers every monitor's workspaces in a block of ten — 1-10 for
  // the first monitor, 11-20 for the next, and so on. Omarchy records which
  // monitor owns which block in a state file; each bar shows its own block,
  // labelled 1-10.
  readonly property int slots: 10

  function blockOf(id) { return Math.floor((id - 1) / root.slots) }
  function slotOf(id) { return (id - 1) % root.slots + 1 }

  // Connector -> block, from the file Omarchy keeps them in.
  property var blocks: ({})

  function readBlocks(raw) {
    var next = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var fields = lines[i].split("\t")
      if (fields.length >= 3 && fields[1] !== "") next[fields[1]] = parseInt(fields[0], 10)
    }
    root.blocks = next
  }

  FileView {
    path: (Quickshell.env("XDG_STATE_HOME") || Quickshell.env("HOME") + "/.local/state") + "/omarchy/monitor-workspaces"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.readBlocks(text())
    onLoadFailed: root.readBlocks("")
  }

  function activeWorkspaceId() {
    return root.monitor && root.monitor.activeWorkspace ? root.monitor.activeWorkspace.id : -1
  }

  // Until Omarchy has written the file, the workspace a monitor shows is in
  // its own block.
  readonly property int block: {
    var known = root.blocks[root.monitorName]
    if (known !== undefined) return known
    var active = root.activeWorkspaceId()
    return active > 0 ? root.blockOf(active) : 0
  }

  // The first five of the monitor's own, and any of the rest that exist. After
  // them come workspaces that are only visiting: those of a monitor that is
  // unplugged, which had no room to join this one's.
  function perMonitorWorkspaceIds() {
    var base = root.block * root.slots
    var ids = [base + 1, base + 2, base + 3, base + 4, base + 5]
    var guests = []
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id <= 0) continue
      if (root.blockOf(id) === root.block) {
        if (ids.indexOf(id) === -1) ids.push(id)
      } else if (values[i].monitor && values[i].monitor.name === root.monitorName) {
        guests.push(id)
      }
    }

    ids.sort(function(left, right) { return left - right })
    guests.sort(function(left, right) { return left - right })
    return ids.concat(guests)
  }

  // Quickshell credits every workspace switch to the focused monitor, as the
  // event doesn't say which one switched, and misses the workspace a monitor
  // falls back to when its own is moved away — so in this scheme, where every
  // monitor shows a workspace of its own, ask Hyprland for the truth.
  Connections {
    target: Hyprland
    enabled: root.perMonitor
    function onRawEvent(event) {
      var name = event ? String(event.name) : ""
      var switched = name === "workspacev2" && root.monitor !== null && root.monitor.focused
      if (switched || name === "moveworkspacev2" || name === "changeworkspaceid") {
        Hyprland.refreshMonitors()
        Hyprland.refreshWorkspaces()
      }
    }
  }

  // --------------------------------------------------------- shared by both

  function workspaceIds() {
    return root.perMonitor ? root.perMonitorWorkspaceIds() : root.classicWorkspaceIds()
  }

  function dispatch(expression) {
    if (root.bar) root.bar.run("hyprctl dispatch " + Util.shellQuote(expression))
  }

  function focusWorkspace(id) {
    if (root.perMonitor && root.blockOf(id) === root.block) {
      root.dispatch("o.workspaces.focus(" + root.slotOf(id) + ", \"" + root.monitorName + "\")")
    } else {
      root.dispatch("hl.dsp.focus({ workspace = \"" + id + "\" })")
    }
  }

  // The label of a workspace: its global number in the classic scheme, its
  // position within the monitor's block in the per-monitor one.
  function labelFor(id) {
    var n = root.perMonitor ? root.slotOf(id) : id
    return n === 10 ? "0" : String(n)
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  // Raw theme palette, read from the active theme's colors.toml (the same
  // file terminals/other apps pick up) so colors follow theme switches
  // instead of being hardcoded to one theme's hex values.
  property var palette: ({})

  FileView {
    id: themeColorsFile
    path: Quickshell.env("HOME") + "/.local/state/omarchy/current/theme/colors.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: root.palette = root.parseThemeColors(text())
  }

  function parseThemeColors(raw) {
    var result = {}
    var lines = String(raw || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var match = lines[i].match(/^\s*([A-Za-z0-9_-]+)\s*=\s*["']?(#[0-9A-Fa-f]{6})/)
      if (match) result[match[1]] = match[2]
    }
    return result
  }

  function isHexColor(value) {
    return /^#[0-9a-fA-F]{6}$/.test(String(value || ""))
  }

  // Resolves a color choice to an actual color: a "#rrggbb" value as is, a
  // palette key from colors.toml if the theme defines it, else a rotating
  // default by `index`, else Color.urgent/Color.accent.
  function colorForKeyOrIndex(key, index) {
    if (root.isHexColor(key)) return String(key)
    var count = root.defaultColorKeys.length
    var k = key || root.defaultColorKeys[((index % count) + count) % count]
    return root.palette[k] || (index === 0 ? Color.urgent : Color.accent)
  }

  function colorForGroupIndex(index) {
    var group = index >= 0 && index < root.groups.length ? root.groups[index] : null
    return root.colorForKeyOrIndex(group ? group.colorKey : "", index)
  }

  // The number color of a workspace on this bar.
  function numberColorFor(id) {
    if (root.perMonitor) return root.colorForKeyOrIndex(root.monitorColors[root.monitorName] || "", root.block)
    return root.colorForGroupIndex(root.groupIndexForWorkspace(id))
  }

  function frameColorFor(id) {
    return root.frameColorKey ? root.colorForKeyOrIndex(root.frameColorKey, 0) : root.numberColorFor(id)
  }

  // The workspace that gets the frame: the one focused anywhere in the classic
  // scheme, the one this monitor shows in the per-monitor scheme (every
  // monitor shows one of its own).
  function isMarked(id) {
    if (root.perMonitor) return root.activeWorkspaceId() === id
    return Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === id
  }

  // ---------------------------------------------------------------- settings

  // Edited as ListModels, not plain JS arrays: setProperty() below updates
  // a row's fields in place, so the Repeater's delegates (and their
  // TextFields) are never destroyed and recreated while typing. Reassigning
  // a plain-array property on every keystroke was doing exactly that, which
  // is why a TextField used to lose focus and its cursor position after
  // every single character (and sometimes fail to focus at all, if a click
  // landed mid-rebuild).
  property bool settingsOpen: false
  property string editScheme: "classic"
  property string editFrameColor: ""
  ListModel { id: editGroupsModel }   // classic: monitor, idsText, colorKey
  ListModel { id: editMonitorsModel } // per-monitor: monitor, colorKey

  function idsToText(ids) {
    if (ids === "*" || !ids) return ids === "*" ? "*" : ""
    return ids.join(",")
  }

  function parseIdsText(text) {
    var trimmed = String(text || "").trim()
    if (trimmed === "" || trimmed === "*") return "*"
    var ids = []
    var parts = trimmed.split(",")
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i].trim()
      if (part === "") continue
      var rangeMatch = part.match(/^(\d+)\s*-\s*(\d+)$/)
      if (rangeMatch) {
        var start = parseInt(rangeMatch[1], 10)
        var end = parseInt(rangeMatch[2], 10)
        if (start > end) { var t = start; start = end; end = t }
        for (var n = start; n <= end; n++) {
          if (ids.indexOf(n) === -1) ids.push(n)
        }
      } else {
        var num = parseInt(part, 10)
        if (isFinite(num) && ids.indexOf(num) === -1) ids.push(num)
      }
    }
    ids.sort(function(a, b) { return a - b })
    return ids
  }

  // Same parsing as parseIdsText, but keeps every occurrence instead of
  // deduping — so "1,2,2" reports workspace 2 twice, which is exactly what
  // the duplicate-workspace validation below needs to catch a number typed
  // twice into one field, not just the same number across two fields.
  function rawIdOccurrences(text) {
    var trimmed = String(text || "").trim()
    if (trimmed === "" || trimmed === "*") return []
    var ids = []
    var parts = trimmed.split(",")
    for (var i = 0; i < parts.length; i++) {
      var part = parts[i].trim()
      if (part === "") continue
      var rangeMatch = part.match(/^(\d+)\s*-\s*(\d+)$/)
      if (rangeMatch) {
        var start = parseInt(rangeMatch[1], 10)
        var end = parseInt(rangeMatch[2], 10)
        if (start > end) { var t = start; start = end; end = t }
        for (var n = start; n <= end; n++) ids.push(n)
      } else {
        var num = parseInt(part, 10)
        if (isFinite(num)) ids.push(num)
      }
    }
    return ids
  }

  // The color a monitor gets in the per-monitor scheme before the user picks
  // one: whatever it had in the classic scheme, so switching keeps the look.
  function carriedColorKey(monitor) {
    if (root.monitorColors[monitor] !== undefined) return String(root.monitorColors[monitor])
    for (var i = 0; i < root.groups.length; i++) {
      if (root.groups[i].monitor === monitor) return String(root.groups[i].colorKey || "")
    }
    return ""
  }

  function openSettings() {
    editGroupsModel.clear()
    for (var i = 0; i < root.groups.length; i++) {
      var g = root.groups[i]
      editGroupsModel.append({ monitor: String(g.monitor || ""), idsText: root.idsToText(g.ids), colorKey: String(g.colorKey || "") })
    }

    editMonitorsModel.clear()
    var screens = Quickshell.screens
    for (var j = 0; j < screens.length; j++) {
      editMonitorsModel.append({ monitor: screens[j].name, colorKey: root.carriedColorKey(screens[j].name) })
    }

    root.editScheme = root.scheme
    root.editFrameColor = root.frameColorKey
    root.settingsOpen = true
    root.bumpEditGroupsVersion()
  }

  function closeSettings() {
    root.settingsOpen = false
    // Belt-and-suspenders: force-release the bar's "this widget has an open
    // panel" tracking directly, independent of whatever state PopupCard's
    // own onOpenChanged handler ends up in after a compositor-driven
    // dismiss (see settingsPopup.onVisibleChanged below). Redundant on a
    // normal close; harmless either way.
    if (root.bar && root.bar.activePopout === root && root.bar.releasePopout) {
      root.bar.releasePopout(root)
    }
  }

  // PopupCard's own close() falls back to imperatively setting its *own*
  // `open` property when its `owner` (root, here) has no `close` method —
  // and assigning a value to a property that has a declarative binding
  // (our `open: root.settingsOpen` below) permanently severs that binding.
  // Once severed, toggling settingsOpen no longer does anything to the
  // popup at all — "click the gear, nothing happens," permanently, since
  // it only takes one such close (outside click, Escape, a focus-grab
  // clear) to break it. Defining close() here — matching the contract
  // PopupCard's `owner` expects — keeps the binding intact by routing every
  // close through settingsOpen instead.
  function close() {
    root.closeSettings()
  }

  function toggleSettings() {
    if (root.settingsOpen) root.closeSettings()
    else root.openSettings()
  }

  function firstUnusedScreenName() {
    var used = {}
    for (var i = 0; i < editGroupsModel.count; i++) used[editGroupsModel.get(i).monitor] = true
    var screens = Quickshell.screens
    for (var j = 0; j < screens.length; j++) {
      if (!used[screens[j].name]) return screens[j].name
    }
    return screens.length > 0 ? screens[0].name : ""
  }

  function addEditGroup() {
    editGroupsModel.append({ monitor: root.firstUnusedScreenName(), idsText: "", colorKey: "" })
    root.bumpEditGroupsVersion()
  }

  function removeEditGroup(index) {
    editGroupsModel.remove(index)
    root.bumpEditGroupsVersion()
  }

  function setEditScheme(value) {
    root.editScheme = value
    root.bumpEditGroupsVersion()
  }

  function saveSettings() {
    if (!root.bar || !root.bar.shell) return
    if (root.editScheme === "classic" && root.hasDuplicateWorkspaces) return

    var groupsOut = []
    for (var i = 0; i < editGroupsModel.count; i++) {
      var g = editGroupsModel.get(i)
      if (!g.monitor) continue
      groupsOut.push({ monitor: g.monitor, ids: root.parseIdsText(g.idsText), colorKey: g.colorKey || "" })
    }

    // Colors of monitors that aren't plugged in right now are kept.
    var colorsOut = {}
    var previous = root.monitorColors
    for (var name in previous) colorsOut[name] = previous[name]
    for (var j = 0; j < editMonitorsModel.count; j++) {
      var row = editMonitorsModel.get(j)
      if (row.colorKey) colorsOut[row.monitor] = row.colorKey
      else delete colorsOut[row.monitor]
    }

    // updateEntryInline replaces the entry's settings wholesale, so every
    // setting is written each time. `groups` is kept even in the per-monitor
    // scheme (it just isn't shown), so switching back restores it.
    var settings = { scheme: root.editScheme, groups: groupsOut, monitorColors: colorsOut }
    if (root.editFrameColor) settings.frameColor = root.editFrameColor
    root.bar.shell.updateEntryInline(root.settingsId, settings)
    root.syncHyprland(root.editScheme, groupsOut)
    root.closeSettings()
  }

  // ------------------------------------------------ duplicate-id validation
  //
  // Two monitors both claiming workspace N is a real misconfiguration (only
  // one monitor can actually own a workspace in Hyprland), so it's caught
  // and blocked here rather than silently saved. ListModel row edits
  // (setProperty/append/remove) don't make ordinary property bindings
  // reactive the way a plain `property var` array would — editGroupsVersion
  // is bumped on every edit so the bindings below (which read it purely to
  // establish that dependency) re-evaluate against fresh ListModel data.
  // Only the classic scheme has workspace assignments to validate.
  property int editGroupsVersion: 0
  function bumpEditGroupsVersion() { root.editGroupsVersion++ }

  function editGroupsSnapshot() {
    var snapshot = []
    for (var i = 0; i < editGroupsModel.count; i++) {
      var g = editGroupsModel.get(i)
      snapshot.push({ monitor: g.monitor, ids: root.parseIdsText(g.idsText) })
    }
    return snapshot
  }

  // Counts every occurrence of every workspace id across the whole form —
  // raw (non-deduped) occurrences for explicit rows, so "1,2,2" flags 2 on
  // its own, plus resolved ids for "*" rows (deduped there, since a
  // wildcard's resolved set is derived, not literally typed twice). An id
  // with count > 1 is a duplicate, covering both "typed twice in one field"
  // and "assigned to two different monitors" the same way.
  readonly property var duplicateWorkspaceIds: {
    root.editGroupsVersion // dependency only
    var snapshot = root.editGroupsSnapshot()
    var counts = {}
    for (var i = 0; i < editGroupsModel.count; i++) {
      var g = editGroupsModel.get(i)
      var raw = root.rawIdOccurrences(g.idsText)
      for (var j = 0; j < raw.length; j++) counts[raw[j]] = (counts[raw[j]] || 0) + 1
    }
    for (var k = 0; k < snapshot.length; k++) {
      if (snapshot[k].ids !== "*") continue
      var resolved = root.resolveIdsAgainst(snapshot, snapshot[k])
      for (var m = 0; m < resolved.length; m++) counts[resolved[m]] = (counts[resolved[m]] || 0) + 1
    }
    var dupes = []
    for (var id in counts) if (counts[id] > 1) dupes.push(parseInt(id, 10))
    dupes.sort(function(a, b) { return a - b })
    return dupes
  }

  readonly property bool hasDuplicateWorkspaces: root.duplicateWorkspaceIds.length > 0
  readonly property bool saveBlocked: root.editScheme === "classic" && root.hasDuplicateWorkspaces

  function rowHasDuplicateWorkspace(index) {
    root.editGroupsVersion // dependency only
    if (index < 0 || index >= editGroupsModel.count) return false
    var g = editGroupsModel.get(index)
    var ids = g.idsText.trim() === "*" || g.idsText.trim() === ""
      ? root.resolveIdsAgainst(root.editGroupsSnapshot(), { monitor: g.monitor, ids: root.parseIdsText(g.idsText) })
      : root.rawIdOccurrences(g.idsText)
    var dupes = root.duplicateWorkspaceIds
    for (var i = 0; i < ids.length; i++) if (dupes.indexOf(ids[i]) !== -1) return true
    return false
  }

  // ------------------------------------------- disconnected-monitor warning
  //
  // A saved monitor name that isn't currently connected is often a real
  // problem (a typo, or a name left over from before a cable/port change)
  // but sometimes isn't (an external monitor that's just unplugged right
  // now, with its config worth keeping for next time) — so this warns
  // rather than blocking Save the way duplicate workspace ids do.
  function connectedMonitorNames() {
    var screens = Quickshell.screens
    var names = []
    for (var i = 0; i < screens.length; i++) names.push(screens[i].name)
    return names
  }

  function rowMonitorDisconnected(index) {
    root.editGroupsVersion // dependency only
    if (index < 0 || index >= editGroupsModel.count) return false
    var monitor = editGroupsModel.get(index).monitor
    if (!monitor) return false
    return root.connectedMonitorNames().indexOf(monitor) === -1
  }

  readonly property var disconnectedMonitors: {
    root.editGroupsVersion // dependency only
    var connected = root.connectedMonitorNames()
    var names = []
    for (var i = 0; i < editGroupsModel.count; i++) {
      var monitor = editGroupsModel.get(i).monitor
      if (monitor && connected.indexOf(monitor) === -1 && names.indexOf(monitor) === -1) names.push(monitor)
    }
    return names
  }

  // ---------------------------------------------------------- Hyprland sync
  //
  // What the bar shows is only half of a scheme; the other half is Hyprland:
  // which monitor a workspace lives on, what Super+N does, and whether
  // Omarchy's workspace manager renumbers things into per-monitor blocks. All
  // of that is written into one managed block in ~/.config/hypr/monitors.lua
  // (loaded after Omarchy's defaults, so it can override them), between two
  // sentinel comments. Everything outside the markers (hl.monitor() blocks,
  // other config) is left untouched, and Save replaces the block between the
  // same markers each time. If the markers aren't there yet, Save appends
  // them at the end of the file.
  //
  //   classic      — workspace_rule pins for the groups, plain Super+N /
  //                  Super+Shift+N / Super+Shift+Alt+N bindings and plain
  //                  workspace-to-monitor moves, Omarchy's per-monitor
  //                  renumbering switched off, and any stray block-numbered
  //                  workspace (11+) folded back onto a pinned number.
  //   per-monitor  — nothing at all: Omarchy's own bindings and workspace
  //                  manager run untouched, and no pins are left behind.

  readonly property string hyprPinsBeginMarker: "-- air.workspaces: BEGIN auto-generated workspace pins"
  readonly property string hyprPinsEndMarker: "-- air.workspaces: END auto-generated workspace pins"

  FileView {
    id: hyprMonitorsFile
    path: Quickshell.env("HOME") + "/.config/hypr/monitors.lua"
    printErrors: false
  }

  Process {
    id: hyprReloadProcess
    command: ["hyprctl", "reload"]
  }

  // FileView.setText writes asynchronously; reloading in the same tick can
  // make Hyprland read monitors.lua before the new block is on disk, leaving
  // the previous scheme in force. Give the write a moment to land.
  Timer {
    id: hyprReloadTimer
    interval: 500
    onTriggered: hyprReloadProcess.running = true
  }

  // Resolves one group's workspace ids against a specific groups list (not
  // root.groups — at save time the new list hasn't round-tripped through
  // shell.json yet, so "*" wildcards must resolve against what's being
  // saved, not the still-stale live settings).
  function resolveIdsAgainst(groupsList, group) {
    if (!group || !group.ids) return []
    if (group.ids !== "*") return group.ids.slice()
    var claimed = []
    for (var i = 0; i < groupsList.length; i++) {
      var g = groupsList[i]
      if (g.ids === "*" || !g.ids) continue
      for (var j = 0; j < g.ids.length; j++) {
        if (claimed.indexOf(g.ids[j]) === -1) claimed.push(g.ids[j])
      }
    }
    var result = []
    for (var n = 1; n <= 10; n++) {
      if (claimed.indexOf(n) === -1) result.push(n)
    }
    return result
  }

  // The Lua that makes Hyprland behave the classic way. `homes` is the
  // monitor -> pinned workspace ids table the stray-workspace fold uses.
  function classicLua(groupsList) {
    var homes = []
    for (var i = 0; i < groupsList.length; i++) {
      var g = groupsList[i]
      if (!g.monitor) continue
      homes.push('  ["' + g.monitor + '"] = { ' + root.resolveIdsAgainst(groupsList, g).join(", ") + ' },')
    }

    return [
      '-- Omarchy 3.4 numbers workspaces per monitor (monitor two gets 11-20, ...) and',
      '-- renumbers them whenever a monitor or the config changes. Switch that off:',
      '-- workspaces keep their plain numbers, and the pins above say which monitor',
      '-- shows which.',
      'o.workspaces.reconcile = function() end',
      '',
      'for n = 1, 10 do',
      '  local key = "code:" .. (n + 9)',
      '  o.rebind("SUPER + " .. key, "Switch to workspace " .. n, hl.dsp.focus({ workspace = tostring(n) }))',
      '  o.rebind("SUPER + SHIFT + " .. key, "Move window to workspace " .. n, hl.dsp.window.move({ workspace = tostring(n) }))',
      '  o.rebind("SUPER + SHIFT + ALT + " .. key, "Move window silently to workspace " .. n, hl.dsp.window.move({ workspace = tostring(n), follow = false }))',
      'end',
      '',
      'local function workspace_to_monitor(direction)',
      '  return function()',
      '    local target = hl.get_monitor(direction)',
      '    if target then',
      '      hl.dispatch(hl.dsp.workspace.move({ monitor = target.name }))',
      '    end',
      '  end',
      'end',
      'o.rebind("SUPER + SHIFT + ALT + LEFT", "Move workspace to left monitor", workspace_to_monitor("l"))',
      'o.rebind("SUPER + SHIFT + ALT + RIGHT", "Move workspace to right monitor", workspace_to_monitor("r"))',
      'o.rebind("SUPER + SHIFT + ALT + UP", "Move workspace to up monitor", workspace_to_monitor("u"))',
      'o.rebind("SUPER + SHIFT + ALT + DOWN", "Move workspace to down monitor", workspace_to_monitor("d"))',
      '',
      '-- Coming from the per-monitor scheme, workspaces sit on 11+. Give each one a',
      '-- free pinned number of the monitor it is on.',
      'local homes = {',
      homes.join("\n"),
      '}',
      'hl.on("config.reloaded", function()',
      '  for _, workspace in ipairs(hl.get_workspaces()) do',
      '    local pinned = workspace.monitor and homes[workspace.monitor.name]',
      '    if pinned and workspace.id > 10 and not workspace.special then',
      '      for _, id in ipairs(pinned) do',
      '        if not hl.get_workspace(id) then',
      '          hl.dispatch(hl.dsp.workspace.change_id({ workspace = tostring(workspace.id), id = id }))',
      '          break',
      '        end',
      '      end',
      '    end',
      '  end',
      'end)'
    ].join("\n")
  }

  function hyprBlock(scheme, groupsList) {
    var lines = []
    lines.push(root.hyprPinsBeginMarker + ". Regenerated by the")
    lines.push("-- air.workspaces bar widget's Save button (gear icon on the bar) from its")
    lines.push("-- settings in ~/.config/omarchy/shell.json — edit there, not here; hand")
    lines.push("-- edits in this block get overwritten on the next Save. Pins use Wayland")
    lines.push("-- output names (DP-1/DP-2), not the \"desc:\" descriptors hl.monitor() above")
    lines.push("-- uses, since that's the identifier space Quickshell.screens (and so the")
    lines.push("-- widget's monitor picker) works in — a port swap would need re-picking the")
    lines.push("-- monitor in the widget's settings, same as it always did.")
    lines.push("-- scheme: " + scheme)

    if (scheme === "classic") {
      for (var i = 0; i < groupsList.length; i++) {
        var g = groupsList[i]
        if (!g.monitor) continue
        var ids = root.resolveIdsAgainst(groupsList, g)
        for (var j = 0; j < ids.length; j++) {
          lines.push('hl.workspace_rule({ workspace = "' + ids[j] + '", monitor = "' + g.monitor + '" })')
        }
      }
      lines.push("")
      lines.push(root.classicLua(groupsList))
    } else {
      lines.push("-- Omarchy's own per-monitor workspaces are in charge: nothing to override.")
    }

    lines.push(root.hyprPinsEndMarker)
    return lines.join("\n")
  }

  function syncHyprland(scheme, groupsList) {
    var raw = hyprMonitorsFile.text()
    var block = root.hyprBlock(scheme, groupsList)
    var beginIdx = raw.indexOf(root.hyprPinsBeginMarker)
    var endIdx = beginIdx === -1 ? -1 : raw.indexOf(root.hyprPinsEndMarker, beginIdx)

    var next
    if (beginIdx === -1 || endIdx === -1) {
      next = raw + (raw === "" || raw.slice(-1) === "\n" ? "" : "\n") + "\n" + block + "\n"
    } else {
      next = raw.slice(0, beginIdx) + block + raw.slice(endIdx + root.hyprPinsEndMarker.length)
    }

    if (next === raw) return
    hyprMonitorsFile.setText(next)
    hyprReloadTimer.restart()
  }

  // ------------------------------------------------------------ color choice
  //
  // Colorful, clickable swatches (not a dropdown) so the choice is genuinely
  // colorful, and nothing opens an overlay popup that could get clipped by
  // this widget's own small popup window. One swatch per key the active
  // theme's colors.toml defines (so the picker always reflects the real
  // palette, whatever the theme names its colors), the "?" swatch for the
  // automatic choice, and a field for any #rrggbb color of your own.
  readonly property var colorKeyOptions: {
    var keys = Object.keys(root.palette)
    if (keys.length === 0) keys = root.defaultColorKeys.slice()
    keys.sort()
    var opts = [{ value: "", label: "Auto" }]
    for (var i = 0; i < keys.length; i++) opts.push({ value: keys[i], label: keys[i] })
    return opts
  }

  readonly property color popupForeground: root.bar ? root.bar.barForeground : Color.foreground

  component ColorChoice: Flow {
    id: choice
    property string current: ""
    property string autoLabel: "Auto"
    signal picked(string key)

    width: parent ? parent.width : 0
    spacing: Style.space(6)

    Repeater {
      model: root.colorKeyOptions
      delegate: Rectangle {
        id: swatch
        required property var modelData
        readonly property bool isAuto: modelData.value === ""
        readonly property bool selected: choice.current === modelData.value
        readonly property color swatchColor: isAuto ? "transparent" : (root.palette[modelData.value] || Color.muted)

        width: Style.space(24)
        height: Style.space(24)
        radius: 5
        color: swatchColor
        border.width: selected ? 2 : 1
        border.color: selected
          ? root.popupForeground
          : Qt.darker(isAuto ? root.popupForeground : swatchColor, 1.3)

        Text {
          visible: swatch.isAuto
          anchors.centerIn: parent
          text: "?"
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          color: root.popupForeground
        }

        MouseArea {
          id: swatchMouse
          anchors.fill: parent
          hoverEnabled: true
          cursorShape: Qt.PointingHandCursor
          onClicked: choice.picked(swatch.modelData.value)
        }

        ToolTip.visible: swatchMouse.containsMouse
        ToolTip.text: swatch.isAuto ? choice.autoLabel : swatch.modelData.label
        ToolTip.delay: 400
      }
    }

    // Any color of your own. Only a complete #rrggbb counts; anything else is
    // ignored until it is one.
    TextField {
      id: hexField
      width: Style.space(84)
      placeholderText: "#rrggbb"
      maximumLength: 7
      text: root.isHexColor(choice.current) ? choice.current : ""
      onTextEdited: if (root.isHexColor(text)) choice.picked(text)

      Rectangle {
        visible: root.isHexColor(choice.current)
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.rightMargin: Style.space(6)
        width: Style.space(12)
        height: width
        radius: 3
        color: root.isHexColor(choice.current) ? choice.current : "transparent"
        border.width: 1
        border.color: root.popupForeground
      }
    }
  }

  // -------------------------------------------------------------------- bar

  implicitWidth: (root.vertical ? Math.max(grid.implicitWidth, gearButton.implicitWidth) : grid.implicitWidth + trailingGap + gearButton.implicitWidth)
  implicitHeight: (root.vertical ? grid.implicitHeight + gearButton.implicitHeight : Math.max(grid.implicitHeight, gearButton.implicitHeight))

  GridLayout {
    id: grid
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.bottom: root.vertical ? undefined : parent.bottom
    columns: root.vertical ? 1 : root.workspaceIds().length
    columnSpacing: root.vertical ? 0 : Style.space(1)
    rowSpacing: root.vertical ? Style.space(2) : 0

    Repeater {
      model: root.workspaceIds()

      Item {
        id: cell
        required property int modelData
        required property int index

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: root.isMarked(modelData)
        readonly property color numberColor: root.numberColorFor(modelData)
        readonly property color frameColor: root.frameColorFor(modelData)
        // A gap sets visiting workspaces (another block's, parked on this
        // monitor) apart from the monitor's own.
        readonly property bool firstGuest: root.perMonitor && index > 0
          && root.blockOf(modelData) !== root.block
          && root.blockOf(root.workspaceIds()[index - 1]) === root.block

        implicitWidth: root.vertical ? root.barSize : Style.space(20)
        implicitHeight: root.barSize
        Layout.preferredWidth: implicitWidth
        Layout.preferredHeight: implicitHeight
        Layout.leftMargin: firstGuest && !root.vertical ? Style.space(6) : 0
        Layout.topMargin: firstGuest && root.vertical ? Style.space(6) : 0

        Rectangle {
          anchors.centerIn: parent
          width: Math.min(parent.width, parent.height) - 4
          height: width
          radius: 6
          color: "transparent"
          border.width: cell.focused ? 1.5 : 0
          border.color: cell.frameColor
          antialiasing: true

          Behavior on border.width {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
          }
        }

        WidgetButton {
          anchors.fill: parent
          bar: root.bar
          text: root.labelFor(modelData)
          foreground: cell.numberColor
          activeColor: cell.numberColor
          opacity: cell.occupied || cell.focused ? 1 : 0.5
          horizontalMargin: 6
          verticalPadding: 6
          fixedWidth: parent.width
          fixedHeight: parent.height
          onPressed: function() { root.focusWorkspace(modelData) }
        }
      }
    }
  }

  BarIconButton {
    id: gearButton
    bar: root.bar
    text: ""
    anchors.left: root.vertical ? parent.left : undefined
    anchors.top: root.vertical ? grid.bottom : undefined
    anchors.right: root.vertical ? undefined : parent.right
    anchors.verticalCenter: root.vertical ? undefined : parent.verticalCenter
    // Tooltip suppressed because the settings popup is the detail view —
    // same reasoning as the weather widget's icon button. A tooltip here
    // is a separate floating overlay anchored to this same button, and it
    // was lingering/overlapping the popup opening and closing right next
    // to it (visible as a thin stray line, and requiring an extra click
    // to fully dismiss).
    tooltipText: ""
    onPressed: function() { root.toggleSettings() }
  }

  PopupCard {
    id: settingsPopup
    anchorItem: gearButton
    owner: root
    bar: root.bar
    open: root.settingsOpen
    // PopupCard's underlying PopupWindow does not request real keyboard
    // focus by default (it's normally used for hover/info cards with no
    // text entry, e.g. the tray's manage list). Without this, clicking a
    // TextField inside looked focused but never actually received key
    // events from the compositor — only pointer-driven text operations
    // (selection drag, the right-click Cut/Copy/Paste menu) worked, since
    // those don't require Wayland keyboard focus. `focusable` is a
    // PanelWindow property and doesn't exist on PopupWindow at all — the
    // equivalent here is `grabFocus`.
    grabFocus: true
    // grabFocus and PopupCard's default "click" trigger (which runs its own
    // HyprlandFocusGrab for outside-click-to-dismiss) do conflict — with
    // triggerMode left at its default, the gear icon opened nothing at all
    // (confirmed by testing both ways). "hover" skips that grab, and the
    // popup opens correctly.
    //
    // Trade-off: a real keyboard-focus-grabbing popup (grabFocus: true)
    // still gets dismissed by the compositor on an outside click regardless
    // of triggerMode — that's baked into what requesting real keyboard
    // focus means here, not something HyprlandFocusGrab controls. In
    // "hover" mode nothing tells our settingsOpen that happened, so the
    // popup visually vanishes while settingsOpen stays true and the bar's
    // open-panel underline never releases — hence onVisibleChanged below,
    // syncing settingsOpen back whenever the popup's actual visibility
    // changes for any reason, not just our own close() calls.
    triggerMode: "hover"
    onVisibleChanged: if (!settingsPopup.visible) root.closeSettings()
    contentWidth: settingsPopup.fittedContentWidth(Style.space(360))
    contentHeight: settingsPopup.fittedContentHeight(Math.min(settingsColumn.implicitHeight + footer.height + Style.space(8), Style.space(480)))

    // Content can run taller than the widget's own bar surface once a
    // group's color swatches wrap onto a second line — a Flickable lets it
    // scroll instead of the extra rows getting clipped (or, worse, a child
    // popup silently rendering past the edge of this window).
    Flickable {
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.top: parent.top
      anchors.bottom: footer.top
      anchors.bottomMargin: Style.space(8)
      contentWidth: width
      contentHeight: settingsColumn.implicitHeight
      clip: true
      boundsBehavior: Flickable.StopAtBounds
      interactive: contentHeight > height

      ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

      Column {
        id: settingsColumn
        width: parent.width
        spacing: Style.space(12)

        Text {
          text: "Workspaces"
          color: root.popupForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        // ------------------------------------------------------ scheme picker
        Row {
          spacing: Style.space(8)

          Repeater {
            model: [
              { value: "classic", title: "Classic", detail: "One set of workspaces 1-10. Super+N goes to workspace N; you choose which monitor shows which." },
              { value: "per-monitor", title: "Per monitor", detail: "Every monitor has its own 1-10. Super+N goes to the Nth workspace of the monitor you're on." }
            ]
            delegate: Rectangle {
              id: card
              required property var modelData
              readonly property bool selected: root.editScheme === modelData.value

              width: (settingsColumn.width - Style.space(8)) / 2
              height: cardText.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: selected ? Qt.rgba(root.popupForeground.r, root.popupForeground.g, root.popupForeground.b, 0.12) : "transparent"
              border.width: selected ? 2 : 1
              border.color: selected ? root.popupForeground : Qt.darker(root.popupForeground, 1.8)

              Column {
                id: cardText
                anchors.fill: parent
                anchors.margins: Style.space(8)
                spacing: Style.space(4)

                Text {
                  text: card.modelData.title
                  color: root.popupForeground
                  font.family: Style.font.family
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Text {
                  width: parent.width
                  text: card.modelData.detail
                  color: Qt.darker(root.popupForeground, 1.3)
                  font.family: Style.font.family
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
              }

              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.setEditScheme(card.modelData.value)
              }
            }
          }
        }

        // ------------------------------------------- classic: monitor groups
        Text {
          visible: root.editScheme === "classic"
          text: "One row per monitor. Workspaces: comma list, ranges (\"1-3\"), or \"*\" for everything left over."
          color: Qt.darker(root.popupForeground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: parent.width
        }

        Repeater {
          model: root.editScheme === "classic" ? editGroupsModel : null
          delegate: Column {
            id: row
            required property int index
            required property string monitor
            required property string idsText
            required property string colorKey
            width: settingsColumn.width
            spacing: Style.space(6)

            Rectangle {
              width: parent.width
              height: 1
              visible: row.index > 0
              color: Qt.darker(root.popupForeground, 1.6)
              opacity: 0.3
            }

            Row {
              spacing: Style.space(6)

              Dropdown {
                id: monitorDropdown
                width: Style.space(100)
                showLabel: false
                value: row.monitor
                options: {
                  var opts = []
                  var screens = Quickshell.screens
                  var seen = {}
                  for (var i = 0; i < screens.length; i++) {
                    opts.push(screens[i].name)
                    seen[screens[i].name] = true
                  }
                  if (row.monitor && !seen[row.monitor]) opts.push(row.monitor)
                  return opts
                }
                onChanged: function(value) {
                  editGroupsModel.setProperty(row.index, "monitor", value)
                  root.bumpEditGroupsVersion()
                }
              }

              // Not a hard error (an external monitor can be legitimately
              // unplugged right now with its config still worth keeping),
              // so this warns without blocking Save the way a duplicate
              // workspace assignment does.
              Text {
                id: disconnectedMonitorWarning
                visible: root.rowMonitorDisconnected(row.index)
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                font.family: Style.font.family
                font.pixelSize: Style.font.body
                color: Color.urgent

                MouseArea {
                  id: disconnectedWarningMouse
                  anchors.fill: parent
                  hoverEnabled: true
                }

                ToolTip.visible: disconnectedWarningMouse.containsMouse
                ToolTip.text: "\"" + row.monitor + "\" isn't currently connected. Its config is kept, but double-check the name if this isn't a temporarily unplugged monitor."
                ToolTip.delay: 400
              }

              Item {
                id: idsFieldSlot
                width: Style.space(100)
                height: idsField.height

                TextField {
                  id: idsField
                  anchors.fill: parent
                  placeholderText: "1-5 or *"
                  text: row.idsText
                  onTextEdited: {
                    editGroupsModel.setProperty(row.index, "idsText", text)
                    root.bumpEditGroupsVersion()
                  }
                }

                // Same duplicate-workspace check as the warning text below,
                // localized to the field actually responsible for it.
                Rectangle {
                  anchors.fill: parent
                  visible: root.rowHasDuplicateWorkspace(row.index)
                  color: "transparent"
                  radius: Style.cornerRadius
                  border.width: 2
                  border.color: Color.urgent
                }
              }

              Button {
                iconText: ""
                foreground: root.popupForeground
                horizontalPadding: 6
                verticalPadding: 3
                onClicked: root.removeEditGroup(row.index)
              }
            }

            ColorChoice {
              current: row.colorKey
              onPicked: function(key) { editGroupsModel.setProperty(row.index, "colorKey", key) }
            }
          }
        }

        Text {
          visible: root.editScheme === "classic" && root.hasDuplicateWorkspaces
          width: parent.width
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          text: (root.duplicateWorkspaceIds.length === 1
            ? "Workspace " + root.duplicateWorkspaceIds[0] + " is"
            : "Workspaces " + root.duplicateWorkspaceIds.join(", ") + " are")
            + " assigned more than once — entered twice in one field, or split across two"
            + " monitors. Fix the highlighted field(s) before saving."
        }

        Text {
          visible: root.editScheme === "classic" && root.disconnectedMonitors.length > 0
          width: parent.width
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          text: (root.disconnectedMonitors.length === 1
            ? "\"" + root.disconnectedMonitors[0] + "\" isn't"
            : "\"" + root.disconnectedMonitors.join("\", \"") + "\" aren't")
            + " currently connected (see the  marks above). Their config is kept —"
            + " only worth fixing if that's not a temporarily unplugged monitor."
        }

        Button {
          visible: root.editScheme === "classic"
          text: "Add monitor"
          iconText: ""
          foreground: root.popupForeground
          horizontalPadding: 8
          verticalPadding: 4
          onClicked: root.addEditGroup()
        }

        // ------------------------------------- per-monitor: one color per monitor
        Text {
          visible: root.editScheme === "per-monitor"
          text: "Each monitor numbers its own workspaces 1-10. Pick the color of its numbers."
          color: Qt.darker(root.popupForeground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: parent.width
        }

        Repeater {
          model: root.editScheme === "per-monitor" ? editMonitorsModel : null
          delegate: Column {
            id: monitorRow
            required property int index
            required property string monitor
            required property string colorKey
            width: settingsColumn.width
            spacing: Style.space(6)

            Rectangle {
              width: parent.width
              height: 1
              visible: monitorRow.index > 0
              color: Qt.darker(root.popupForeground, 1.6)
              opacity: 0.3
            }

            Text {
              text: monitorRow.monitor
              color: root.popupForeground
              font.family: Style.font.family
              font.pixelSize: Style.font.body
            }

            ColorChoice {
              current: monitorRow.colorKey
              onPicked: function(key) { editMonitorsModel.setProperty(monitorRow.index, "colorKey", key) }
            }
          }
        }

        // ------------------------------------------------------------- shared
        Rectangle {
          width: parent.width
          height: 1
          color: Qt.darker(root.popupForeground, 1.6)
          opacity: 0.3
        }

        Text {
          text: "Focus frame"
          color: root.popupForeground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }

        ColorChoice {
          current: root.editFrameColor
          autoLabel: "Same as the number"
          onPicked: function(key) { root.editFrameColor = key }
        }
      }
    }

    // Pinned below the scrolling area so Save is always in reach, however
    // many monitors the form lists.
    Row {
      id: footer
      anchors.left: parent.left
      anchors.bottom: parent.bottom
      spacing: Style.space(8)

      Button {
        text: "Save"
        iconText: "\uf0c7"
        foreground: root.popupForeground
        horizontalPadding: 8
        verticalPadding: 4
        opacity: root.saveBlocked ? 0.4 : 1.0
        tooltipText: root.saveBlocked ? "Resolve duplicate workspace assignments first" : ""
        onClicked: root.saveSettings()
      }

      Button {
        text: "Cancel"
        foreground: root.popupForeground
        horizontalPadding: 8
        verticalPadding: 4
        onClicked: root.closeSettings()
      }
    }
  }
}
