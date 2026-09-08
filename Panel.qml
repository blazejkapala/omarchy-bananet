import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// banan.bananet — Bananet: where does this machine's traffic go?
//
// Bar: glyph + short egress label ("wifi +2" = internet leaves over Wi-Fi,
// two tunnels are up). Hover: one-screen summary. Click: full panel with
// interfaces/tunnels, live throughput, routes, DNS, per-service connections
// and listening services. All data comes from collect.py (no root needed).
Panel {
  id: root
  moduleName: "banan.bananet"
  ipcTarget: "banan.bananet"
  manageIpc: false

  // Own IPC handler so `omarchy-shell banan.bananet <method>` also gets
  // refresh/scrollTo (the base Panel only offers open/close/toggle).
  IpcHandler {
    target: "banan.bananet"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
    function scrollTo(y: string): void { root.scrollTo(Number(y)) }
  }

  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal
  implicitWidth: vertical ? barSize : widgetRow.implicitWidth
  implicitHeight: barSize

  // ------------------------------------------------------------------ theme
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  // Blend toward the surface the text sits on instead of Qt.darker(): on a
  // light theme (Catppuccin Latte, Flexoki Light, White) darkening a dark
  // foreground makes "dim" text *more* prominent, not less.
  function mix(a, b, t) {
    return Qt.rgba(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, 1)
  }
  readonly property color surface: Color.popups.background
  readonly property color barSurface: Color.bar.background
  readonly property color dim: mix(foreground, surface, 0.38)
  readonly property color dimmer: mix(foreground, surface, 0.58)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color hoverFill: Style.hoverFillFor(foreground, Color.accent)
  readonly property color selectedFill: Style.selectedFillFor(foreground, Color.accent)

  // --------------------------------------------------------------- settings
  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }
  function boolSetting(name, fallback) {
    var v = setting(name, fallback)
    if (typeof v === "string") return v === "true" || v === "1" || v === "yes"
    return !!v
  }
  readonly property int refreshIntervalSec: intSetting("refreshIntervalSec", 10, 2, 600)
  readonly property int openRefreshIntervalSec: intSetting("openRefreshIntervalSec", 2, 1, 60)
  readonly property bool showLabel: boolSetting("showLabel", false)
  readonly property bool showTooltip: boolSetting("showTooltip", false)
  readonly property string iconStyle: String(setting("iconStyle", "banana"))
  readonly property bool resolveNames: boolSetting("resolveNames", true)
  readonly property bool useSudo: boolSetting("useSudo", true)
  readonly property bool showInactive: boolSetting("showInactive", true)
  readonly property bool showVirtual: boolSetting("showVirtual", false)
  readonly property bool showLoopback: boolSetting("showLoopback", false)
  readonly property bool publicIp: boolSetting("publicIp", true)
  property bool forcePublic: false     // next refresh re-checks the public IP now (manual refresh)
  readonly property var labelOverrides: {
    var v = setting("labels", null)
    return (v && typeof v === "object") ? v : {}
  }

  // ------------------------------------------------------------------- data
  readonly property string scriptPath: Qt.resolvedUrl("collect.py").toString().replace(/^file:\/\//, "")
  property var snap: ({ interfaces: [], processes: [], listeners: [], connections: [], warnings: [], egress: {} })
  property bool loaded: false
  property bool refreshing: false
  property string lastError: ""
  property double lastSampleMs: 0
  property var rates: ({})
  property var _prev: null
  property string actionStatus: ""
  property var history: []            // [[ts, {dev: [rx, tx]}], ...] cumulative counters, 30 s apart, 24 h
  property int chartRange: 3600       // seconds shown in charts: 3600 / 21600 / 86400
  readonly property color accentColor: {
    var a = Color.accent
    var f = foreground
    return (Math.abs(a.r - f.r) + Math.abs(a.g - f.g) + Math.abs(a.b - f.b) < 0.15) ? mix(f, surface, 0.4) : a
  }

  readonly property var egress: snap && snap.egress ? snap.egress : {}
  readonly property var egress4: egress.v4 || null
  readonly property var pub: snap && snap.public ? snap.public : null
  readonly property var tools: snap && snap.tools ? snap.tools : []
  readonly property string publicText: {
    if (!pub) return ""
    if (!pub.available) return pub.error ? "unreachable (" + pub.error + ")" : (pub.reason || "unknown")
    var parts = []
    if (pub.v4) parts.push(pub.v4)
    if (pub.v6) parts.push(pub.v6)
    var g = pub.info || {}
    var who = []
    if (g.org) who.push(g.org)
    if (g.city || g.country) who.push([g.city, g.country].filter(function(x) { return !!x }).join(", "))
    if (g.hostname) who.push(g.hostname)
    var out = parts.join("  /  ") + (who.length ? "  ·  " + who.join(" · ") : "")
    if (pub.stale) out += "  (stale, last check failed)"
    return out
  }
  readonly property string toolsText: {
    var found = [], missing = []
    for (var i = 0; i < tools.length; i++) (tools[i].found ? found : missing).push(tools[i].name)
    if (found.length === 0 && missing.length === 0) return ""
    return "detected: " + found.join(" · ") + (missing.length ? "   ·   not installed: " + missing.join(" · ") : "")
  }
  readonly property var egress6: egress.v6 || null
  readonly property int tunnelsActive: snap && snap.tunnelsActive ? snap.tunnelsActive : 0
  readonly property var defaultIface: {
    var list = snap && snap.interfaces ? snap.interfaces : []
    for (var i = 0; i < list.length; i++) if (list[i].isDefault) return list[i]
    return null
  }

  // A refresh replaces the row models, which rebuilds every delegate and lets
  // the Flickable snap back to the top. Remember the scroll offset before the
  // swap and pin it back for a moment while the content settles.
  property real _savedScroll: 0
  property bool _restoringScroll: false
  function scrollTo(y) {
    var f = scrollArea.contentItem
    if (!f) return
    f.contentY = Math.max(0, Math.min(Number(y) || 0, Math.max(0, f.contentHeight - f.height)))
  }
  function restoreScroll() {
    if (!_restoringScroll) return
    scrollTo(_savedScroll)
  }
  Timer {
    id: scrollRestoreTimer
    interval: 300
    repeat: false
    onTriggered: { root.restoreScroll(); root._restoringScroll = false }
  }
  Connections {
    target: scrollArea.contentItem
    function onContentHeightChanged() { root.restoreScroll() }
  }

  function applySample(doc) {
    if (opened && scrollArea.contentItem) {
      _savedScroll = scrollArea.contentItem.contentY
      _restoringScroll = _savedScroll > 0
      if (_restoringScroll) scrollRestoreTimer.restart()
    }
    var now = Number(doc.ts) || Date.now() / 1000
    var counters = {}
    var list = doc.interfaces || []
    for (var i = 0; i < list.length; i++) counters[list[i].name] = { rx: Number(list[i].rx) || 0, tx: Number(list[i].tx) || 0 }
    var next = {}
    if (_prev && now > _prev.ts) {
      var dt = now - _prev.ts
      for (var name in counters) {
        var p = _prev.counters[name]
        if (!p) continue
        next[name] = { rx: Math.max(0, (counters[name].rx - p.rx) / dt), tx: Math.max(0, (counters[name].tx - p.tx) / dt) }
      }
    } else {
      for (var n2 in counters) next[n2] = { rx: 0, tx: 0 }
    }
    _prev = { ts: now, counters: counters }
    rates = next
    snap = doc
    loaded = true
    lastSampleMs = Date.now()
    lastError = doc.error ? String(doc.error) : ""
    if (doc.history && doc.history.length !== undefined) history = doc.history
    syncRows()
    if (_restoringScroll) Qt.callLater(restoreScroll)
  }

  function handleOutput(text) {
    var raw = String(text || "")
    if (raw.length > maxDocumentChars) {
      lastError = "Collector output too large (" + raw.length + " chars), ignored"
      return
    }
    raw = raw.trim()
    if (raw === "") return
    try {
      applySample(JSON.parse(raw))
    } catch (e) {
      lastError = "Could not parse collector output: " + e
      console.warn("banan.bananet", lastError)
    }
  }

  // Fixed absolute paths only (never PATH lookups): the interpreter, the
  // terminal launcher and wl-copy. `-I` keeps PYTHON* variables and the
  // user site directory out of the collector.
  readonly property string pythonBin: "/usr/bin/python3"
  readonly property string terminalBin: "/usr/bin/omarchy-launch-terminal"
  readonly property string clipboardBin: "/usr/bin/wl-copy"
  readonly property int maxDocumentChars: 8 * 1024 * 1024

  // Strings that end up in components we do not own (tooltips) go through
  // this: with the default AutoText a "<b>" in a process name would be markup.
  function plain(value) {
    return String(value === undefined || value === null ? "" : value).replace(/</g, "\u2039").replace(/>/g, "\u203a")
  }

  function collectorArgs() {
    var args = [pythonBin, "-I", scriptPath]
    if (!resolveNames) args.push("--no-rdns")
    if (!useSudo) args.push("--no-sudo")
    if (showLoopback) args.push("--loopback")
    if (opened) args.push("--history")
    if (!publicIp) args.push("--no-public")
    if (forcePublic) { args.push("--public-now"); forcePublic = false }
    if (boolSetting("demo", false)) args.push("--demo")
    var keys = Object.keys(labelOverrides)
    if (keys.length > 0) { args.push("--labels"); args.push(JSON.stringify(labelOverrides)) }
    return args
  }

  function refresh() {
    if (collector.running) return
    refreshing = true
    collector.command = collectorArgs()
    collector.running = true
    watchdog.restart()
  }

  Process {
    id: collector
    running: false
    command: []
    stdout: StdioCollector { id: collectorOut; waitForEnd: true }
    stderr: StdioCollector { id: collectorErr; waitForEnd: true }
    onExited: function(exitCode) {
      root.refreshing = false
      watchdog.stop()
      var out = String(collectorOut.text || "")
      if (exitCode === 0 && out.trim() !== "") root.handleOutput(out)
      else {
        var err = String(collectorErr.text || "").trim()
        root.lastError = err !== "" ? err.split("\n").slice(-1)[0] : ("Collector exited with code " + exitCode)
      }
    }
  }

  Timer {
    id: watchdog
    interval: 8000
    repeat: false
    onTriggered: if (collector.running) collector.running = false
  }

  Timer {
    id: refreshTimer
    interval: (root.opened ? root.openRefreshIntervalSec : root.refreshIntervalSec) * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  Timer {
    id: actionStatusTimer
    interval: 2200
    repeat: false
    onTriggered: root.actionStatus = ""
  }

  // Tick once a second so the "refreshed N s ago" footer stays honest.
  property int clockTick: 0
  Timer { interval: 1000; repeat: true; running: root.opened; onTriggered: root.clockTick += 1 }

  onOpenedChanged: {
    if (opened) { cursorActive = false; refresh() }
  }


  // ------------------------------------------------------------- formatting
  function fmtBytes(n) {
    n = Number(n) || 0
    var units = ["B", "kB", "MB", "GB", "TB"]
    var i = 0
    while (n >= 1024 && i < units.length - 1) { n /= 1024; i++ }
    return (i === 0 ? Math.round(n) : n.toFixed(n >= 100 ? 0 : 1)) + " " + units[i]
  }
  function fmtRate(bps) { return fmtBytes(bps) + "/s" }
  function fmtAge(seconds) {
    seconds = Math.max(0, Math.round(Number(seconds) || 0))
    if (seconds < 60) return seconds + " s"
    if (seconds < 3600) return Math.floor(seconds / 60) + " min"
    if (seconds < 86400) return Math.floor(seconds / 3600) + " h"
    return Math.floor(seconds / 86400) + " d"
  }
  function rateOf(name) {
    var r = rates[name]
    return r ? r : { rx: 0, tx: 0 }
  }
  function kindGlyph(kind) {
    switch (kind) {
      case "wifi": return "󰖩"
      case "ethernet": return "󰈀"
      case "tailscale": return "󰖂"
      case "zerotier": return "󱘖"
      case "wireguard": return "󰦝"
      case "openvpn": return "󰒘"
      case "vpn": return "󰒘"
      case "virtual": return "󰡨"
      default: return "󰛳"
    }
  }
  function kindShort(kind, name) {
    switch (kind) {
      case "wifi": return "wifi"
      case "ethernet": return "eth"
      case "tailscale": return "ts"
      case "zerotier": return "zt"
      case "wireguard": return "wg"
      case "openvpn": return "ovpn"
      case "vpn": return "vpn"
      default: return name || "?"
    }
  }
  function isTunnelKind(kind) {
    return kind === "tailscale" || kind === "zerotier" || kind === "wireguard" || kind === "openvpn" || kind === "vpn"
  }
  function plural(n, one, many) {
    n = Number(n) || 0
    return n + " " + (n === 1 ? one : many)
  }
  function connWord(n) { return plural(n, "connection", "connections") }
  function remoteLabel(r) {
    var s = String(r.addr || "")
    if (r.name) s += " (" + r.name + ")"
    return s
  }

  // ------------------------------------------------------------ bar surface
  readonly property string egressShort: defaultIface ? kindShort(defaultIface.kind, defaultIface.name) : (loaded ? "none" : "…")
  readonly property string barLabel: {
    if (!loaded) return ""
    var s = egressShort
    if (egress.exitNode && egress.exitNode.name) s = "exit:" + egress.exitNode.name
    if (tunnelsActive > 0) s += " +" + tunnelsActive
    return s
  }
  readonly property bool egressViaTunnel: !!egress.exitNode || (defaultIface ? isTunnelKind(defaultIface.kind) : false)
  readonly property string mainGlyph: !loaded ? "󰖟" : (!defaultIface ? "󰲛" : (egressViaTunnel ? "󰖂" : "󰖟"))
  readonly property var setupItems: snap && snap.setup ? snap.setup : []
  readonly property var majorSetupItems: {
    var out = []
    for (var i = 0; i < setupItems.length; i++) if (!setupItems[i].minor) out.push(setupItems[i])
    return out
  }
  function setupFor(kind) {
    for (var i = 0; i < setupItems.length; i++) if (setupItems[i].iface === kind) return setupItems[i]
    return null
  }
  // The card names a rule id; collect.py --setup <id> prints the exact rule
  // and hands a self-contained root-side installer to `sudo python3 -I -` on
  // stdin. No shell, no generated command string, nothing root reopens here.
  function runSetup(item) {
    if (!item || !item.id) return
    if (!/^[a-z]+$/.test(String(item.id))) return
    Quickshell.execDetached([terminalBin, pythonBin, "-I", scriptPath, "--setup", String(item.id)])
    actionStatus = "Opening a terminal for the sudo rule…"
    actionStatusTimer.restart()
    delayedRefresh.restart()
  }
  Timer { id: delayedRefresh; interval: 15000; repeat: false; onTriggered: root.refresh() }

  readonly property color barIconColor: {
    var fg = barForeground
    if (!loaded) return mix(fg, barSurface, 0.4)
    if (!defaultIface) return urgent
    return fg
  }
  readonly property string barTooltip: {
    if (!loaded) return "Bananet: collecting…"
    var lines = []
    if (egress4) {
      var d = defaultIface
      lines.push("Internet → " + egress4.dev + (d ? " (" + d.label + ")" : "") + (egress4.gateway ? " via " + egress4.gateway : ""))
    } else lines.push("Internet → no default route")
    if (egress.exitNode && egress.exitNode.name) lines.push("Tailscale exit node: " + egress.exitNode.name)
    if (pub && pub.available) lines.push("Public IP: " + (pub.v4 || pub.v6 || "?") + ((pub.info || {}).org ? " · " + pub.info.org : "") + (pub.stale ? " (stale)" : ""))
    var list = snap.interfaces || []
    for (var i = 0; i < list.length; i++) {
      var f = list[i]
      if (!f.active) continue
      var r = rateOf(f.name)
      var line = kindGlyph(f.kind) + " " + f.name + "  " + f.label
      line += "  ↓ " + fmtRate(r.rx) + "  ↑ " + fmtRate(r.tx)
      if (f.connCount > 0) line += "  · " + connWord(f.connCount)
      lines.push(line)
    }
    if (egress.dns && egress.dns.length > 0) lines.push("DNS: " + egress.dns.join(", ") + (egress.dnsDev ? " (" + egress.dnsDev + ")" : ""))
    for (var m = 0; m < majorSetupItems.length; m++) lines.push("⚠ " + majorSetupItems[m].title + " (open the panel)")
    var procs = snap.processes || []
    if (procs.length > 0) {
      var top = []
      for (var p = 0; p < Math.min(4, procs.length); p++) top.push(procs[p].name + " ×" + procs[p].count)
      lines.push("Services: " + top.join(", ") + (procs.length > 4 ? ", …" : ""))
    }
    return lines.join("\n")
  }

  function handlePress(button) {
    if (button === Qt.RightButton) { refresh(); return }
    toggle()
  }

  Item {
    id: widgetRow
    anchors.fill: parent
    readonly property bool labelShown: root.showLabel && !root.vertical && root.barLabel !== ""
    implicitWidth: button.implicitWidth + (labelShown ? labelButton.implicitWidth : 0)
    implicitHeight: root.barSize

    BarIconButton {
      id: button
      bar: root.bar
      anchors.left: parent.left
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: implicitWidth
      text: root.iconStyle === "emoji" ? "🍌" : (root.iconStyle === "banana" ? "" : root.mainGlyph)
      iconComponent: root.iconStyle === "banana" ? bananaIcon : null
      useActiveColor: false
      foreground: root.barIconColor
      tooltipText: root.showTooltip ? root.plain(root.barTooltip) : ""
      onPressed: function(b) { root.handlePress(b) }
    }

    WidgetButton {
      id: labelButton
      bar: root.bar
      anchors.left: button.right
      anchors.top: parent.top
      anchors.bottom: parent.bottom
      width: visible ? implicitWidth : 0
      visible: widgetRow.labelShown
      text: root.barLabel
      fontSize: Style.font.bodySmall
      horizontalMargin: 3
      foreground: root.barIconColor
      useActiveColor: false
      tooltipText: root.showTooltip ? root.plain(root.barTooltip) : ""
      onPressed: function(b) { root.handlePress(b) }
    }
  }

  Component {
    id: bananaIcon
    Item {
      BananaIcon {
        anchors.centerIn: parent
        iconSize: Style.space(14)
        color: root.barIconColor
      }
    }
  }

  // ------------------------------------------------------------- row model
  property var expanded: ({})
  property bool showListeners: false
  property bool cursorActive: false
  property int cursorIndex: 0

  function isExpanded(key) { return !!expanded[key] }
  function toggleExpanded(key) {
    var next = {}
    for (var k in expanded) next[k] = expanded[k]
    if (next[key]) delete next[key]
    else next[key] = true
    expanded = next
  }
  function setAllExpanded(on) {
    var next = {}
    if (on) {
      for (var i = 0; i < ifaceRows.length; i++) next["if:" + ifaceRows[i].name] = true
      for (var j = 0; j < procRows.length; j++) next["proc:" + procRows[j].name] = true
    }
    expanded = next
  }

  // Row models are lists of stable keys; the data lives in maps swapped on
  // every refresh. A Repeater rebuilds its delegates only when the key list
  // itself changes (an interface appears or disappears), so a refresh merely
  // updates bindings in place — no rebuild, no flicker, no scroll jump.
  property var ifaceKeys: []
  property var procKeys: []
  property var listenKeys: []
  property var ifaceMap: ({})
  property var procMap: ({})
  property var listenMap: ({})
  readonly property var ifaceRows: ifaceKeys.map(function(k) { return ifaceMap[k] }).filter(function(x) { return !!x })
  readonly property var procRows: procKeys.map(function(k) { return procMap[k] }).filter(function(x) { return !!x })
  readonly property var listenRows: listenKeys.map(function(k) { return listenMap[k] }).filter(function(x) { return !!x })
  readonly property int listenHeaderIndex: ifaceKeys.length + procKeys.length
  readonly property int rowCount: ifaceKeys.length + procKeys.length + 1 + listenKeys.length
  readonly property string warningsJson: JSON.stringify(snap && snap.warnings ? snap.warnings : [])
  readonly property string minorSetupJson: {
    var out = []
    for (var i = 0; i < setupItems.length; i++) if (setupItems[i].minor) out.push(setupItems[i])
    return JSON.stringify(out)
  }

  function sameKeys(a, b) {
    if (a.length !== b.length) return false
    for (var i = 0; i < a.length; i++) if (a[i] !== b[i]) return false
    return true
  }
  function syncRows() {
    var list = snap && snap.interfaces ? snap.interfaces : []
    var im = {}, ik = []
    for (var i = 0; i < list.length; i++) {
      var f = list[i]
      if (!showInactive && !f.active) continue
      if (!showVirtual && f.kind === "virtual") continue
      im[f.name] = f
      ik.push(f.name)
    }
    ifaceMap = im
    if (!sameKeys(ik, ifaceKeys)) ifaceKeys = ik

    var procs = snap && snap.processes ? snap.processes : []
    var pm = {}, pk = []
    for (var j = 0; j < procs.length; j++) {
      var key = procs[j].name
      if (pm[key]) key += "#" + j
      pm[key] = procs[j]
      pk.push(key)
    }
    procMap = pm
    if (!sameKeys(pk, procKeys)) procKeys = pk

    var lm = {}, lk = []
    if (showListeners) {
      var ls = snap && snap.listeners ? snap.listeners : []
      for (var l = 0; l < ls.length; l++) {
        var lkey = ls[l].proto + ":" + ls[l].addr + ":" + ls[l].port + ":" + ls[l].proc
        if (lm[lkey]) lkey += "#" + l
        lm[lkey] = ls[l]
        lk.push(lkey)
      }
    }
    listenMap = lm
    if (!sameKeys(lk, listenKeys)) listenKeys = lk
    if (cursorIndex > rowCount - 1) cursorIndex = Math.max(0, rowCount - 1)
  }
  onShowInactiveChanged: syncRows()
  onShowVirtualChanged: syncRows()
  onShowListenersChanged: syncRows()

  function rowAt(idx) {
    if (idx < ifaceRows.length) return { section: "iface", item: ifaceRows[idx] }
    idx -= ifaceRows.length
    if (idx < procRows.length) return { section: "proc", item: procRows[idx] }
    idx -= procRows.length
    if (idx === 0) return { section: "listenHeader", item: null }
    idx -= 1
    if (idx < listenRows.length) return { section: "listen", item: listenRows[idx] }
    return { section: "", item: null }
  }

  function setCursor(idx) {
    cursorActive = true
    cursorIndex = Math.max(0, Math.min(rowCount - 1, idx))
  }
  function moveCursor(delta) {
    if (!cursorActive) { cursorActive = true; return }
    setCursor(cursorIndex + delta)
  }
  function activateCursor() {
    var row = rowAt(cursorIndex)
    if (row.section === "iface") toggleExpanded("if:" + row.item.name)
    else if (row.section === "proc") toggleExpanded("proc:" + row.item.name)
    else if (row.section === "listenHeader") showListeners = !showListeners
    else if (row.section === "listen") copyText(row.item.addr + ":" + row.item.port, "address")
  }
  function copyCursor() {
    var row = rowAt(cursorIndex)
    if (row.section === "iface") copyText(row.item.ip, row.item.name + " IP")
    else if (row.section === "proc" && row.item.remotes.length > 0) copyText(row.item.remotes[0].addr, row.item.name + " address")
    else if (row.section === "listen") copyText(row.item.addr + ":" + row.item.port, "address")
  }
  function copyText(value, label) {
    var text = String(value || "")
    if (text === "") return
    if (text.length > 65536) text = text.slice(0, 65536)
    clipboard.running = false
    clipboard.payload = text
    clipboard.stdinEnabled = true
    clipboard.running = true
    actionStatus = "Copied " + (label || "") + ": " + text
    actionStatusTimer.restart()
  }

  // wl-copy gets the text on stdin (argv is world-readable in /proc) and
  // detaches itself to serve the selection; closing stdin is the EOF it waits for.
  Process {
    id: clipboard
    property string payload: ""
    command: [root.clipboardBin]
    stdinEnabled: true
    onStarted: {
      write(payload)
      payload = ""
      stdinEnabled = false
    }
  }
  Timer {
    id: clipboardDeadline
    interval: 5000
    repeat: false
    running: clipboard.running
    onTriggered: clipboard.running = false
  }

  function ensureVisible(item) {
    if (!item || !scrollArea.contentItem) return
    var flick = scrollArea.contentItem
    var y = item.mapToItem(panelColumn, 0, 0).y
    if (y < flick.contentY) flick.contentY = Math.max(0, y - Style.space(8))
    else if (y + item.height > flick.contentY + flick.height) flick.contentY = Math.max(0, y + item.height - flick.height + Style.space(8))
  }

  // --------------------------------------------------------------- charts
  // Turn the cumulative counters in `history` into per-bucket average rates
  // (bytes/s) for one interface over the last `rangeSec` seconds. Counter
  // resets (negative delta) and long gaps (bar was not running) become nulls
  // so the chart shows a break instead of a spike.
  function seriesFor(dev, rangeSec, buckets) {
    var now = Date.now() / 1000
    var start = now - rangeSec
    var rx = [], tx = [], cnt = []
    for (var b = 0; b < buckets; b++) { rx.push(0); tx.push(0); cnt.push(0) }
    var prev = null
    var bytesRx = 0, bytesTx = 0, n = 0, firstTs = 0
    var list = history || []
    for (var i = 0; i < list.length; i++) {
      var entry = list[i]
      if (!entry || entry.length < 2) continue
      var t = Number(entry[0])
      var c = entry[1] ? entry[1][dev] : null
      if (!c) { prev = null; continue }
      if (prev) {
        var dt = t - prev.t
        if (dt > 0 && dt < 900) {
          var drx = c[0] - prev.rx, dtx = c[1] - prev.tx
          if (drx >= 0 && dtx >= 0 && t >= start) {
            var idx = Math.floor((t - start) / rangeSec * buckets)
            if (idx >= buckets) idx = buckets - 1
            if (idx < 0) idx = 0
            rx[idx] += drx / dt; tx[idx] += dtx / dt; cnt[idx] += 1
            bytesRx += drx; bytesTx += dtx; n += 1
            if (!firstTs) firstTs = prev.t
          }
        }
      }
      prev = { t: t, rx: c[0], tx: c[1] }
    }
    var max = 0
    for (var k = 0; k < buckets; k++) {
      if (cnt[k] > 0) { rx[k] /= cnt[k]; tx[k] /= cnt[k]; if (rx[k] > max) max = rx[k]; if (tx[k] > max) max = tx[k] }
      else { rx[k] = null; tx[k] = null }
    }
    return { rx: rx, tx: tx, max: max, start: start, end: now, bytesRx: bytesRx, bytesTx: bytesTx, n: n, firstTs: firstTs }
  }
  readonly property var rangeOptions: [{ sec: 3600, label: "1h" }, { sec: 21600, label: "6h" }, { sec: 86400, label: "24h" }]
  function rangeLabel(sec) {
    for (var i = 0; i < rangeOptions.length; i++) if (rangeOptions[i].sec === sec) return rangeOptions[i].label
    return Math.round(sec / 3600) + "h"
  }
  function fmtClock(ts) { return Qt.formatTime(new Date(ts * 1000), "HH:mm") }

  // ----------------------------------------------------------- text builders
  function ifaceSubtitle(f) {
    var parts = []
    if (f.ip) parts.push(f.ip)
    if (f.gateway) parts.push("gw " + f.gateway)
    if (f.kind === "wifi" && f.wifi && f.wifi.signal) parts.push("signal " + f.wifi.signal + "%")
    if (f.connCount > 0) parts.push(connWord(f.connCount))
    if (!f.active) parts.push(f.carrier ? "inactive" : "no carrier")
    return parts.join(" · ")
  }

  function tunnelOneLiner(f) {
    var t = f.tunnel
    if (!t) return ""
    if (f.kind === "tailscale") {
      var online = 0, active = 0
      for (var i = 0; i < (t.peers || []).length; i++) { if (t.peers[i].online) online++; if (t.peers[i].active) active++ }
      var s = t.state + " · " + (t.peers || []).length + " peers, " + online + " online"
      if (active > 0) s += ", " + active + " active"
      if (t.self && t.self.relay) s += " · relay " + t.self.relay
      if (t.exitNode) s += " · exit node " + (t.exitNode.name || t.exitNode.ips.join(","))
      return s
    }
    if (f.kind === "zerotier") {
      if (!t.available) return "needs a one-time setup (see below)"
      var n = t.network
      var z = n ? (n.name || n.id) + " · " + n.status : "unknown network"
      if (t.peers) z += " · " + t.peers.length + " peers"
      return z
    }
    if (f.kind === "wireguard") {
      var peers = t.peers || []
      var w = peers.length + " peer" + (peers.length === 1 ? "" : "s")
      for (var p = 0; p < peers.length; p++) {
        if (peers[p].endpoint) { w += " · " + peers[p].endpoint; break }
      }
      for (var q = 0; q < peers.length; q++) {
        if (peers[q].handshakeAge !== undefined && peers[q].handshakeAge !== null) { w += " · handshake " + fmtAge(peers[q].handshakeAge) + " ago"; break }
      }
      return w
    }
    if (f.kind === "openvpn" || f.kind === "vpn") {
      return (t.name || "") + (t.remote ? " → " + t.remote : "")
    }
    return ""
  }

  function ifaceTooltip(f) {
    var r = rateOf(f.name)
    var lines = [kindGlyph(f.kind) + " " + f.name + " — " + f.label]
    lines.push("↓ " + fmtRate(r.rx) + "  ↑ " + fmtRate(r.tx) + "   total ↓ " + fmtBytes(f.rx) + " ↑ " + fmtBytes(f.tx))
    if (f.addrs.length > 0 || f.addrs6.length > 0) lines.push("Addresses: " + f.addrs.concat(f.addrs6).join(", "))
    if (f.gateway) lines.push("Gateway: " + f.gateway + (f.isDefault ? " (default route)" : ""))
    if (f.dns.length > 0) lines.push("DNS: " + f.dns.join(", ") + (f.dnsDefaultRoute ? " (default)" : ""))
    var t = tunnelOneLiner(f)
    if (t) lines.push(t)
    if (f.connByProc.length > 0) {
      var parts = []
      for (var i = 0; i < Math.min(5, f.connByProc.length); i++) parts.push(f.connByProc[i].proc + " ×" + f.connByProc[i].count)
      lines.push("Services: " + parts.join(", ") + (f.connByProc.length > 5 ? ", …" : ""))
    }
    lines.push("Click to expand routes, peers and connections")
    return lines.join("\n")
  }

  function ifaceDetailLines(f) {
    var lines = []
    var all = f.addrs.concat(f.addrs6)
    lines.push({ t: "Addresses: " + (all.length ? all.join(", ") : "none"), k: "info" })
    var hw = []
    if (f.mtu) hw.push("MTU " + f.mtu)
    if (f.mac) hw.push("MAC " + f.mac)
    if (f.nmConnection) hw.push("NM: " + f.nmConnection)
    if (f.kind === "wifi" && f.wifi) hw.push(f.wifi.freq + (f.wifi.rate ? ", " + f.wifi.rate : ""))
    if (hw.length) lines.push({ t: hw.join(" · "), k: "info" })
    lines.push({ t: "Counters: ↓ " + fmtBytes(f.rx) + " (" + f.rxPackets + " pkt) ↑ " + fmtBytes(f.tx) + " (" + f.txPackets + " pkt)" + (f.rxDrop || f.txDrop ? " · drop " + f.rxDrop + "/" + f.txDrop : ""), k: "info" })
    if (f.dns.length > 0) lines.push({ t: "DNS: " + f.dns.join(", ") + (f.dnsDefaultRoute ? " · default resolver" : "") + (f.dnsDomains.length ? " · domains " + f.dnsDomains.join(", ") : "") + (f.dnsRoutingDomains ? " · " + f.dnsRoutingDomains + " routing domains" : ""), k: "info" })

    if (f.routes.length > 0) {
      lines.push({ t: "Routes via " + f.name + ":", k: "head" })
      for (var i = 0; i < f.routes.length; i++) {
        var r = f.routes[i]
        var s = (r.dst === "default" ? "default (all internet)" : r.dst)
        if (r.gateway) s += " via " + r.gateway
        var tags = []
        if (r.table !== "main") tags.push("table " + r.table)
        if (r.protocol && r.protocol !== "boot") tags.push(r.protocol)
        if (r.metric !== null && r.metric !== undefined) tags.push("metric " + r.metric)
        if (tags.length) s += "  [" + tags.join(", ") + "]"
        lines.push({ t: s, k: "item" })
      }
      if (f.moreRoutes > 0) lines.push({ t: "… and " + f.moreRoutes + " more", k: "item" })
    }

    var t = f.tunnel
    if (f.kind === "tailscale" && t) {
      lines.push({ t: "Tailscale:", k: "head" })
      if (t.self) lines.push({ t: "Me: " + t.self.name + " " + (t.self.ips || []).join(", ") + (t.self.dns ? " · " + t.self.dns : "") + (t.self.relay ? " · DERP " + t.self.relay : ""), k: "item" })
      if (t.tailnet) lines.push({ t: "Tailnet: " + t.tailnet + (t.magicDns ? " · MagicDNS " + t.magicDns : ""), k: "item" })
      lines.push({ t: "Exit node: " + (t.exitNode ? (t.exitNode.name || t.exitNode.ips.join(",")) + (t.exitNode.online ? " (online)" : " (offline!)") : "none — internet leaves locally"), k: "item" })
      var peers = t.peers || []
      if (peers.length) lines.push({ t: "Peers (" + peers.length + "):", k: "head" })
      for (var p = 0; p < peers.length; p++) {
        var pe = peers[p]
        var ps = (pe.online ? "●" : "○") + " " + pe.name + "  " + pe.ip
        if (pe.os) ps += " · " + pe.os
        if (pe.active) ps += " · ACTIVE " + (pe.curAddr ? "direct " + pe.curAddr : "via relay " + pe.relay)
        else if (pe.online && pe.relay) ps += " · relay " + pe.relay
        if (pe.rx || pe.tx) ps += " · ↓" + fmtBytes(pe.rx) + " ↑" + fmtBytes(pe.tx)
        if (pe.exitNode) ps += " · EXIT NODE"
        else if (pe.exitNodeOption) ps += " · can be exit node"
        if (pe.primaryRoutes && pe.primaryRoutes.length) ps += " · advertises " + pe.primaryRoutes.join(", ")
        lines.push({ t: ps, k: "item", dim: !pe.online })
      }
      for (var h = 0; h < (t.health || []).length; h++) lines.push({ t: "⚠ " + t.health[h], k: "warn" })
    } else if (f.kind === "zerotier" && t) {
      lines.push({ t: "ZeroTier:", k: "head" })
      if (!t.available) {
        lines.push({ t: t.hint || "zerotier-cli is not accessible.", k: "warn" })
      } else {
        var n = t.network
        if (n) {
          lines.push({ t: "Network: " + (n.name || "(unnamed)") + " · " + n.id + " · " + n.status + " · " + n.type, k: "item" })
          if (n.addrs.length) lines.push({ t: "Assigned: " + n.addrs.join(", "), k: "item" })
          var flags = []
          if (n.allowManaged) flags.push("managed routes")
          if (n.allowGlobal) flags.push("global")
          if (n.allowDefault) flags.push("DEFAULT ROUTE via ZT")
          if (n.bridge) flags.push("bridge")
          if (flags.length) lines.push({ t: "Flags: " + flags.join(", "), k: "item" })
          if (n.dns && n.dns.length) lines.push({ t: "Network DNS: " + n.dns.join(", "), k: "item" })
          if (n.routes.length) {
            lines.push({ t: "Managed routes (" + n.routes.length + "):", k: "head" })
            for (var zr = 0; zr < n.routes.length; zr++) lines.push({ t: n.routes[zr].target + (n.routes[zr].via ? " via " + n.routes[zr].via : " (local)"), k: "item" })
          }
        }
        var zp = t.peers || []
        lines.push({ t: "Peers: " + zp.length + " leaf" + (t.rootCount ? " · " + t.rootCount + " root (" + t.rootsDirect + " direct)" : ""), k: "head" })
        for (var z = 0; z < zp.length; z++) {
          var zz = zp[z]
          var path = ""
          for (var pa = 0; pa < zz.paths.length; pa++) if (zz.paths[pa].active) { path = zz.paths[pa].address; break }
          lines.push({ t: zz.address + "  " + (zz.latency >= 0 ? zz.latency + " ms" : "?") + "  " + (path ? "direct " + path : "via relay") + (zz.version && zz.version !== "-1.-1.-1" ? " · v" + zz.version : ""), k: "item" })
        }
      }
    } else if (f.kind === "wireguard" && t) {
      lines.push({ t: "WireGuard" + (t.nmName ? " (" + t.nmName + ")" : "") + (t.listenPort ? " · port " + t.listenPort : "") + ":", k: "head" })
      var wp = t.peers || []
      if (!wp.length) lines.push({ t: "No peer data (needs `wg show` access or a NetworkManager connection)", k: "warn" })
      for (var w = 0; w < wp.length; w++) {
        var ww = wp[w]
        var ws = (ww.endpoint ? "→ " + ww.endpoint : "→ (no endpoint)")
        if (ww.allowedIps && ww.allowedIps.length) ws += " · allowed " + ww.allowedIps.join(", ")
        if (ww.handshakeAge !== undefined && ww.handshakeAge !== null) ws += " · handshake " + fmtAge(ww.handshakeAge) + " ago"
        else if (ww.source === "wg") ws += " · no handshake yet"
        if (ww.rx || ww.tx) ws += " · ↓" + fmtBytes(ww.rx) + " ↑" + fmtBytes(ww.tx)
        if (ww.keepalive && ww.keepalive !== "off" && ww.keepalive !== "0") ws += " · keepalive " + ww.keepalive
        lines.push({ t: ws, k: "item" })
        if (ww.publicKey) lines.push({ t: "   key " + ww.publicKey, k: "item", dim: true })
      }
    } else if ((f.kind === "openvpn" || f.kind === "vpn") && t) {
      lines.push({ t: (f.kind === "openvpn" ? "OpenVPN" : "VPN") + ": " + (t.name || "") + (t.remote ? " → " + t.remote : "") + (t.pid ? " · pid " + t.pid : ""), k: "head" })
    }

    var conns = []
    var all2 = snap.connections || []
    for (var c = 0; c < all2.length; c++) if (all2[c].dev === f.name) conns.push(all2[c])
    if (conns.length > 0) {
      lines.push({ t: "Connections via " + f.name + " (" + conns.length + "):", k: "head" })
      var byProc = {}
      var order = []
      for (var c2 = 0; c2 < conns.length; c2++) {
        var cc = conns[c2]
        if (!byProc[cc.proc]) { byProc[cc.proc] = {}; order.push(cc.proc) }
        var key = cc.remote + (cc.rname ? " (" + cc.rname + ")" : "")
        byProc[cc.proc][key] = (byProc[cc.proc][key] || 0) + 1
      }
      for (var o = 0; o < order.length; o++) {
        var rem = byProc[order[o]]
        var keys = Object.keys(rem).sort(function(a, b) { return rem[b] - rem[a] })
        var shown = []
        for (var kk = 0; kk < Math.min(6, keys.length); kk++) shown.push(keys[kk] + (rem[keys[kk]] > 1 ? " ×" + rem[keys[kk]] : ""))
        lines.push({ t: order[o] + ": " + shown.join(", ") + (keys.length > 6 ? ", … +" + (keys.length - 6) : ""), k: "item" })
      }
    }
    return lines
  }

  function procSubtitle(p) {
    var parts = []
    for (var i = 0; i < p.byDev.length; i++) parts.push(p.byDev[i].dev + " ×" + p.byDev[i].count)
    var s = parts.join(" · ")
    if (p.guessed) s += " · name guessed from port"
    return s
  }

  function procTooltip(p) {
    var lines = [p.name + " — " + connWord(p.count) + (p.pids.length ? " · pid " + p.pids.slice(0, 3).join(",") : "")]
    lines.push(procSubtitle(p))
    for (var i = 0; i < Math.min(8, p.remotes.length); i++) {
      var r = p.remotes[i]
      lines.push("→ " + remoteLabel(r) + (r.count > 1 ? " ×" + r.count : "") + " · " + r.dev + " " + r.proto)
    }
    if (p.remotes.length > 8) lines.push("… +" + (p.remotes.length - 8) + " more addresses (click)")
    return lines.join("\n")
  }

  function procDetailLines(p) {
    var lines = []
    for (var i = 0; i < p.remotes.length; i++) {
      var r = p.remotes[i]
      lines.push({ t: "→ " + remoteLabel(r) + (r.count > 1 ? " ×" + r.count : "") + "  · " + r.proto + " via " + r.dev, k: "item" })
    }
    if (p.moreRemotes > 0) lines.push({ t: "… and " + p.moreRemotes + " more", k: "item" })
    return lines
  }

  function listenScopeLabel(l) {
    if (l.scope === "all") return "all interfaces"
    if (l.scope === "lo") return "localhost only"
    return l.scope + " (" + l.addr + ")"
  }

  readonly property string egressLine: {
    if (!loaded) return "Collecting…"
    if (!egress4) return "No IPv4 default route"
    var d = defaultIface
    return "Internet → " + egress4.dev + (d ? " · " + d.label : "") + (egress4.gateway ? " · " + egress4.gateway : "")
  }

  readonly property string footerAge: {
    clockTick
    if (!lastSampleMs) return ""
    return "refreshed " + fmtAge((Date.now() - lastSampleMs) / 1000) + " ago" + (snap.tookMs ? " · " + snap.tookMs + " ms" : "")
  }

  // ---------------------------------------------------------------- panel
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(660))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0 && root.cursorActive) {
          var row = root.rowAt(root.cursorIndex)
          if (row.section === "iface") { if ((dx > 0) !== root.isExpanded("if:" + row.item.name)) root.toggleExpanded("if:" + row.item.name) }
          else if (row.section === "proc") { if ((dx > 0) !== root.isExpanded("proc:" + row.item.name)) root.toggleExpanded("proc:" + row.item.name) }
        }
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (t === "r") { root.forcePublic = true; root.refresh() }
        else if (t === "c") root.copyCursor()
        else if (t === "l") root.showListeners = !root.showListeners
        else if (t === "e") root.setAllExpanded(true)
        else if (t === "w") root.setAllExpanded(false)
        else if (t === "1") root.chartRange = 3600
        else if (t === "2") root.chartRange = 21600
        else if (t === "3") root.chartRange = 86400
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          value: panelColumn.implicitHeight > scrollArea.height
        }

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(10)

          PanelHero {
            iconComponent: Component {
              Text {
                textFormat: Text.PlainText
                text: root.mainGlyph
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            title: "Bananet"
            meta: root.egressLine
            detail: root.loaded ? (root.tunnelsActive > 0 ? root.plural(root.tunnelsActive, "tunnel", "tunnels") : "no tunnels") : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // ---------- Egress ----------
          Column {
            width: parent.width
            spacing: Style.space(4)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader { text: "Egress"; foreground: root.foreground; fontFamily: root.fontFamily }

            InfoLine { label: "IPv4"; value: root.egress4 ? (root.egress4.dev + (root.egress4.gateway ? " → " + root.egress4.gateway : " (no gateway)") + (root.egress4.src ? "  from " + root.egress4.src : "") + (root.egress4.table && root.egress4.table !== "main" ? "  [table " + root.egress4.table + "]" : "")) : (root.loaded ? "no route" : "…") }
            InfoLine { label: "IPv6"; value: root.egress6 ? (root.egress6.dev + (root.egress6.gateway ? " → " + root.egress6.gateway : "") + (root.egress6.src ? "  from " + root.egress6.src : "")) : "no route (IPv4 only)"; dimValue: !root.egress6 }
            InfoLine { visible: !!root.egress.exitNode; label: "Exit"; value: root.egress.exitNode ? ("Tailscale exit node " + (root.egress.exitNode.name || (root.egress.exitNode.ips || []).join(",")) + (root.egress.exitNode.online ? "" : " — OFFLINE")) : ""; urgentValue: root.egress.exitNode ? !root.egress.exitNode.online : false }
            InfoLine { label: "DNS"; value: root.egress.dns && root.egress.dns.length ? root.egress.dns.join(", ") + (root.egress.dnsDev ? "  via " + root.egress.dnsDev : "") : (root.loaded ? "none" : "…") }
            InfoLine { visible: root.publicIp; label: "Public"; value: root.pub ? root.publicText : (root.loaded ? "checking…" : "…"); dimValue: !root.pub || !root.pub.available || !!root.pub.stale; urgentValue: !!(root.pub && root.pub.available === false && root.pub.error) }

            Repeater {
              model: JSON.parse(root.warningsJson)
              delegate: Text {
                textFormat: Text.PlainText
                required property var modelData
                width: panelColumn.width
                text: "⚠ " + modelData
                color: root.urgent
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                wrapMode: Text.WordWrap
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.lastError !== ""
              width: parent.width
              text: "⚠ " + root.lastError
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          // ---------- Interfaces ----------
          Column {
            width: parent.width
            spacing: Style.space(2)

            PanelSeparator { foreground: root.foreground }
            Item {
              width: parent.width
              implicitHeight: Math.max(ifaceHeader.implicitHeight, rangeRow.implicitHeight)
              PanelSectionHeader { id: ifaceHeader; text: "Interfaces & tunnels"; foreground: root.foreground; fontFamily: root.fontFamily; anchors.left: parent.left; anchors.verticalCenter: parent.verticalCenter }
              Row {
                id: rangeRow
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(4)
                Text {
                  textFormat: Text.PlainText
                  text: "chart:"
                  color: root.dimmer
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
                Repeater {
                  model: root.rangeOptions
                  delegate: RangePill {
                    required property var modelData
                    rangeSec: modelData.sec
                    label: modelData.label
                  }
                }
              }
            }

            Repeater {
              model: root.ifaceKeys
              delegate: Column {
                id: ifaceEntry
                required property var modelData
                required property int index
                readonly property var iface: root.ifaceMap[modelData] || null
                readonly property var setupItem: root.setupFor(iface ? iface.kind : "")
                visible: iface !== null
                width: panelColumn.width
                spacing: Style.space(4)

                IfaceRow {
                  iface: ifaceEntry.iface
                  rowIndex: index
                  width: panelColumn.width
                }
                SetupRow {
                  visible: setupItem !== null
                  item: setupItem
                  width: panelColumn.width - Style.space(30)
                  anchors.right: parent.right
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.loaded && root.ifaceKeys.length === 0
              text: "No interfaces"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // ---------- Services / connections ----------
          Column {
            width: parent.width
            spacing: Style.space(2)

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader {
              text: "Services → addresses" + (root.snap.connections ? " (" + root.snap.connections.length + ")" : "")
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.procKeys
              delegate: ProcRow {
                required property var modelData
                required property int index
                proc: root.procMap[modelData] || null
                visible: proc !== null
                rowIndex: root.ifaceKeys.length + index
                width: panelColumn.width
              }
            }

            Text {
              textFormat: Text.PlainText
              visible: root.loaded && root.procKeys.length === 0
              text: "No active outgoing connections"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
            }
          }

          // ---------- Listeners ----------
          Column {
            width: parent.width
            spacing: Style.space(2)

            PanelSeparator { foreground: root.foreground }

            CursorSurface {
              id: listenHeader
              width: parent.width
              implicitHeight: listenHeaderRow.implicitHeight + Style.space(8)
              hasCursor: root.cursorActive && root.cursorIndex === root.listenHeaderIndex
              foreground: root.foreground
              fill: root.hoverFill
              onHasCursorChanged: if (hasCursor) root.ensureVisible(listenHeader)

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onEntered: root.setCursor(root.listenHeaderIndex)
                onClicked: root.showListeners = !root.showListeners
              }

              Row {
                id: listenHeaderRow
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.leftMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(6)

                Text {
                  textFormat: Text.PlainText
                  text: root.showListeners ? "󰅀" : "󰅂"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }
                PanelSectionHeader {
                  text: "Listening services" + (root.snap.listeners ? " (" + root.snap.listeners.length + ")" : "")
                  foreground: root.foreground
                  fontFamily: root.fontFamily
                  topPadding: 0
                }
              }
            }

            Repeater {
              model: root.listenKeys
              delegate: ListenRow {
                required property var modelData
                required property int index
                listener: root.listenMap[modelData] || null
                visible: listener !== null
                rowIndex: root.listenHeaderIndex + 1 + index
                width: panelColumn.width
              }
            }
          }

          // ---------- Optional privileges ----------
          Column {
            width: parent.width
            spacing: Style.space(2)
            visible: minorSetupRepeater.count > 0

            PanelSeparator { foreground: root.foreground }
            PanelSectionHeader { text: "Optional privileges"; foreground: root.foreground; fontFamily: root.fontFamily }

            Repeater {
              id: minorSetupRepeater
              model: JSON.parse(root.minorSetupJson)
              delegate: SetupRow {
                required property var modelData
                item: modelData
                minor: true
                width: panelColumn.width
              }
            }
          }

          // ---------- Footer ----------
          Column {
            width: parent.width
            spacing: Style.space(2)

            PanelSeparator { foreground: root.foreground }

            Text {
              textFormat: Text.PlainText
              visible: root.actionStatus !== ""
              width: parent.width
              text: root.actionStatus
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: "j/k move · enter/→ expand · 1/2/3 chart range · c copy · r refresh · l listeners · e/w expand/collapse all · esc"
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              visible: root.toolsText !== ""
              width: parent.width
              text: root.toolsText
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              text: (root.refreshing ? "refreshing… · " : "") + root.footerAge
              color: root.dimmer
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }
        }
      }
    }
  }

  // ------------------------------------------------------------- components
  component InfoLine: Row {
    property string label: ""
    property string value: ""
    property bool dimValue: false
    property bool urgentValue: false
    width: parent ? parent.width : implicitWidth
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: label
      width: Style.space(44)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }
    Text {
      textFormat: Text.PlainText
      width: parent.width - Style.space(44) - Style.space(8)
      text: value
      color: urgentValue ? root.urgent : (dimValue ? root.dim : root.foreground)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.WrapAnywhere
    }
  }

  component DetailLines: Column {
    property var lines: []
    width: parent ? parent.width : implicitWidth
    spacing: Style.space(1)

    Repeater {
      model: lines
      delegate: Text {
        textFormat: Text.PlainText
        required property var modelData
        width: parent.width
        leftPadding: modelData.k === "item" ? Style.space(14) : 0
        topPadding: modelData.k === "head" ? Style.space(4) : 0
        text: modelData.t
        color: modelData.k === "warn" ? root.urgent : (modelData.k === "head" ? root.foreground : (modelData.dim ? root.dimmer : root.dim))
        font.family: root.fontFamily
        font.pixelSize: modelData.k === "head" ? Style.font.bodySmall : Style.font.caption
        font.bold: modelData.k === "head"
        wrapMode: Text.WrapAnywhere
      }
    }
  }

  component IfaceRow: CursorSurface {
    id: ifaceRow
    property var iface: null
    property int rowIndex: 0
    readonly property string key: "if:" + (iface ? iface.name : "")
    readonly property bool expandedRow: root.isExpanded(key)
    readonly property var rate: iface ? root.rateOf(iface.name) : { rx: 0, tx: 0 }
    readonly property bool inactive: iface && !iface.active

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    current: iface && iface.isDefault
    foreground: root.foreground
    fill: root.hoverFill
    currentFill: root.selectedFill
    implicitHeight: ifaceInner.implicitHeight + Style.space(10)
    onHasCursorChanged: if (hasCursor) root.ensureVisible(ifaceRow)

    MouseArea {
      id: ifaceMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onEntered: root.setCursor(ifaceRow.rowIndex)
      onClicked: function(mouse) {
        if (!ifaceRow.iface) return
        if (mouse.button === Qt.RightButton) root.copyText(ifaceRow.iface.ip, ifaceRow.iface.name + " IP")
        else root.toggleExpanded(ifaceRow.key)
      }

      PanelToolTip {
        visible: ifaceMouse.containsMouse && !ifaceRow.expandedRow && ifaceRow.iface !== null
        text: ifaceRow.iface ? root.plain(root.ifaceTooltip(ifaceRow.iface)) : ""
        fontFamily: root.fontFamily
      }
    }

    Column {
      id: ifaceInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      // One line: kind · name · label · [INTERNET] · ip/gw/signal/conns … rates · chevron
      RowLayout {
        width: parent.width
        spacing: Style.space(6)

        Text {
          textFormat: Text.PlainText
          text: ifaceRow.iface ? root.kindGlyph(ifaceRow.iface.kind) : ""
          color: ifaceRow.inactive ? root.dimmer : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          Layout.preferredWidth: Style.space(20)
          horizontalAlignment: Text.AlignHCenter
          Layout.alignment: Qt.AlignVCenter
        }
        Text {
          textFormat: Text.PlainText
          text: ifaceRow.iface ? ifaceRow.iface.name : ""
          color: ifaceRow.inactive ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          Layout.alignment: Qt.AlignVCenter
        }
        Text {
          textFormat: Text.PlainText
          text: ifaceRow.iface ? ifaceRow.iface.label : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          elide: Text.ElideRight
          Layout.maximumWidth: Style.space(170)
          Layout.alignment: Qt.AlignVCenter
        }
        BorderSurface {
          visible: ifaceRow.iface && ifaceRow.iface.isDefault
          implicitWidth: pillText.implicitWidth + Style.space(8)
          implicitHeight: pillText.implicitHeight + Style.space(2)
          Layout.alignment: Qt.AlignVCenter
          color: "transparent"
          borderSpec: Border.controlSpec("normal", root.foreground, Color.accent)
          radius: Style.cornerRadius
          Text {
            textFormat: Text.PlainText
            id: pillText
            anchors.centerIn: parent
            text: "INTERNET"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            font.bold: true
          }
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: ifaceRow.iface ? root.ifaceSubtitle(ifaceRow.iface) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          Layout.alignment: Qt.AlignVCenter
        }
        Text {
          textFormat: Text.PlainText
          visible: !ifaceRow.inactive
          text: "↓ " + root.fmtRate(ifaceRow.rate.rx) + "  ↑ " + root.fmtRate(ifaceRow.rate.tx)
          color: (ifaceRow.rate.rx > 0 || ifaceRow.rate.tx > 0) ? root.foreground : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignVCenter
        }
        Text {
          textFormat: Text.PlainText
          text: ifaceRow.expandedRow ? "󰅀" : "󰅂"
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          Layout.alignment: Qt.AlignVCenter
        }
      }

      // Full-width chart: a slim sparkline while collapsed, the full chart with
      // axis and legend once expanded.
      TrafficChart {
        id: rowChart
        visible: !ifaceRow.inactive
        width: parent.width
        height: ifaceRow.expandedRow ? Style.space(96) : Style.space(28)
        mini: !ifaceRow.expandedRow
        series: ifaceRow.inactive || !ifaceRow.iface ? null : root.seriesFor(ifaceRow.iface.name, root.chartRange, Math.max(20, Math.min(Math.floor(width / 3), Math.floor(root.chartRange / 60))))
        Behavior on height { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }
      }

      Text {
        textFormat: Text.PlainText
        visible: ifaceRow.expandedRow && !ifaceRow.inactive
        width: parent.width
        text: {
          var sr = rowChart.series
          if (!sr || sr.n === 0) return "History is recorded while the bar runs (every 30 s, up to 24 h). No samples for this range yet."
          var t = "Last " + root.rangeLabel(root.chartRange) + ": ↓ " + root.fmtBytes(sr.bytesRx) + " ↑ " + root.fmtBytes(sr.bytesTx) + " · peak " + root.fmtRate(sr.max)
          if (sr.firstTs > sr.start + 120) t += " · data since " + root.fmtClock(sr.firstTs)
          return t
        }
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        wrapMode: Text.WordWrap
      }

      DetailLines {
        visible: ifaceRow.expandedRow
        width: parent.width
        readonly property string detailJson: ifaceRow.expandedRow && ifaceRow.iface ? JSON.stringify(root.ifaceDetailLines(ifaceRow.iface)) : "[]"
        lines: JSON.parse(detailJson)
      }
    }
  }

  component RangePill: BorderSurface {
    id: pill
    property int rangeSec: 3600
    property string label: ""
    readonly property bool current: root.chartRange === rangeSec
    implicitWidth: pillLabel.implicitWidth + Style.space(10)
    implicitHeight: pillLabel.implicitHeight + Style.space(4)
    radius: Style.cornerRadius
    color: current ? root.selectedFill : (pillMouse.containsMouse ? root.hoverFill : "transparent")
    borderSpec: Border.controlSpec(current ? "selected" : "normal", root.foreground, Color.accent)
    Text {
      textFormat: Text.PlainText
      id: pillLabel
      anchors.centerIn: parent
      text: pill.label
      color: pill.current ? root.foreground : root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: pill.current
    }
    MouseArea {
      id: pillMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: root.chartRange = pill.rangeSec
    }
  }

  // Rate-over-time chart drawn on a Canvas: download as a filled area, upload
  // as a line, breaks where no samples exist. `mini` is the in-row sparkline.
  component TrafficChart: Item {
    id: chart
    property var series: null
    property bool mini: false
    implicitHeight: mini ? Style.space(20) : Style.space(90)
    implicitWidth: mini ? Style.space(64) : Style.space(300)

    onSeriesChanged: canvas.requestPaint()
    onWidthChanged: canvas.requestPaint()
    onHeightChanged: canvas.requestPaint()
    // Canvas keeps its last bitmap, so a theme swap must trigger a repaint.
    Connections {
      target: root
      function onForegroundChanged() { canvas.requestPaint() }
      function onAccentColorChanged() { canvas.requestPaint() }
    }

    function tracePath(ctx, values, x0, w, y0, h, max, closeArea) {
      var n = values.length
      if (n === 0) return
      var step = w / n
      var open = false
      var lastX = 0, startX = 0
      for (var i = 0; i <= n; i++) {
        var v = i < n ? values[i] : null
        var x = x0 + (i + 0.5) * step
        if (v === null || v === undefined) {
          if (open) {
            if (closeArea) { ctx.lineTo(lastX, y0 + h); ctx.lineTo(startX, y0 + h); ctx.closePath() }
            open = false
          }
          continue
        }
        var y = y0 + h - (max > 0 ? (v / max) * h : 0)
        if (!open) {
          if (closeArea) { ctx.moveTo(x, y0 + h); ctx.lineTo(x, y) } else ctx.moveTo(x, y)
          startX = x
          open = true
        } else ctx.lineTo(x, y)
        lastX = x
      }
    }

    Canvas {
      id: canvas
      anchors.fill: parent
      antialiasing: true
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        ctx.clearRect(0, 0, width, height)
        var sr = chart.series
        var fg = root.foreground
        var pad = chart.mini ? 1 : Style.space(2)
        var labelH = chart.mini ? 0 : Style.space(12)
        var x0 = pad, w = width - pad * 2
        var y0 = pad, h = height - pad * 2 - labelH
        // baseline
        ctx.strokeStyle = Qt.rgba(fg.r, fg.g, fg.b, chart.mini ? 0.15 : 0.22)
        ctx.lineWidth = 1
        ctx.beginPath(); ctx.moveTo(x0, y0 + h + 0.5); ctx.lineTo(x0 + w, y0 + h + 0.5); ctx.stroke()
        if (!sr || sr.n === 0) {
          if (!chart.mini) {
            ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.45)
            ctx.font = Style.font.caption + "px " + root.fontFamily
            ctx.textAlign = "center"
            ctx.fillText("collecting history…", x0 + w / 2, y0 + h / 2 + 4)
          }
          return
        }
        var max = Math.max(sr.max, 1)
        // download: filled area + line
        var rxc = fg
        ctx.fillStyle = Qt.rgba(rxc.r, rxc.g, rxc.b, chart.mini ? 0.35 : 0.28)
        ctx.beginPath(); chart.tracePath(ctx, sr.rx, x0, w, y0, h, max, true); ctx.fill()
        ctx.strokeStyle = Qt.rgba(rxc.r, rxc.g, rxc.b, 0.95)
        ctx.lineWidth = chart.mini ? 1 : 1.5
        ctx.lineJoin = "round"
        ctx.beginPath(); chart.tracePath(ctx, sr.rx, x0, w, y0, h, max, false); ctx.stroke()
        // upload: line (+ faint area on the big chart)
        var txc = root.accentColor
        if (!chart.mini) {
          ctx.fillStyle = Qt.rgba(txc.r, txc.g, txc.b, 0.14)
          ctx.beginPath(); chart.tracePath(ctx, sr.tx, x0, w, y0, h, max, true); ctx.fill()
        }
        ctx.strokeStyle = Qt.rgba(txc.r, txc.g, txc.b, 0.95)
        ctx.lineWidth = chart.mini ? 1 : 1.5
        ctx.beginPath(); chart.tracePath(ctx, sr.tx, x0, w, y0, h, max, false); ctx.stroke()
        if (chart.mini) return
        // labels: peak at top-left, time ticks along the bottom
        ctx.font = Style.font.caption + "px " + root.fontFamily
        ctx.fillStyle = Qt.rgba(fg.r, fg.g, fg.b, 0.6)
        ctx.textAlign = "left"
        ctx.fillText("↓ download   ↑ upload   peak " + root.fmtRate(sr.max), x0 + 2, y0 + Style.font.caption)
        var ticks = 4
        for (var i = 0; i <= ticks; i++) {
          var frac = i / ticks
          var tx = x0 + frac * w
          ctx.textAlign = i === 0 ? "left" : (i === ticks ? "right" : "center")
          ctx.fillText(root.fmtClock(sr.start + frac * (sr.end - sr.start)), tx, y0 + h + labelH - 1)
          ctx.beginPath(); ctx.moveTo(Math.round(tx) + 0.5, y0 + h); ctx.lineTo(Math.round(tx) + 0.5, y0 + h + 3); ctx.stroke()
        }
      }
    }
  }

  // One-click fix for a tunnel that needs privileges before it can be inspected.
  // Left click opens a terminal running the command (sudo asks for the password
  // there), right click copies it, so the user never has to retype anything.
  component SetupRow: BorderSurface {
    id: setupRow
    property var item: null
    property bool minor: false
    readonly property color tint: minor ? root.foreground : root.urgent

    width: parent ? parent.width : implicitWidth
    implicitHeight: setupInner.implicitHeight + Style.space(12)
    radius: Style.cornerRadius
    color: setupMouse.containsMouse ? Style.hoverFillFor(tint, tint) : Util.alpha(tint, minor ? 0.03 : 0.07)
    borderSpec: Border.controlSpec(setupMouse.containsMouse ? "hover-cursor" : "normal", tint, tint)

    MouseArea {
      id: setupMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onClicked: function(mouse) {
        if (!setupRow.item) return
        if (mouse.button === Qt.RightButton) root.copyText(setupRow.item.command, "command")
        else root.runSetup(setupRow.item)
      }

      PanelToolTip {
        visible: setupMouse.containsMouse && setupRow.item !== null
        text: setupRow.item ? root.plain("Left click: open a terminal and install the rule\nRight click: copy the command\n\n" + setupRow.item.command) : ""
        fontFamily: root.fontFamily
      }
    }

    RowLayout {
      id: setupInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(8)
      anchors.rightMargin: Style.space(8)
      spacing: Style.space(10)

      Text {
        textFormat: Text.PlainText
        text: setupRow.minor ? "󰋽" : "󱄊"
        color: setupRow.tint
        font.family: root.fontFamily
        font.pixelSize: Style.font.heading
        Layout.alignment: Qt.AlignVCenter
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)

        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: setupRow.item ? setupRow.item.title : ""
          color: setupRow.minor ? root.foreground : root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          font.bold: true
          wrapMode: Text.WordWrap
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: setupRow.item ? setupRow.item.detail : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
        Text {
          textFormat: Text.PlainText
          Layout.fillWidth: true
          text: setupRow.item ? (setupRow.item.rule || setupRow.item.command) : ""
          color: setupRow.minor ? root.dim : root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WrapAnywhere
          topPadding: Style.space(2)
        }
      }

      Column {
        spacing: Style.space(4)
        Layout.alignment: Qt.AlignVCenter
        PanelActionButton {
          iconText: "󰆍"
          tooltipText: "Run in a terminal"
          foreground: setupRow.tint
          hoverColor: setupRow.tint
          onClicked: root.runSetup(setupRow.item)
        }
        PanelActionButton {
          iconText: "󰆏"
          tooltipText: "Copy command"
          foreground: setupRow.tint
          hoverColor: setupRow.tint
          onClicked: root.copyText(setupRow.item ? setupRow.item.command : "", "command")
        }
      }
    }
  }

  component ProcRow: CursorSurface {
    id: procRow
    property var proc: null
    property int rowIndex: 0
    readonly property string key: "proc:" + (proc ? proc.name : "")
    readonly property bool expandedRow: root.isExpanded(key)

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: procInner.implicitHeight + Style.space(10)
    onHasCursorChanged: if (hasCursor) root.ensureVisible(procRow)

    MouseArea {
      id: procMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.RightButton
      onEntered: root.setCursor(procRow.rowIndex)
      onClicked: function(mouse) {
        if (!procRow.proc) return
        if (mouse.button === Qt.RightButton && procRow.proc.remotes.length > 0) root.copyText(procRow.proc.remotes[0].addr, procRow.proc.name + " address")
        else root.toggleExpanded(procRow.key)
      }

      PanelToolTip {
        visible: procMouse.containsMouse && !procRow.expandedRow && procRow.proc !== null
        text: procRow.proc ? root.plain(root.procTooltip(procRow.proc)) : ""
        fontFamily: root.fontFamily
      }
    }

    Column {
      id: procInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(4)

      RowLayout {
        width: parent.width
        spacing: Style.space(8)

        Text {
          textFormat: Text.PlainText
          text: "󰆍"
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.title
          Layout.preferredWidth: Style.space(22)
          horizontalAlignment: Text.AlignHCenter
          Layout.alignment: Qt.AlignVCenter
        }

        ColumnLayout {
          Layout.fillWidth: true
          spacing: Style.space(1)
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: procRow.proc ? procRow.proc.name : ""
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            font.bold: true
            elide: Text.ElideRight
          }
          Text {
            textFormat: Text.PlainText
            Layout.fillWidth: true
            text: procRow.proc ? root.procSubtitle(procRow.proc) : ""
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }
        }

        Text {
          textFormat: Text.PlainText
          text: procRow.proc ? root.connWord(procRow.proc.count) : ""
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          Layout.alignment: Qt.AlignVCenter
        }

        Text {
          textFormat: Text.PlainText
          text: procRow.expandedRow ? "󰅀" : "󰅂"
          color: root.dimmer
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          Layout.alignment: Qt.AlignVCenter
        }
      }

      DetailLines {
        visible: procRow.expandedRow
        width: parent.width - Style.space(30)
        anchors.left: parent.left
        anchors.leftMargin: Style.space(30)
        readonly property string detailJson: procRow.expandedRow && procRow.proc ? JSON.stringify(root.procDetailLines(procRow.proc)) : "[]"
        lines: JSON.parse(detailJson)
      }
    }
  }

  component ListenRow: CursorSurface {
    id: listenRow
    property var listener: null
    property int rowIndex: 0

    hasCursor: root.cursorActive && root.cursorIndex === rowIndex
    foreground: root.foreground
    fill: root.hoverFill
    implicitHeight: listenInner.implicitHeight + Style.space(6)
    onHasCursorChanged: if (hasCursor) root.ensureVisible(listenRow)

    MouseArea {
      id: listenMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onEntered: root.setCursor(listenRow.rowIndex)
      onClicked: if (listenRow.listener) root.copyText(listenRow.listener.addr + ":" + listenRow.listener.port, "address")

      PanelToolTip {
        visible: listenMouse.containsMouse && listenRow.listener !== null
        text: listenRow.listener ? root.plain(listenRow.listener.proto + " " + listenRow.listener.addr + ":" + listenRow.listener.port + "\n" + root.listenScopeLabel(listenRow.listener) + (listenRow.listener.pid ? "\npid " + listenRow.listener.pid : "") + "\nClick to copy the address") : ""
        fontFamily: root.fontFamily
      }
    }

    Row {
      id: listenInner
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.leftMargin: Style.space(34)
      anchors.rightMargin: Style.space(6)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(8)

      Text {
        textFormat: Text.PlainText
        text: listenRow.listener ? listenRow.listener.proto : ""
        width: Style.space(28)
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
      Text {
        textFormat: Text.PlainText
        text: listenRow.listener ? ":" + listenRow.listener.port : ""
        width: Style.space(52)
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
      Text {
        textFormat: Text.PlainText
        text: listenRow.listener ? listenRow.listener.proc : ""
        width: Style.space(150)
        color: listenRow.listener && listenRow.listener.guessed ? root.dim : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
      Text {
        textFormat: Text.PlainText
        text: listenRow.listener ? root.listenScopeLabel(listenRow.listener) : ""
        color: listenRow.listener && listenRow.listener.scope === "lo" ? root.dimmer : root.dim
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        elide: Text.ElideRight
      }
    }
  }
}
