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

  function workspaceById(id) {
    var values = Hyprland.workspaces.values
    for (var i = 0; i < values.length; i++) {
      if (values[i].id === id) return values[i]
    }

    return null
  }

  // Per-monitor workspace groups, configured via the gear icon's settings
  // popup below (persisted into this widget's shell.json layout entry) —
  // see README.md in this plugin's directory for the on-disk shape. e.g.:
  //   { "id": "air.workspaces", "groups": [
  //       { "monitor": "DP-1", "ids": [1,2,3,4,5], "colorKey": "red" },
  //       { "monitor": "DP-2", "ids": "*", "colorKey": "yellow" }
  //   ] }
  // `ids` is either an explicit array of workspace numbers, or "*" meaning
  // "every workspace 1-10 not explicitly claimed by another group" (so one
  // monitor can pin 1-3 while another picks up everything else). With no
  // "groups" setting, every monitor shows workspaces 1-10 as one ungrouped
  // range.
  //
  // `root.bar` is one shared object across every monitor's bar surface, so
  // it can't tell us which screen this widget instance is on. QtQuick's
  // plain `Screen` attached property doesn't resolve correctly inside
  // Quickshell's layer-shell PanelWindow surfaces either. `QsWindow.window
  // .screen` (used the same way elsewhere in this shell, e.g. Bar.qml's
  // tooltip anchoring) is the reliable path to this item's actual hosting
  // screen.
  readonly property var defaultColorKeys: ["red", "yellow", "green", "blue", "magenta", "cyan"]
  readonly property var groups: root.setting("groups", [])

  function screenName() {
    var win = root.QsWindow ? root.QsWindow.window : null
    return win && win.screen ? String(win.screen.name || "") : ""
  }

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

  function workspaceIds() {
    var ids = root.baseIdsForScreen()
    var values = Hyprland.workspaces.values

    for (var i = 0; i < values.length; i++) {
      var id = values[i].id
      if (id > 0 && ids.indexOf(id) === -1) ids.push(id)
    }

    ids.sort(function(left, right) { return left - right })
    return ids
  }

  function focusWorkspace(id) {
    if (!root.bar) return
    root.bar.run("hyprctl dispatch " + Util.shellQuote("hl.dsp.focus({ workspace = \"" + id + "\" })"))
  }

  readonly property real trailingGap: root.vertical ? 0 : Style.spaceReal(1.5)

  // Raw theme palette, read from the active theme's colors.toml (the same
  // file terminals/other apps pick up) so group colors follow theme
  // switches instead of being hardcoded to one theme's hex values.
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

  // Resolves a color key (a group's explicit "colorKey", falling back to a
  // rotating default per group index) to an actual color: a palette key
  // from colors.toml if the theme defines it, else Color.urgent/Color.accent.
  function colorForKeyOrIndex(key, index) {
    var k = key || root.defaultColorKeys[((index % root.defaultColorKeys.length) + root.defaultColorKeys.length) % root.defaultColorKeys.length]
    return root.palette[k] || (index === 0 ? Color.urgent : Color.accent)
  }

  function colorForGroupIndex(index) {
    var group = index >= 0 && index < root.groups.length ? root.groups[index] : null
    return root.colorForKeyOrIndex(group ? group.colorKey : "", index)
  }

  function groupIndexForWorkspace(id) {
    for (var i = 0; i < root.groups.length; i++) {
      if (root.groupIdsResolved(root.groups[i]).indexOf(id) !== -1) return i
    }
    return -1
  }

  // ---------------------------------------------------------------- settings

  // Edited as a ListModel, not a plain JS array: setProperty() below updates
  // a row's fields in place, so the Repeater's delegates (and their
  // TextFields) are never destroyed and recreated while typing. Reassigning
  // a plain-array property on every keystroke was doing exactly that, which
  // is why a TextField used to lose focus and its cursor position after
  // every single character (and sometimes fail to focus at all, if a click
  // landed mid-rebuild).
  property bool settingsOpen: false
  ListModel { id: editGroupsModel }

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

  function openSettings() {
    editGroupsModel.clear()
    for (var i = 0; i < root.groups.length; i++) {
      var g = root.groups[i]
      editGroupsModel.append({ monitor: String(g.monitor || ""), idsText: root.idsToText(g.ids), colorKey: String(g.colorKey || "") })
    }
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

  function saveSettings() {
    if (!root.bar || !root.bar.shell) return
    if (root.hasDuplicateWorkspaces) return
    var groupsOut = []
    for (var i = 0; i < editGroupsModel.count; i++) {
      var g = editGroupsModel.get(i)
      if (!g.monitor) continue
      groupsOut.push({ monitor: g.monitor, ids: root.parseIdsText(g.idsText), colorKey: g.colorKey || "" })
    }
    root.bar.shell.updateEntryInline(root.settingsId, { groups: groupsOut })
    root.syncHyprlandPins(groupsOut)
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

  // ---------------------------------------------------- Hyprland pin sync
  //
  // The groups above only control this bar widget's display — Hyprland's
  // own workspace-to-monitor binding (what Super+N actually activates) is a
  // separate mechanism: hl.workspace_rule() calls in
  // ~/.config/hypr/monitors.lua. Left alone, editing groups here silently
  // desyncs the bar's display from real Super+N behavior. So Save also
  // regenerates the matching pins there, between two sentinel comments
  // installed once by hand — everything outside those markers (hl.monitor()
  // blocks, other config) is left untouched, and re-running Save just
  // replaces the block between the same markers again.

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

  function hyprPinBlock(groupsList) {
    var lines = []
    lines.push(root.hyprPinsBeginMarker + ". Regenerated by the")
    lines.push("-- air.workspaces bar widget's Save button (gear icon on the bar) from its")
    lines.push("-- \"groups\" setting in ~/.config/omarchy/shell.json — edit there, not here;")
    lines.push("-- hand edits in this block get overwritten on the next Save. Uses Wayland")
    lines.push("-- output names (DP-1/DP-2), not the \"desc:\" descriptors hl.monitor() above")
    lines.push("-- uses, since that's the identifier space Quickshell.screens (and so the")
    lines.push("-- widget's monitor picker) works in — a port swap would need re-picking the")
    lines.push("-- monitor in the widget's settings, same as it always did.")
    for (var i = 0; i < groupsList.length; i++) {
      var g = groupsList[i]
      if (!g.monitor) continue
      var ids = root.resolveIdsAgainst(groupsList, g)
      for (var j = 0; j < ids.length; j++) {
        lines.push('hl.workspace_rule({ workspace = "' + ids[j] + '", monitor = "' + g.monitor + '" })')
      }
    }
    lines.push(root.hyprPinsEndMarker)
    return lines.join("\n")
  }

  function syncHyprlandPins(groupsList) {
    var raw = hyprMonitorsFile.text()
    var beginIdx = raw.indexOf(root.hyprPinsBeginMarker)
    if (beginIdx === -1) return
    var endIdx = raw.indexOf(root.hyprPinsEndMarker, beginIdx)
    if (endIdx === -1) return
    endIdx += root.hyprPinsEndMarker.length

    var next = raw.slice(0, beginIdx) + root.hyprPinBlock(groupsList) + raw.slice(endIdx)
    if (next === raw) return
    hyprMonitorsFile.setText(next)
    hyprReloadProcess.running = true
  }

  // Color options for the settings popup: every key the active theme's
  // colors.toml actually defines (so the picker always reflects the real
  // palette, whatever the theme names its colors), falling back to the
  // built-in rotation before the palette has loaded. Rendered as clickable
  // swatches (not a dropdown) so: (1) the choice is genuinely colorful
  // instead of a plain text list, and (2) nothing opens an overlay popup
  // that could get clipped by this widget's own small popup window.
  readonly property var colorKeyOptions: {
    var keys = Object.keys(root.palette)
    if (keys.length === 0) keys = root.defaultColorKeys.slice()
    keys.sort()
    var opts = [{ value: "", label: "Auto" }]
    for (var i = 0; i < keys.length; i++) opts.push({ value: keys[i], label: keys[i] })
    return opts
  }

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

        readonly property var workspace: root.workspaceById(modelData)
        readonly property bool occupied: workspace !== null && workspace.toplevels.values.length > 0
        readonly property bool focused: Hyprland.focusedWorkspace !== null && Hyprland.focusedWorkspace.id === modelData
        readonly property color groupColor: root.colorForGroupIndex(root.groupIndexForWorkspace(modelData))

        implicitWidth: root.vertical ? root.barSize : Style.space(20)
        implicitHeight: root.barSize
        Layout.preferredWidth: implicitWidth
        Layout.preferredHeight: implicitHeight

        Rectangle {
          anchors.centerIn: parent
          width: Math.min(parent.width, parent.height) - 4
          height: width
          radius: 6
          color: "transparent"
          border.width: cell.focused ? 1.5 : 0
          border.color: cell.groupColor
          antialiasing: true

          Behavior on border.width {
            NumberAnimation { duration: 140; easing.type: Easing.OutCubic }
          }
        }

        WidgetButton {
          anchors.fill: parent
          bar: root.bar
          text: modelData === 10 ? "0" : String(modelData)
          foreground: cell.groupColor
          activeColor: cell.groupColor
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
    text: "\uf013"
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
    contentHeight: settingsPopup.fittedContentHeight(Math.min(settingsColumn.implicitHeight, Style.space(420)))

    // Content can run taller than the widget's own bar surface once a
    // group's color swatches wrap onto a second line — a Flickable lets it
    // scroll instead of the extra rows getting clipped (or, worse, a child
    // popup silently rendering past the edge of this window).
    Flickable {
      anchors.fill: parent
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
          text: "Workspace groups"
          color: root.bar ? root.bar.barForeground : Color.foreground
          font.family: Style.font.family
          font.pixelSize: Style.font.body
          font.bold: true
        }

        Text {
          text: "One row per monitor. Workspaces: comma list, ranges (\"1-3\"), or \"*\" for everything left over."
          color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.4)
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
          width: parent.width
        }

        Repeater {
          model: editGroupsModel
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
              color: Qt.darker(root.bar ? root.bar.barForeground : Color.foreground, 1.6)
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
                text: "\uf071"
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
                iconText: "\uf00d"
                foreground: root.bar ? root.bar.barForeground : Color.foreground
                horizontalPadding: 6
                verticalPadding: 3
                onClicked: root.removeEditGroup(row.index)
              }
            }

            // Colorful, clickable swatches instead of a plain-text dropdown
            // — inline (never opens its own popup), so it can never get
            // clipped by this settings window's own bounds either.
            Flow {
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.colorKeyOptions
                delegate: Rectangle {
                  id: swatch
                  required property var modelData
                  readonly property bool isAuto: modelData.value === ""
                  readonly property bool selected: row.colorKey === modelData.value
                  readonly property color swatchColor: isAuto ? "transparent" : (root.palette[modelData.value] || Color.muted)

                  width: Style.space(24)
                  height: Style.space(24)
                  radius: 5
                  color: swatchColor
                  border.width: selected ? 2 : 1
                  border.color: selected
                    ? (root.bar ? root.bar.barForeground : Color.foreground)
                    : Qt.darker(isAuto ? (root.bar ? root.bar.barForeground : Color.foreground) : swatchColor, 1.3)

                  Text {
                    visible: swatch.isAuto
                    anchors.centerIn: parent
                    text: "?"
                    font.family: Style.font.family
                    font.pixelSize: Style.font.caption
                    color: root.bar ? root.bar.barForeground : Color.foreground
                  }

                  MouseArea {
                    id: swatchMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: editGroupsModel.setProperty(row.index, "colorKey", swatch.modelData.value)
                  }

                  ToolTip.visible: swatchMouse.containsMouse
                  ToolTip.text: swatch.modelData.label
                  ToolTip.delay: 400
                }
              }
            }
          }
        }

        Text {
          visible: root.hasDuplicateWorkspaces
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
          visible: root.disconnectedMonitors.length > 0
          width: parent.width
          wrapMode: Text.WordWrap
          color: Color.urgent
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
          text: (root.disconnectedMonitors.length === 1
            ? "\"" + root.disconnectedMonitors[0] + "\" isn't"
            : "\"" + root.disconnectedMonitors.join("\", \"") + "\" aren't")
            + " currently connected (see the  marks above). Their config is kept —"
            + " only worth fixing if that's not a temporarily unplugged monitor."
        }

        Row {
          spacing: Style.space(8)

          Button {
            text: "Add monitor"
            iconText: "\uf067"
            foreground: root.bar ? root.bar.barForeground : Color.foreground
            horizontalPadding: 8
            verticalPadding: 4
            onClicked: root.addEditGroup()
          }

          Button {
            text: "Save"
            iconText: "\uf0c7"
            foreground: root.bar ? root.bar.barForeground : Color.foreground
            horizontalPadding: 8
            verticalPadding: 4
            opacity: root.hasDuplicateWorkspaces ? 0.4 : 1.0
            tooltipText: root.hasDuplicateWorkspaces ? "Resolve duplicate workspace assignments first" : ""
            onClicked: root.saveSettings()
          }

          Button {
            text: "Cancel"
            foreground: root.bar ? root.bar.barForeground : Color.foreground
            horizontalPadding: 8
            verticalPadding: 4
            onClicked: root.closeSettings()
          }
        }
      }
    }
  }
}
