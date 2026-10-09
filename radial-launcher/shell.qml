//@ pragma IconTheme Papirus-Dark
pragma ComponentBehavior: Bound

// FR Navy — radial launcher untuk niri
// Jalan on-demand: dibuka lewat bind, langsung quit setelah app dipilih / Esc.
//   qs -p ~/.config/radial-launcher/shell.qml
//
// Kontrol:
//   ketik            → cari aplikasi
//   ← → / Tab        → pindah pilihan (lewat ujung = pindah halaman)
//   ↑ ↓              → ganti grup (Game, Browser, Coding, …)
//   PgUp/PgDn, scroll → halaman sebelumnya / berikutnya
//   Enter / klik     → buka aplikasi
//   Esc / klik luar  → tutup

import QtQuick
import Quickshell
import Quickshell.Wayland

ShellRoot {
    id: root

    // ── token warna FR Navy ───────────────────────────────
    readonly property color cBg:       "#0B0F17"
    readonly property color cSurface:  "#121826"
    readonly property color cSurface2: "#1A2233"
    readonly property color cBorder:   "#24304A"
    readonly property color cText:     "#E6EAF2"
    readonly property color cMuted:    "#8A96AD"
    readonly property color cAccent:   "#6EA8FE"
    function tone(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }

    // ── geometri ─────────────────────────────────────────
    readonly property int perPage: 5
    // ukuran ikut tinggi layar: ±340px di 1080p, ±280px di 900p
    readonly property real rOuter: Math.round(Math.max(130, Math.min(190, (win.height > 0 ? win.height : 1080) * 0.157)))
    readonly property real rInner: Math.round(rOuter * 0.43)
    readonly property real gapRad: 0.045      // celah antar irisan (radian)
    readonly property real step: 2 * Math.PI / perPage
    readonly property real startAngle: -Math.PI / 2   // irisan pertama di atas

    // ── data ─────────────────────────────────────────────
    property string query: ""
    property int page: 0
    property int selected: 0
    property string group: "all"

    // ── grup aplikasi (dari Categories= di file .desktop) ──
    // urutan = prioritas: app masuk ke grup pertama yang cocok
    readonly property var groupDefs: [
        { id: "game",    label: "Game",    cp: 0xf0297, cats: ["Game"] },
        { id: "browser", label: "Browser", cp: 0xf059f, cats: ["WebBrowser"] },
        { id: "chat",    label: "Sosial",  cp: 0xf0b79, cats: ["InstantMessaging", "Chat", "Email", "VideoConference"] },
        { id: "code",    label: "Coding",  cp: 0xf0169, cats: ["Development", "IDE", "TextEditor", "TerminalEmulator"] },
        { id: "media",   label: "Media",   cp: 0xf040c, cats: ["AudioVideo", "Audio", "Video", "Music", "Player"] },
        { id: "art",     label: "Grafis",  cp: 0xf03d8, cats: ["Graphics", "Photography", "2DGraphics", "3DGraphics"] },
        { id: "office",  label: "Kantor",  cp: 0xf00d6, cats: ["Office", "Education", "Science"] },
        { id: "system",  label: "Sistem",  cp: 0xf0493, cats: ["System", "Settings", "Utility", "Monitor", "Network", "FileManager"] }
    ]
    function groupOf(e) {
        const cats = Array.from(e.categories || []);
        for (const g of groupDefs)
            if (g.cats.some(c => cats.includes(c))) return g.id;
        return "other";
    }
    // chip yang ditampilkan: "Semua" + grup yang punya isi
    readonly property var groups: {
        const count = {};
        allApps.forEach(e => { const g = groupOf(e); count[g] = (count[g] || 0) + 1; });
        return [{ id: "all", label: "Semua", cp: 0xf003b }]
            .concat(groupDefs.filter(g => count[g.id] > 0));
    }
    function cycleGroup(d) {
        const i = groups.findIndex(g => g.id === group);
        group = groups[(i + d + groups.length) % groups.length].id;
    }
    onGroupChanged: { page = 0; selected = 0; }

    readonly property var allApps: {
        const seen = {};
        return DesktopEntries.applications.values
            .filter(e => !e.noDisplay && e.name && !seen[e.id] && (seen[e.id] = true))
            .sort((a, b) => a.name.localeCompare(b.name));
    }

    readonly property var apps: {
        const q = query.trim().toLowerCase();
        // pencarian selalu ke semua app; tanpa query → ikut grup aktif
        if (q === "") return group === "all" ? allApps : allApps.filter(e => groupOf(e) === group);
        const hit = e => (e.name || "").toLowerCase().includes(q)
            || (e.genericName || "").toLowerCase().includes(q)
            || Array.from(e.keywords || []).some(k => k.toLowerCase().includes(q));
        // yang namanya diawali query naik ke depan
        return allApps.filter(hit).sort((a, b) =>
            (b.name.toLowerCase().startsWith(q) ? 1 : 0) - (a.name.toLowerCase().startsWith(q) ? 1 : 0));
    }

    readonly property int pageCount: Math.max(1, Math.ceil(apps.length / perPage))
    readonly property var pageApps: apps.slice(page * perPage, page * perPage + perPage)
    readonly property var current: pageApps[selected] || null

    onQueryChanged: { page = 0; selected = 0; }
    onPageAppsChanged: if (selected >= pageApps.length) selected = Math.max(0, pageApps.length - 1)

    function goPage(d) {
        const p = (page + d + pageCount) % pageCount;
        if (p !== page) { page = p; selected = 0; }
    }
    function move(d) {
        const n = pageApps.length;
        if (n === 0) return;
        const s = selected + d;
        if (s >= n)      { goPage(1);  selected = 0; }
        else if (s < 0)  { goPage(-1); selected = Math.max(0, pageApps.length - 1); }
        else             selected = s;
    }
    function launch(entry) {
        if (!entry) return;
        entry.execute();
        Qt.quit();
    }

    PanelWindow {
        id: win
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "radial-launcher"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        // latar redup, klik di luar = tutup
        Rectangle {
            anchors.fill: parent
            color: root.tone(root.cBg, 0.45)
            MouseArea { anchors.fill: parent; onClicked: Qt.quit() }
        }

        Item {
            id: wheel
            width: root.rOuter * 2
            height: root.rOuter * 2
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -Math.round(root.rOuter * 0.35)

            opacity: 0
            scale: 0.92
            Component.onCompleted: { opacity = 1; scale = 1; }
            Behavior on opacity { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
            Behavior on scale   { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }

            // irisan pie
            Canvas {
                id: ring
                anchors.fill: parent
                antialiasing: true
                onPaint: {
                    const ctx = getContext("2d");
                    ctx.reset();
                    const c = width / 2;
                    for (let i = 0; i < root.perPage; i++) {
                        const mid = root.startAngle + i * root.step;
                        const a0 = mid - root.step / 2 + root.gapRad;
                        const a1 = mid + root.step / 2 - root.gapRad;
                        const filled = i < root.pageApps.length;
                        const sel = filled && i === root.selected;
                        const ro = sel ? root.rOuter : root.rOuter - 6;
                        ctx.beginPath();
                        ctx.arc(c, c, ro, a0, a1, false);
                        ctx.arc(c, c, root.rInner, a1, a0, true);
                        ctx.closePath();
                        ctx.fillStyle = sel ? root.cSurface2 : (filled ? root.tone(root.cSurface, 0.94) : root.tone(root.cSurface, 0.55));
                        ctx.fill();
                        ctx.lineWidth = 1;
                        ctx.strokeStyle = sel ? root.tone(root.cAccent, 0.55) : root.cBorder;
                        ctx.stroke();
                        if (sel) {
                            // busur aksen tipis di tepi luar irisan aktif
                            ctx.beginPath();
                            ctx.arc(c, c, ro - 3, a0 + 0.03, a1 - 0.03, false);
                            ctx.lineWidth = 4;
                            ctx.lineCap = "round";
                            ctx.strokeStyle = root.cAccent;
                            ctx.stroke();
                        }
                    }
                }
                onWidthChanged: requestPaint()
                Connections {
                    target: root
                    function onSelectedChanged() { ring.requestPaint(); }
                    function onPageAppsChanged() { ring.requestPaint(); }
                }
            }

            // ikon tiap irisan
            Repeater {
                model: root.pageApps
                delegate: Item {
                    required property var modelData
                    required property int index
                    readonly property real ang: root.startAngle + index * root.step
                    readonly property real rad: (root.rOuter + root.rInner) / 2
                    readonly property bool isSel: index === root.selected
                    width: Math.round(root.rOuter * 0.3); height: width
                    x: wheel.width / 2 + Math.cos(ang) * rad - width / 2
                    y: wheel.height / 2 + Math.sin(ang) * rad - height / 2
                    scale: isSel ? 1.12 : 1
                    Behavior on scale { NumberAnimation { duration: 120; easing.type: Easing.OutCubic } }

                    readonly property string iconSrc: Quickshell.iconPath(modelData.icon, true)

                    Image {
                        id: appIcon
                        anchors.fill: parent
                        sourceSize: Qt.size(88, 88)
                        source: parent.iconSrc
                        visible: parent.iconSrc !== "" && status === Image.Ready
                        smooth: true
                        asynchronous: true
                    }

                    // ikon nggak ketemu → huruf depan nama app
                    Rectangle {
                        anchors.fill: parent
                        visible: !appIcon.visible
                        radius: 12
                        color: root.cSurface2
                        border.color: root.cBorder
                        Text {
                            anchors.centerIn: parent
                            text: modelData.name.charAt(0).toUpperCase()
                            color: root.cAccent
                            font { family: "Inter"; pixelSize: 20; weight: Font.Bold }
                        }
                    }
                }
            }

            // hover / klik / scroll di atas cincin
            MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                function idxAt(mx, my) {
                    const dx = mx - width / 2, dy = my - height / 2;
                    const d = Math.sqrt(dx * dx + dy * dy);
                    if (d < root.rInner || d > root.rOuter + 8) return -1;
                    let a = Math.atan2(dy, dx) - root.startAngle + root.step / 2;
                    a = ((a % (2 * Math.PI)) + 2 * Math.PI) % (2 * Math.PI);
                    const i = Math.floor(a / root.step);
                    return i < root.pageApps.length ? i : -1;
                }
                onPositionChanged: m => { const i = idxAt(m.x, m.y); if (i >= 0) root.selected = i; }
                onClicked: m => {
                    const i = idxAt(m.x, m.y);
                    if (i >= 0) root.launch(root.pageApps[i]);
                    else if (Math.hypot(m.x - width / 2, m.y - height / 2) > root.rOuter + 8) Qt.quit();
                }
                onWheel: w => root.goPage(w.angleDelta.y < 0 ? 1 : -1)
            }

            // tengah: nama app + titik halaman
            Rectangle {
                width: root.rInner * 2 - 12
                height: width
                radius: width / 2
                anchors.centerIn: parent
                color: root.cBg
                border.color: root.cBorder
                border.width: 1

                Column {
                    anchors.centerIn: parent
                    width: parent.width - 18
                    spacing: 8

                    Text {
                        width: parent.width
                        horizontalAlignment: Text.AlignHCenter
                        text: root.current ? root.current.name : (root.apps.length === 0 ? "Tidak ada" : "")
                        color: root.cText
                        font { family: "Inter"; pixelSize: 12; weight: Font.DemiBold }
                        wrapMode: Text.Wrap
                        maximumLineCount: 2
                        elide: Text.ElideRight
                    }

                    Row {
                        anchors.horizontalCenter: parent.horizontalCenter
                        spacing: 4
                        visible: root.pageCount > 1 && root.pageCount <= 7
                        Repeater {
                            model: root.pageCount
                            delegate: Rectangle {
                                required property int index
                                width: index === root.page ? 12 : 5
                                height: 5
                                radius: 3
                                color: index === root.page ? root.cAccent : root.cBorder
                                Behavior on width { NumberAnimation { duration: 120 } }
                            }
                        }
                    }
                }
            }
        }

        // chip grup
        Row {
            id: chips
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: wheel.bottom
            anchors.topMargin: 20
            spacing: 6
            opacity: root.query.trim() === "" ? wheel.opacity : 0.35
            Behavior on opacity { NumberAnimation { duration: 120 } }

            Repeater {
                model: root.groups
                delegate: Rectangle {
                    id: chip
                    required property var modelData
                    readonly property bool sel: root.group === modelData.id
                    height: 34
                    width: sel ? chipRow.implicitWidth + 24 : 34
                    radius: 17
                    color: sel ? root.cSurface2 : (chipMa.containsMouse ? root.cSurface : root.tone(root.cSurface, 0.85))
                    border.color: sel ? root.tone(root.cAccent, 0.55) : root.cBorder
                    clip: true
                    Behavior on width { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }

                    Row {
                        id: chipRow
                        anchors.centerIn: parent
                        spacing: 6
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: String.fromCodePoint(chip.modelData.cp)
                            color: chip.sel ? root.cAccent : root.cMuted
                            font { family: "JetBrainsMono Nerd Font"; pixelSize: 15 }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            visible: chip.sel
                            text: chip.modelData.label
                            color: root.cText
                            font { family: "Inter"; pixelSize: 12; weight: Font.DemiBold }
                        }
                    }
                    MouseArea {
                        id: chipMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { root.group = chip.modelData.id; input.forceActiveFocus(); }
                    }
                }
            }
        }

        // search bar
        Rectangle {
            id: search
            width: 300
            height: 44
            radius: 22
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: chips.bottom
            anchors.topMargin: 12
            color: root.cSurface
            border.color: input.activeFocus ? root.cAccent : root.cBorder
            border.width: 1
            opacity: wheel.opacity

            Text {
                id: glass
                anchors.left: parent.left
                anchors.leftMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: ""   // nf-fa-search
                color: root.cMuted
                font { family: "JetBrainsMono Nerd Font"; pixelSize: 14 }
            }

            TextInput {
                id: input
                anchors.left: glass.right
                anchors.leftMargin: 10
                anchors.right: count.left
                anchors.rightMargin: 10
                anchors.verticalCenter: parent.verticalCenter
                color: root.cText
                selectionColor: root.cAccent
                font { family: "Inter"; pixelSize: 14 }
                clip: true
                focus: true
                onTextChanged: root.query = text
                Component.onCompleted: forceActiveFocus()

                Text {
                    anchors.fill: parent
                    verticalAlignment: Text.AlignVCenter
                    text: "Cari aplikasi…"
                    color: root.cMuted
                    font: input.font
                    visible: input.text.length === 0
                }

                Keys.onPressed: e => {
                    switch (e.key) {
                    case Qt.Key_Escape:
                        if (input.text.length) input.text = ""; else Qt.quit();
                        break;
                    case Qt.Key_Return: case Qt.Key_Enter:
                        root.launch(root.current); break;
                    case Qt.Key_Right: case Qt.Key_Tab:
                        root.move(1); break;
                    case Qt.Key_Left: case Qt.Key_Backtab:
                        root.move(-1); break;
                    case Qt.Key_Down:
                        root.cycleGroup(1); break;
                    case Qt.Key_Up:
                        root.cycleGroup(-1); break;
                    case Qt.Key_PageDown:
                        root.goPage(1); break;
                    case Qt.Key_PageUp:
                        root.goPage(-1); break;
                    default:
                        return;
                    }
                    e.accepted = true;
                }
            }

            Text {
                id: count
                anchors.right: parent.right
                anchors.rightMargin: 16
                anchors.verticalCenter: parent.verticalCenter
                text: (root.page + 1) + "/" + root.pageCount
                color: root.cMuted
                font { family: "Inter"; pixelSize: 12 }
            }
        }
    }
}
