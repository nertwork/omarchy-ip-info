import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

Panel {
  id: root
  moduleName: "nertwork.ip-info"
  ipcTarget: "nertwork.ip-info"
  manageIpc: false

  property var localData: ({})
  property var publicData: ({})

  readonly property var displayModes: ["both", "private", "public", "icon"]
  property string displayMode: "both"

  readonly property string configFilePath: (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/settings/nertwork.ip-info.json"

  function normalizeMode(m) {
    if (!m) return "both"
    var lower = String(m).toLowerCase().trim()
    if (lower === "primary") return "private"
    if (displayModes.indexOf(lower) >= 0) return lower
    return "both"
  }

  function setDisplayMode(mode) {
    var norm = normalizeMode(mode)
    if (root.displayMode === norm) return
    root.displayMode = norm

    try {
      var cfg = {}
      var curText = configFile.text().trim()
      if (curText) {
        try { cfg = JSON.parse(curText) || {} } catch (_) { cfg = {} }
      }
      cfg.displayMode = norm
      configFile.setText(JSON.stringify(cfg, null, 2) + "\n")
    } catch (e) {
      console.warn("nertwork.ip-info: failed writing settings: " + e)
    }
  }

  function cycleDisplayMode() {
    var idx = displayModes.indexOf(root.displayMode)
    if (idx < 0) idx = 0
    var nextIdx = (idx + 1) % displayModes.length
    root.setDisplayMode(displayModes[nextIdx])
  }

  FileView {
    id: configFile
    path: root.configFilePath
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var raw = text().trim()
        if (raw) {
          var parsed = JSON.parse(raw)
          if (parsed && parsed.displayMode) {
            var norm = root.normalizeMode(parsed.displayMode)
            if (root.displayMode !== norm) {
              root.displayMode = norm
            }
          }
        }
      } catch (e) {
        console.warn("nertwork.ip-info: error parsing config.json: " + e)
      }
    }
  }

  onSettingsChanged: {
    var m = root.setting("displayMode", null)
    if (m) {
      var norm = normalizeMode(m)
      if (root.displayMode !== norm) root.displayMode = norm
    }
  }

  readonly property string scriptPath: {
    var url = String(Qt.resolvedUrl("bin/network-info.py"))
    if (url.indexOf("file://") === 0) {
      url = url.substring(7)
    }
    return decodeURIComponent(url)
  }

  // Extracted network data
  readonly property bool connected: localData && localData.connected === true
  readonly property var primaryInfo: localData && localData.primary ? localData.primary : ({})
  readonly property string privateIp: primaryInfo.ip || ""
  readonly property string primaryIface: primaryInfo.iface || ""
  readonly property string primaryType: primaryInfo.type || "ethernet"
  readonly property string gatewayIp: primaryInfo.gateway || ""
  readonly property string gatewayPing: primaryInfo.gatewayPingMs || ""
  readonly property string macAddress: primaryInfo.mac || ""
  readonly property string netmask: primaryInfo.netmask || ""
  readonly property string cidrPrefix: primaryInfo.prefix || ""

  readonly property var dnsServers: localData && localData.dns ? localData.dns : []
  readonly property var additionalInterfaces: {
    if (!localData || !localData.interfaces) return []
    return localData.interfaces.filter(function(i) {
      return !i.isPrimary && i.ip && (i.state === "UP" || !i.state)
    })
  }

  readonly property string publicIp: publicData && publicData.ip ? publicData.ip : ""
  readonly property string publicOrg: publicData && publicData.org ? publicData.org : ""
  readonly property string publicHostname: publicData && publicData.hostname ? publicData.hostname : ""
  readonly property string publicLocation: {
    if (!publicData) return ""
    var parts = []
    if (publicData.city) parts.push(publicData.city)
    if (publicData.region) parts.push(publicData.region)
    if (publicData.country) parts.push(publicData.country)
    return parts.join(", ")
  }

  readonly property bool refreshing: localProc.running || publicProc.running || publicForceProc.running

  property string copiedValue: ""
  property string copiedLabel: ""

  readonly property color contentForeground: bar ? bar.foreground : Color.foreground
  readonly property string contentFontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dimColor: Qt.darker(contentForeground, 1.4)
  readonly property color subDimColor: Qt.darker(contentForeground, 1.7)

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight
  readonly property real openPanelIndicatorWidth: button.labelWidth

  function copyToClipboard(val, label) {
    if (!val) return
    Quickshell.execDetached(["bash", "-c", "printf %s " + Util.shellQuote(val) + " | wl-copy"])
    root.copiedValue = val
    root.copiedLabel = label || val
    copiedTimer.restart()
  }

  function refreshAll(force) {
    if (!localProc.running) localProc.running = true
    if (force) {
      if (!publicForceProc.running) publicForceProc.running = true
    } else {
      if (!publicProc.running && !publicForceProc.running) publicProc.running = true
    }
  }

  Timer {
    id: copiedTimer
    interval: 2200
    repeat: false
    onTriggered: {
      root.copiedValue = ""
      root.copiedLabel = ""
    }
  }

  // Realtime kernel netlink watcher for address & route changes
  Process {
    id: netMonitorProc
    command: ["ip", "monitor", "address", "route"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        netDebounceTimer.restart()
      }
    }
    onExited: netMonitorRestartTimer.restart()
  }

  Timer {
    id: netMonitorRestartTimer
    interval: 2000
    repeat: false
    onTriggered: netMonitorProc.running = true
  }

  Timer {
    id: netDebounceTimer
    interval: 350
    repeat: false
    onTriggered: {
      if (!localProc.running) localProc.running = true
    }
  }

  // Fallback local network polling (every 30s)
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: {
      if (!localProc.running) localProc.running = true
    }
  }

  // Periodic public IP check (every 5 min)
  Timer {
    interval: 300000
    running: true
    repeat: true
    onTriggered: {
      if (!publicProc.running && !publicForceProc.running) publicProc.running = true
    }
  }

  onOpenedChanged: {
    if (opened) {
      if (!localProc.running) localProc.running = true
      if (!root.publicIp && !publicProc.running && !publicForceProc.running) {
        publicProc.running = true
      }
    }
  }

  Component.onCompleted: {
    var stateDir = (Quickshell.env("XDG_STATE_HOME") || (Quickshell.env("HOME") + "/.local/state")) + "/omarchy/settings"
    Quickshell.execDetached(["mkdir", "-p", stateDir])
    var fromShell = root.setting("displayMode", null)
    if (fromShell) {
      root.displayMode = root.normalizeMode(fromShell)
    }
    refreshAll(false)
  }

  IpcHandler {
    target: "nertwork.ip-info"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refreshAll(true) }
    function cycle(): void { root.cycleDisplayMode() }
    function setMode(mode: string): void { root.setDisplayMode(mode) }
    function getMode(): string { return root.displayMode }
  }

  Process {
    id: localProc
    command: ["python3", root.scriptPath, "--local"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          var prevIp = root.privateIp
          var prevGw = root.gatewayIp
          root.localData = parsed
          // If IP or default gateway changed, trigger immediate public IP re-probe
          if (prevIp && parsed && parsed.primary && (parsed.primary.ip !== prevIp || parsed.primary.gateway !== prevGw)) {
            if (!publicForceProc.running) publicForceProc.running = true
          }
        } catch (e) {
          console.warn("nertwork.ip-info: error parsing local data: " + e)
        }
      }
    }
  }

  Process {
    id: publicProc
    command: ["python3", root.scriptPath, "--public-cached"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.publicData = parsed
        } catch (e) {
          console.warn("nertwork.ip-info: error parsing public data: " + e)
        }
      }
    }
  }

  Process {
    id: publicForceProc
    command: ["python3", root.scriptPath, "--public"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var parsed = JSON.parse(text)
          root.publicData = parsed
        } catch (e) {
          console.warn("nertwork.ip-info: error parsing force public data: " + e)
        }
      }
    }
  }

  // Status bar widget representation
  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    fontSize: root.displayMode === "icon" ? Style.bar.iconFont : Style.font.caption
    text: {
      var priv = root.privateIp ? root.privateIp : "--"
      var pub = root.publicIp ? root.publicIp : "..."
      var netIcon = Model.typeIcon(root.primaryType)
      var pubIcon = Model.publicIcon()

      switch (root.displayMode) {
        case "private":
          return netIcon + " " + priv
        case "public":
          return pubIcon + " " + pub
        case "icon":
          return netIcon
        case "both":
        default:
          return netIcon + " " + priv + "  " + pubIcon + " " + pub
      }
    }
    tooltipText: {
      var tip = "Network IP Info (" + root.displayMode.toUpperCase() + ")\n"
      tip += "Private: " + (root.privateIp || "N/A") + " (" + (root.primaryIface || "none") + ")\n"
      tip += "Public:  " + (root.publicIp || "Fetching...") + "\n"
      if (root.gatewayIp) tip += "Gateway: " + root.gatewayIp + "\n"
      tip += "Left: Details • Middle: Refresh • Right: Cycle Display Mode"
      return tip
    }
    onPressed: function(b) {
      if (b === Qt.LeftButton) root.toggle()
      else if (b === Qt.MiddleButton) root.refreshAll(true)
      else if (b === Qt.RightButton) root.cycleDisplayMode()
    }
  }

  // Native Quickshell popover card
  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(mainColumn.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: mainColumn
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ----------------- Header / Hero Section -----------------
        Item {
          width: parent.width
          implicitHeight: Math.max(heroIcon.implicitHeight, heroLabels.implicitHeight, heroAction.implicitHeight)

          Text {
            id: heroIcon
            textFormat: Text.PlainText
            text: Model.typeIcon(root.primaryType)
            color: root.connected ? Color.accent : root.dimColor
            font.family: root.contentFontFamily
            font.pixelSize: Style.font.display
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            id: heroLabels
            anchors.left: heroIcon.right
            anchors.leftMargin: Style.space(12)
            anchors.right: heroAction.left
            anchors.rightMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: root.connected ? (root.primaryIface ? "Connected (" + root.primaryIface + ")" : "Network Connected") : "Disconnected"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: {
                var info = "GATEWAY: " + (root.gatewayIp || "--")
                if (root.gatewayPing) {
                  info += " · PING: " + Model.formatPing(root.gatewayPing)
                }
                return info.toUpperCase()
              }
              color: root.dimColor
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 0.8
              elide: Text.ElideRight
              width: parent.width
            }
          }

          PanelActionButton {
            id: heroAction
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            iconText: Model.refreshIcon()
            tooltipText: "Refresh Network & IP Info"
            hoverColor: Color.accent
            onClicked: root.refreshAll(true)

            RotationAnimation {
              target: heroAction
              property: "rotation"
              from: 0
              to: 360
              duration: 800
              loops: Animation.Infinite
              running: root.refreshing
            }
          }
        }

        // ----------------- Copied Feedback Banner -----------------
        Rectangle {
          visible: root.copiedValue !== ""
          width: parent.width
          height: Style.space(26)
          radius: Style.cornerRadius
          color: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.22)
          border.width: 1
          border.color: Color.accent

          Row {
            anchors.centerIn: parent
            spacing: Style.space(6)

            Text {
              text: Model.checkIcon()
              color: Color.accent
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Text {
              text: "Copied " + root.copiedLabel + " (" + root.copiedValue + ") to clipboard"
              color: root.contentForeground
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }
        }

        PanelSeparator { foreground: root.contentForeground }

        // ----------------- Bar Display Mode -----------------
        Item {
          width: parent.width
          implicitHeight: Math.max(displayHeader.implicitHeight, displayGroup.implicitHeight)

          PanelSectionHeader {
            id: displayHeader
            text: "BAR DISPLAY"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
          }

          ButtonGroup {
            id: displayGroup
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            options: [
              { value: "both", label: "Both" },
              { value: "private", label: "Private" },
              { value: "public", label: "Public" },
              { value: "icon", label: "Icon" }
            ]
            value: root.displayMode
            foreground: root.contentForeground
            background: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)
            accent: Color.accent
            fontFamily: root.contentFontFamily
            fontSize: Style.font.caption
            onChanged: function(v) {
              root.setDisplayMode(v)
            }
          }
        }

        PanelSeparator { foreground: root.contentForeground }

        // ----------------- Primary Private IP Card -----------------
        PanelSectionHeader {
          text: "PRIMARY PRIVATE IP"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        Rectangle {
          id: privateCard
          width: parent.width
          implicitHeight: privateRow.implicitHeight + Style.space(16)
          radius: Style.cornerRadius
          color: privateMouse.containsMouse
            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
            : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)
          border.width: 1
          border.color: privateMouse.containsMouse
            ? Color.accent
            : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.1)

          Behavior on color { ColorAnimation { duration: 100 } }
          Behavior on border.color { ColorAnimation { duration: 100 } }

          MouseArea {
            id: privateMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.copyToClipboard(root.privateIp, "Private IP")
          }

          Row {
            id: privateRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(12)

            Text {
              text: Model.typeIcon(root.primaryType)
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.title
              color: Color.accent
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              width: parent.width - Style.space(70)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Row {
                spacing: Style.space(8)

                Text {
                  text: root.privateIp ? root.privateIp + (root.cidrPrefix ? "/" + root.cidrPrefix : "") : "Not assigned"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }

                Rectangle {
                  visible: root.primaryIface !== ""
                  height: Style.space(16)
                  width: ifaceLabel.implicitWidth + Style.space(8)
                  radius: Style.space(3)
                  color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    id: ifaceLabel
                    anchors.centerIn: parent
                    text: root.primaryIface
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption
                    color: root.dimColor
                  }
                }
              }

              Text {
                text: {
                  var meta = []
                  if (root.netmask) meta.push("Mask: " + root.netmask)
                  if (root.macAddress) meta.push("MAC: " + root.macAddress)
                  return meta.join(" · ")
                }
                color: root.subDimColor
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.copiedValue === root.privateIp ? Model.checkIcon() : Model.copyIcon()
              tooltipText: "Copy private IP (" + root.privateIp + ")"
              hoverColor: Color.accent
              onClicked: root.copyToClipboard(root.privateIp, "Private IP")
            }
          }
        }

        PanelSeparator { foreground: root.contentForeground }

        // ----------------- Public IP Card -----------------
        PanelSectionHeader {
          text: "PUBLIC IP"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        Rectangle {
          id: publicCard
          width: parent.width
          implicitHeight: publicRow.implicitHeight + Style.space(16)
          radius: Style.cornerRadius
          color: publicMouse.containsMouse
            ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
            : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.05)
          border.width: 1
          border.color: publicMouse.containsMouse
            ? Color.accent
            : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.1)

          Behavior on color { ColorAnimation { duration: 100 } }
          Behavior on border.color { ColorAnimation { duration: 100 } }

          MouseArea {
            id: publicMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: root.copyToClipboard(root.publicIp, "Public IP")
          }

          Row {
            id: publicRow
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(12)

            Text {
              text: Model.publicIcon()
              font.family: root.contentFontFamily
              font.pixelSize: Style.font.title
              color: Color.accent
              anchors.verticalCenter: parent.verticalCenter
            }

            Column {
              width: parent.width - Style.space(70)
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(2)

              Text {
                text: root.publicIp ? root.publicIp : (root.refreshing ? "Fetching public IP..." : "Offline / Unavailable")
                color: root.contentForeground
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.body
                font.bold: true
              }

              Text {
                visible: root.publicOrg !== ""
                text: root.publicOrg
                color: root.dimColor
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                visible: root.publicLocation !== ""
                text: root.publicLocation
                color: root.subDimColor
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideRight
                width: parent.width
              }

              Text {
                visible: root.publicHostname !== ""
                text: "Host: " + root.publicHostname
                color: root.subDimColor
                font.family: root.contentFontFamily
                font.pixelSize: Style.font.caption
                elide: Text.ElideMiddle
                width: parent.width
              }
            }

            PanelActionButton {
              anchors.verticalCenter: parent.verticalCenter
              iconText: root.copiedValue === root.publicIp ? Model.checkIcon() : Model.copyIcon()
              tooltipText: "Copy public IP (" + root.publicIp + ")"
              hoverColor: Color.accent
              onClicked: root.copyToClipboard(root.publicIp, "Public IP")
            }
          }
        }

        PanelSeparator { foreground: root.contentForeground }

        // ----------------- Gateway & DNS Section -----------------
        PanelSectionHeader {
          text: "GATEWAY & DNS"
          foreground: root.contentForeground
          fontFamily: root.contentFontFamily
        }

        Rectangle {
          width: parent.width
          implicitHeight: gwDnsCol.implicitHeight + Style.space(16)
          radius: Style.cornerRadius
          color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.04)
          border.width: 1
          border.color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

          Column {
            id: gwDnsCol
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.topMargin: Style.space(8)
            anchors.leftMargin: Style.space(12)
            anchors.rightMargin: Style.space(10)
            spacing: Style.space(8)

            // Gateway row
            Item {
              width: parent.width
              height: Style.space(22)

              Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: Model.gatewayIcon()
                  color: root.dimColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "Gateway:"
                  color: root.dimColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: root.gatewayIp || "--"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: !!root.gatewayIp
                iconText: root.copiedValue === root.gatewayIp ? Model.checkIcon() : Model.copyIcon()
                tooltipText: "Copy gateway IP (" + root.gatewayIp + ")"
                size: Style.space(18)
                fontSize: Style.font.caption
                hoverColor: Color.accent
                onClicked: root.copyToClipboard(root.gatewayIp, "Gateway IP")
              }
            }

            // DNS Servers row / header
            Item {
              width: parent.width
              height: Style.space(22)

              Row {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: Model.dnsIcon()
                  color: root.dimColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: "DNS Servers:"
                  color: root.dimColor
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  visible: root.dnsServers.length === 0
                  text: "--"
                  color: root.contentForeground
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  anchors.verticalCenter: parent.verticalCenter
                }
              }

              PanelActionButton {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: root.dnsServers.length > 0
                iconText: root.copiedValue === root.dnsServers.join(", ") ? Model.checkIcon() : Model.copyIcon()
                tooltipText: "Copy all DNS servers (" + root.dnsServers.join(", ") + ")"
                size: Style.space(18)
                fontSize: Style.font.caption
                hoverColor: Color.accent
                onClicked: root.copyToClipboard(root.dnsServers.join(", "), "All DNS Servers")
              }
            }

            // DNS Servers pills
            Flow {
              visible: root.dnsServers.length > 0
              width: parent.width
              spacing: Style.space(6)

              Repeater {
                model: root.dnsServers
                delegate: Rectangle {
                  height: Style.space(22)
                  width: dnsPillContent.implicitWidth + Style.space(14)
                  radius: Style.cornerRadius
                  color: dnsPillMouse.containsMouse
                    ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.15)
                    : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.06)
                  border.width: 1
                  border.color: dnsPillMouse.containsMouse
                    ? Color.accent
                    : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.12)

                  Behavior on color { ColorAnimation { duration: 100 } }
                  Behavior on border.color { ColorAnimation { duration: 100 } }

                  MouseArea {
                    id: dnsPillMouse
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.copyToClipboard(modelData, "DNS Server")
                  }

                  Row {
                    id: dnsPillContent
                    anchors.centerIn: parent
                    spacing: Style.space(6)

                    Text {
                      text: modelData
                      color: root.contentForeground
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption - 1
                      anchors.verticalCenter: parent.verticalCenter
                    }

                    Text {
                      text: root.copiedValue === modelData ? Model.checkIcon() : Model.copyIcon()
                      color: root.copiedValue === modelData ? Color.accent : root.dimColor
                      font.family: root.contentFontFamily
                      font.pixelSize: Style.font.caption - 2
                      anchors.verticalCenter: parent.verticalCenter
                    }
                  }
                }
              }
            }
          }
        }

        // ----------------- Additional Interfaces (if any) -----------------
        Column {
          visible: root.additionalInterfaces.length > 0
          width: parent.width
          spacing: Style.space(8)

          PanelSeparator {
            width: parent.width
            foreground: root.contentForeground
          }

          PanelSectionHeader {
            text: "ADDITIONAL INTERFACES"
            foreground: root.contentForeground
            fontFamily: root.contentFontFamily
          }

          Repeater {
            model: root.additionalInterfaces
            delegate: Rectangle {
              id: ifaceItem
              width: parent.width
              height: Style.space(34)
              radius: Style.cornerRadius
              color: ifaceMouse.containsMouse
                ? Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.04)
              border.width: 1
              border.color: ifaceMouse.containsMouse
                ? Color.accent
                : Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.08)

              Behavior on color { ColorAnimation { duration: 100 } }
              Behavior on border.color { ColorAnimation { duration: 100 } }

              MouseArea {
                id: ifaceMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.copyToClipboard(modelData.ip, modelData.iface)
              }

              Row {
                id: leftDetails
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.verticalCenter: parent.verticalCenter
                anchors.right: rightDetails.left
                anchors.rightMargin: Style.space(8)
                spacing: Style.space(8)

                Text {
                  text: Model.typeIcon(modelData.type)
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  color: Color.accent
                  anchors.verticalCenter: parent.verticalCenter
                }

                Text {
                  text: modelData.iface
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  color: root.contentForeground
                  anchors.verticalCenter: parent.verticalCenter
                  elide: Text.ElideRight
                }

                Rectangle {
                  height: Style.space(16)
                  width: typeLabel.implicitWidth + Style.space(8)
                  radius: Style.space(3)
                  color: Qt.rgba(root.contentForeground.r, root.contentForeground.g, root.contentForeground.b, 0.1)
                  anchors.verticalCenter: parent.verticalCenter

                  Text {
                    id: typeLabel
                    anchors.centerIn: parent
                    text: modelData.type.toUpperCase()
                    font.family: root.contentFontFamily
                    font.pixelSize: Style.font.caption - 1
                    color: root.dimColor
                  }
                }
              }

              Row {
                id: rightDetails
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                spacing: Style.space(8)

                Text {
                  text: modelData.prefix && modelData.prefix !== "32" ? (modelData.ip + "/" + modelData.prefix) : modelData.ip
                  font.family: root.contentFontFamily
                  font.pixelSize: Style.font.caption
                  color: root.contentForeground
                  anchors.verticalCenter: parent.verticalCenter
                }

                PanelActionButton {
                  anchors.verticalCenter: parent.verticalCenter
                  iconText: root.copiedValue === modelData.ip ? Model.checkIcon() : Model.copyIcon()
                  tooltipText: "Copy " + modelData.iface + " IP (" + modelData.ip + (modelData.prefix ? "/" + modelData.prefix : "") + ")"
                  size: Style.space(20)
                  fontSize: Style.font.caption
                  hoverColor: Color.accent
                  onClicked: root.copyToClipboard(modelData.ip, modelData.iface)
                }
              }
            }
          }
        }
      }
    }
  }
}
