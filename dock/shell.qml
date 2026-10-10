//@ pragma IconTheme Papirus-Dark
pragma ComponentBehavior: Bound

// FR Navy — dock bawah (auto-hide)
//   fr-dock on | off        nyalakan / matikan (juga dari panel kontrol → Tema)
//
// Muncul hanya kalau kursor DITAHAN di tepi bawah ±0,4 detik (lewat sebentar tidak memicu,
// jadi aman untuk toolbar Zoom / kontrol video). Jendela fullscreen menutupi dock karena
// dock ada di layer "top". Data jendela dari `niri msg event-stream` (berbasis event, tanpa polling).
//
// Klik      : buka aplikasi / fokus jendelanya (klik lagi = jendela berikutnya dari aplikasi itu)
// Klik tengah: buka jendela baru
// Klik kanan : pin / lepas pin
// Daftar pin : ~/.config/fr-dock/pinned (satu desktop-id per baris)

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    // ── token (diganti fr-theme) ──
    readonly property color cBg:       "#0B0F17"
    readonly property color cSurface:  "#121826"
    readonly property color cSurface2: "#1A2233"
    readonly property color cBorder:   "#24304A"
    readonly property color cText:     "#E6EAF2"
    readonly property color cMuted:    "#8A96AD"
    readonly property color cAccent:   "#6EA8FE"
    readonly property string fUi: "Inter"

    readonly property string home: Quickshell.env("HOME")
    readonly property int iconSize: 40
    readonly property int cell: 54
    readonly property int pad: 8
    readonly property int dwellMs: 250         // lama kursor ditahan di tepi sebelum dock muncul
    readonly property int leaveMs: 450         // jeda sebelum dock turun lagi

    // ── pin ──
    property var pinned: []
    property bool pinsLoaded: false
    // dipakai kalau belum pernah mengatur pin: SATU aplikasi terpasang per jenis (urutan = prioritas)
    readonly property var defaultPinGroups: [
        ["zen", "zen-browser", "firefox", "chromium", "google-chrome", "brave-browser"],   // browser
        ["Alacritty", "kitty", "org.wezfurlong.wezterm", "foot", "org.kde.konsole"],       // terminal
        ["org.kde.dolphin", "org.gnome.Nautilus", "thunar", "pcmanfm"],                    // file manager
        ["code", "code-oss", "visual-studio-code", "dev.zed.Zed", "android-studio"]        // editor
    ]

    function entryFor(id) {
        if (!id) return null;
        return DesktopEntries.byId(id) || DesktopEntries.byId(id.toLowerCase())
            || (DesktopEntries.heuristicLookup ? DesktopEntries.heuristicLookup(id) : null);
    }
    function keyOf(e, fallback) { return (e ? e.id : fallback).toLowerCase().replace(/\.desktop$/, ""); }

    Process {
        id: pinRead
        running: true
        command: ["sh", "-c", 'f="$HOME/.config/fr-dock/pinned"; [ -f "$f" ] && { echo HAS; cat "$f"; } || echo NONE']
        stdout: StdioCollector {
            onStreamFinished: {
                const l = this.text.split("\n").map(s => s.trim()).filter(s => s);
                if (l[0] === "HAS") {
                    root.pinned = l.slice(1);
                } else {
                    const out = [];
                    for (const group of root.defaultPinGroups) {
                        const e = group.map(id => DesktopEntries.byId(id)).find(x => x);   // id persis, tanpa tebak-tebakan
                        if (e) out.push(e.id);
                    }
                    root.pinned = out;
                }
                root.pinsLoaded = true;
            }
        }
    }
    function savePins(list) {
        pinned = list;
        Quickshell.execDetached(["sh", "-c", 'exec "$HOME/.local/bin/fr-dock" set "$@"', "sh"].concat(list));
    }
    function togglePin(app) {
        const ids = pinned.slice();
        const i = ids.findIndex(p => keyOf(entryFor(p), p) === app.key);
        if (i >= 0) ids.splice(i, 1);
        else if (app.entry) ids.push(app.entry.id);
        savePins(ids);
    }

    // ── jendela dari niri (event-stream) ──
    // Hanya app_id & fokus yang disimpan: perubahan judul (tab browser, perintah terminal, lagu)
    // datang terus-menerus dan diabaikan supaya dock tidak menghitung ulang tanpa perlu.
    property var wins: ({})                    // id → {id, app_id, is_focused}
    function slim(w) { return { id: w.id, app_id: w.app_id || "", is_focused: !!w.is_focused }; }
    function onEvent(line) {
        let ev;
        try { ev = JSON.parse(line); } catch (e) { return; }
        if (ev.WindowsChanged) {
            const m = {};
            ev.WindowsChanged.windows.forEach(w => m[w.id] = slim(w));
            wins = m;
        } else if (ev.WindowOpenedOrChanged) {
            const w = slim(ev.WindowOpenedOrChanged.window), old = wins[w.id];
            if (old && old.app_id === w.app_id && old.is_focused === w.is_focused) return;   // cuma judul berubah
            const m = {};
            for (const k in wins) m[k] = w.is_focused ? Object.assign({}, wins[k], { is_focused: false }) : wins[k];
            m[w.id] = w; wins = m;
        } else if (ev.WindowClosed) {
            if (!(ev.WindowClosed.id in wins)) return;
            const m = Object.assign({}, wins); delete m[ev.WindowClosed.id]; wins = m;
        } else if (ev.WindowFocusChanged) {
            const id = ev.WindowFocusChanged.id, m = {};
            for (const k in wins) m[k] = Object.assign({}, wins[k], { is_focused: wins[k].id === id });
            wins = m;
        }
    }
    Process {
        id: events
        running: true
        command: ["niri", "msg", "--json", "event-stream"]
        stdout: SplitParser { onRead: line => root.onEvent(line) }
        onExited: retry.start()                // niri restart / belum siap: coba lagi
    }
    Timer { id: retry; interval: 3000; onTriggered: events.running = true }

    // ── isi dock: pin dulu (urut pin), lalu aplikasi lain yang terbuka ──
    // appKeys (daftar ikon) hanya diganti kalau susunannya berubah, jadi pindah fokus atau
    // tambah jendela ke aplikasi yang sudah ada TIDAK membuat ulang ikon; cukup penandanya.
    property var appKeys: []
    property var appMap: ({})                  // key → {key, entry, name, icon, wins, pinned}
    property int pinnedCount: 0
    function refresh() {
        const groups = {}, order = [];
        for (const id of pinned) {
            const e = entryFor(id), k = keyOf(e, id);
            if (groups[k]) continue;
            groups[k] = { key: k, entry: e, name: e ? e.name : id, icon: e ? e.icon : id, wins: [], pinned: true };
            order.push(k);
        }
        const ws = Object.values(wins).filter(w => w.app_id && !/^fr-/.test(w.app_id)).sort((a, b) => a.id - b.id);
        for (const w of ws) {
            const e = entryFor(w.app_id), k = keyOf(e, w.app_id);
            if (!groups[k]) {
                groups[k] = { key: k, entry: e, name: e ? e.name : w.app_id, icon: e ? e.icon : w.app_id, wins: [], pinned: false };
                order.push(k);
            }
            groups[k].wins.push(w);
        }
        const keys = order.filter(k => groups[k].entry || groups[k].wins.length);
        appMap = groups;
        pinnedCount = keys.filter(k => groups[k].pinned).length;
        if (keys.join("\n") !== appKeys.join("\n")) appKeys = keys;
    }
    onWinsChanged: refresh()
    onPinnedChanged: refresh()
    // daftar aplikasi (.desktop) bisa selesai dimuat setelah dock jalan
    Connections {
        target: DesktopEntries.applications
        function onValuesChanged() { root.refresh(); }
    }

    function activate(app) {
        if (!app.wins.length) { if (app.entry) app.entry.execute(); return; }
        const i = app.wins.findIndex(w => w.is_focused);
        const next = app.wins[(i + 1) % app.wins.length];     // sudah fokus → jendela berikutnya
        Quickshell.execDetached(["niri", "msg", "action", "focus-window", "--id", String(next.id)]);
    }

    // ── satu dock per layar ──
    Variants {
        model: Quickshell.screens

        PanelWindow {
            id: win
            required property var modelData
            screen: modelData

            property bool open: false             // dock terlihat (animasi)
            property bool extended: false         // ukuran jendela penuh (masih ada saat animasi turun)
            property string hoverName: ""
            property real hoverX: 0

            anchors.bottom: true
            exclusionMode: ExclusionMode.Ignore
            color: "transparent"
            WlrLayershell.layer: WlrLayer.Top
            WlrLayershell.namespace: "fr-dock"
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

            readonly property int dockW: root.appKeys.length === 0 ? 200
                                         : root.appKeys.length * root.cell + root.pad * 2
                                           + (root.pinnedCount > 0 && root.pinnedCount < root.appKeys.length ? 13 : 0)
            readonly property int dockH: root.cell + root.pad * 2
            implicitWidth: dockW + 24
            // tersembunyi = strip 3 px di tepi bawah (selebar dock), cuma untuk mendeteksi kursor
            implicitHeight: extended ? dockH + 50 : 3

            function show() { extended = true; open = true; }
            function hide() { open = false; hoverName = ""; collapse.restart(); }
            Timer { id: collapse; interval: 220; onTriggered: if (!win.open) win.extended = false }
            Timer { id: dwell; interval: root.dwellMs; onTriggered: if (edge.hovered) win.show() }
            Timer { id: leave; interval: root.leaveMs; onTriggered: if (!area.hovered) win.hide() }

            // pemicu: kursor ditahan di strip bawah
            Item {
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                height: 3
                HoverHandler {
                    id: edge
                    onHoveredChanged: if (hovered && !win.open) dwell.restart(); else if (!hovered) dwell.stop()
                }
            }

            // seluruh area dock: selama kursor di sini, dock tetap terbuka
            Item {
                id: dockArea
                anchors.fill: parent
                visible: win.extended
                HoverHandler {
                    id: area
                    onHoveredChanged: if (hovered) leave.stop(); else if (win.open) leave.restart()
                }

                // tooltip nama aplikasi
                Rectangle {
                    visible: win.hoverName !== "" && win.open
                    x: Math.max(4, Math.min(parent.width - width - 4, win.hoverX - width / 2))
                    y: box.y - height - 8
                    width: tip.implicitWidth + 20
                    height: 26
                    radius: 8
                    color: root.cSurface
                    border.color: root.cBorder
                    Text {
                        id: tip
                        anchors.centerIn: parent
                        text: win.hoverName
                        color: root.cText
                        font { family: root.fUi; pixelSize: 12; weight: Font.Medium }
                    }
                }

                Rectangle {
                    id: box
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: win.dockW
                    height: win.dockH
                    y: win.open ? parent.height - height - 8 : parent.height + 4
                    opacity: win.open ? 1 : 0
                    radius: 20
                    color: Qt.rgba(root.cBg.r, root.cBg.g, root.cBg.b, 0.92)
                    border.color: root.cBorder
                    Behavior on y { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
                    Behavior on opacity { NumberAnimation { duration: 160 } }

                    Row {
                        x: root.pad
                        anchors.verticalCenter: parent.verticalCenter
                        Repeater {
                            model: root.appKeys
                            delegate: Row {
                                id: slot
                                required property string modelData        // key aplikasi
                                required property int index
                                readonly property var app: root.appMap[modelData] || ({ name: "", icon: "", wins: [], entry: null })
                                readonly property bool focusedApp: app.wins.some(w => w.is_focused)
                                // garis pemisah antara pin dan aplikasi lain
                                Item {
                                    visible: slot.index === root.pinnedCount && slot.index > 0
                                    width: 13; height: root.cell
                                    Rectangle { anchors.centerIn: parent; width: 1; height: root.cell - 18; color: root.cBorder }
                                }
                                Item {
                                    id: cellItem
                                    width: root.cell; height: root.cell

                                    Rectangle {               // latar saat hover
                                        anchors.centerIn: parent
                                        width: root.cell - 4; height: root.cell - 4
                                        radius: 14
                                        color: ma.containsMouse ? root.cSurface2 : "transparent"
                                        Behavior on color { ColorAnimation { duration: 120 } }
                                    }
                                    Item {
                                        id: iconBox
                                        width: root.iconSize; height: root.iconSize
                                        anchors.centerIn: parent
                                        anchors.verticalCenterOffset: ma.containsMouse ? -4 : -2
                                        scale: ma.pressed ? 0.92 : (ma.containsMouse ? 1.12 : 1)
                                        Behavior on scale { NumberAnimation { duration: 140; easing.type: Easing.OutBack } }
                                        Behavior on anchors.verticalCenterOffset { NumberAnimation { duration: 140 } }
                                        readonly property string src: Quickshell.iconPath(slot.app.icon || "", true)
                                        Image {
                                            anchors.fill: parent
                                            visible: iconBox.src !== ""
                                            source: iconBox.src
                                            sourceSize: Qt.size(root.iconSize * 2, root.iconSize * 2)
                                            smooth: true
                                            asynchronous: true
                                        }
                                        Rectangle {           // tanpa ikon: huruf depan
                                            anchors.fill: parent
                                            visible: iconBox.src === ""
                                            radius: 12
                                            color: root.cSurface2
                                            border.color: root.cBorder
                                            Text {
                                                anchors.centerIn: parent
                                                text: (slot.app.name || "?").charAt(0).toUpperCase()
                                                color: root.cAccent
                                                font { family: root.fUi; pixelSize: 18; weight: Font.Bold }
                                            }
                                        }
                                    }
                                    // penanda jendela terbuka: titik; aplikasi yang fokus: garis aksen
                                    Row {
                                        anchors.horizontalCenter: parent.horizontalCenter
                                        anchors.bottom: parent.bottom
                                        anchors.bottomMargin: 1
                                        spacing: 3
                                        visible: slot.app.wins.length > 0
                                        Repeater {
                                            model: slot.focusedApp ? 1 : Math.min(3, slot.app.wins.length)
                                            delegate: Rectangle {
                                                width: slot.focusedApp ? 14 : 4; height: 4; radius: 2
                                                color: slot.focusedApp ? root.cAccent : root.cMuted
                                            }
                                        }
                                    }
                                    MouseArea {
                                        id: ma
                                        anchors.fill: parent
                                        hoverEnabled: true
                                        acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
                                        cursorShape: Qt.PointingHandCursor
                                        onContainsMouseChanged: {
                                            if (containsMouse) {
                                                const p = cellItem.mapToItem(dockArea, cellItem.width / 2, 0);
                                                win.hoverX = p.x;
                                                const n = slot.app.wins.length;
                                                win.hoverName = slot.app.name + (n > 1 ? "  ·  " + n + " jendela" : "");
                                            } else if (win.hoverName.startsWith(slot.app.name)) win.hoverName = "";
                                        }
                                        onClicked: mouse => {
                                            if (mouse.button === Qt.RightButton) root.togglePin(slot.app);
                                            else if (mouse.button === Qt.MiddleButton) { if (slot.app.entry) slot.app.entry.execute(); }
                                            else root.activate(slot.app);
                                        }
                                    }
                                }
                            }
                        }
                    }

                    Text {
                        visible: root.appKeys.length === 0 && root.pinsLoaded
                        anchors.centerIn: parent
                        text: "Klik kanan ikon untuk pin"
                        color: root.cMuted
                        font { family: root.fUi; pixelSize: 11 }
                    }
                }
            }
        }
    }
}
