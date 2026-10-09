//@ pragma IconTheme Papirus-Dark
pragma ComponentBehavior: Bound

// FR Navy — monitor sistem (dibuka dari CPU/RAM/disk di waybar kiri)
//   fr-toggle fr-sysmon
// Data: ~/.local/bin/fr-sysmon-sample
//   stream → satu proses yang hidup selama widget terbuka (1 sampel/dtk, tanpa fork)
//   slow   → df + ps tiap 5 dtk

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland

ShellRoot {
    id: root

    readonly property color cBg:       "#0B0F17"
    readonly property color cSurface:  "#121826"
    readonly property color cSurface2: "#1A2233"
    readonly property color cBorder:   "#24304A"
    readonly property color cText:     "#E6EAF2"
    readonly property color cMuted:    "#8A96AD"
    readonly property color cAccent:   "#6EA8FE"
    function tone(c, a) { return Qt.rgba(c.r, c.g, c.b, a); }
    readonly property color cTeal:     "#7FD1B9"
    readonly property color cViolet:   "#B49CFF"
    readonly property color cWarn:     "#F2C46D"
    readonly property color cUrgent:   "#F27A7A"
    readonly property string fUi:   "Inter"
    readonly property string fIcon: "JetBrainsMono Nerd Font"

    readonly property string sampler: Quickshell.env("HOME") + "/.local/bin/fr-sysmon-sample"
    readonly property int histLen: 60

    function ic(cp) { return String.fromCodePoint(cp); }
    function gib(kb) { return (kb / 1048576).toFixed(1); }
    function human(bytes) {
        const u = ["B", "KB", "MB", "GB", "TB"]; let i = 0, v = bytes;
        while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
        return (v >= 100 || i === 0 ? v.toFixed(0) : v.toFixed(1)) + " " + u[i];
    }
    function rate(bps) { return human(bps) + "/s"; }
    function push(arr, v) { const a = arr.slice(-(histLen - 1)); a.push(v); return a; }
    function tempColor(t) { return t >= 85 ? cUrgent : t >= 70 ? cWarn : cTeal; }

    // ── state ────────────────────────────────────────────
    property string model: "CPU"
    property int threads: 0
    property string host: ""

    property var prevCpu: ({})
    property real cpu: 0
    property var cores: []
    property var cpuHist: []
    property real freqGhz: 0
    property string load: ""

    property real memTotal: 0
    property real memUsed: 0
    property real swapTotal: 0
    property real swapUsed: 0
    property var memHist: []

    property var temps: []           // [{label, value}]
    property real cpuTemp: 0
    property var tempHist: []

    property var prevDisk: null
    property real readBps: 0
    property real writeBps: 0
    property var readHist: []
    property var writeHist: []
    property var mounts: []          // [{target, size, used}]
    property var procs: []

    readonly property real memPct: memTotal > 0 ? memUsed / memTotal : 0
    readonly property var rootFs: mounts.find(m => m.target === "/") || mounts[0] || null

    // ── sampling ─────────────────────────────────────────
    Process {
        id: infoProc
        command: [root.sampler, "info"]
        stdout: StdioCollector {
            onStreamFinished: this.text.split("\n").forEach(l => {
                if (l.startsWith("MODEL ")) root.model = l.slice(6).trim() || "CPU";
                else if (l.startsWith("THREADS ")) root.threads = parseInt(l.slice(8)) || 0;
                else if (l.startsWith("HOST ")) root.host = l.slice(5).trim();
            })
        }
    }

    property var _buf: []
    Process {
        id: streamProc
        command: [root.sampler, "stream"]
        running: true
        stdout: SplitParser {
            onRead: line => {
                if (line === "END") { root.parseFast(root._buf.join("\n")); root._buf = []; }
                else root._buf.push(line);
            }
        }
    }
    Process {
        id: slowProc
        command: [root.sampler, "slow"]
        stdout: StdioCollector { onStreamFinished: root.parseSlow(this.text) }
    }

    function parseFast(text) {
        const prev = prevCpu, next = {}, coreVals = [];
        const tempsRaw = [];
        let total = 0, totalSet = false;
        text.split("\n").forEach(l => {
            const f = l.trim().split(/\s+/);
            switch (f[0]) {
            case "CPU": {
                const name = f[1];
                const v = f.slice(2).map(Number);
                const idle = v[3] + (v[4] || 0);
                const all = v.slice(0, 8).reduce((a, b) => a + b, 0);
                next[name] = { idle: idle, all: all };
                const p = prev[name];
                const use = p && all > p.all ? 1 - (idle - p.idle) / (all - p.all) : 0;
                if (name === "cpu") { total = Math.max(0, Math.min(1, use)); totalSet = !!p; }
                else coreVals.push(Math.max(0, Math.min(1, use)));
                break;
            }
            case "MEM": {
                const t = +f[1], a = +f[2], st = +f[3], sf = +f[4];
                root.memTotal = t; root.memUsed = t - a;
                root.swapTotal = st; root.swapUsed = st - sf;
                break;
            }
            case "LOAD": root.load = f[1] + " · " + f[2] + " · " + f[3]; break;
            case "FREQ": root.freqGhz = (+f[1]) / 1e6; break;
            case "TEMP": tempsRaw.push(l.slice(5)); break;
            case "DISK": {
                const r = +f[1] * 512, w = +f[2] * 512, now = Date.now();
                if (root.prevDisk) {
                    const dt = Math.max(0.2, (now - root.prevDisk.t) / 1000);
                    root.readBps = Math.max(0, (r - root.prevDisk.r) / dt);
                    root.writeBps = Math.max(0, (w - root.prevDisk.w) / dt);
                    root.readHist = root.push(root.readHist, root.readBps);
                    root.writeHist = root.push(root.writeHist, root.writeBps);
                }
                root.prevDisk = { r: r, w: w, t: now };
                break;
            }
            }
        });
        prevCpu = next;
        if (totalSet) {
            cpu = total;
            cores = coreVals;
            cpuHist = push(cpuHist, total * 100);
        }
        memHist = push(memHist, memPct * 100);
        parseTemps(tempsRaw);
    }

    // pilih sensor yang berguna & beri nama yang manusiawi
    function parseTemps(raw) {
        const names = { k10temp: "CPU", coretemp: "CPU", zenpower: "CPU", amdgpu: "GPU", nouveau: "GPU",
                        nvme: "NVMe", acpitz: "Board", iwlwifi_1: "Wi-Fi", mt7921_phy0: "Wi-Fi" };
        const seen = {}, list = [];
        raw.forEach(r => {
            const [chip, label, milli] = r.split("|");
            const base = names[chip] || (chip.startsWith("nvme") ? "NVMe" : null);
            const v = parseInt(milli) / 1000;
            if (!base || isNaN(v) || v <= 0 || v > 125) return;
            // CPU: utamakan Tctl / Package; GPU: edge; NVMe: Composite
            const prefer = /Tctl|Tdie|Package|edge|Composite/i.test(label || "");
            if (seen[base] !== undefined) {
                if (prefer) list[seen[base]].value = v;
                return;
            }
            seen[base] = list.length;
            list.push({ label: base, value: v });
        });
        temps = list;
        const c = list.find(t => t.label === "CPU");
        cpuTemp = c ? c.value : (list.length ? list[0].value : 0);
        tempHist = push(tempHist, cpuTemp);
    }

    function parseSlow(text) {
        const m = [], p = [];
        text.split("\n").forEach(l => {
            if (l.startsWith("FS ")) {
                const [t, s, u] = l.slice(3).split("|");
                if (+s > 1e9) m.push({ target: t, size: +s, used: +u });
            } else if (l.startsWith("PROC ")) {
                const [n, c, mm] = l.slice(5).split("|");
                p.push({ name: n, cpu: parseFloat(c) || 0, mem: parseFloat(mm) || 0 });
            }
        });
        mounts = m.sort((a, b) => b.size - a.size).slice(0, 2);
        procs = p.slice(0, 5);
    }

    Timer { interval: 5000; running: true; repeat: true; triggeredOnStart: true; onTriggered: slowProc.running = true }
    Component.onCompleted: infoProc.running = true

    // ═════════ JENDELA ═══════════════════════════════════
    PanelWindow {
        id: win
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "fr-sysmon"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        MouseArea { anchors.fill: parent; onClicked: Qt.quit() }
        Item { anchors.fill: parent; focus: true; Keys.onEscapePressed: Qt.quit() }

        Rectangle {
            id: panel
            width: 572
            height: content.implicitHeight + 32
            anchors { top: parent.top; left: parent.left; topMargin: 50; leftMargin: 10 }
            radius: 20
            color: root.cBg
            border.color: root.cBorder

            opacity: 0
            transform: Translate { id: slide; y: -8 }
            Component.onCompleted: { opacity = 1; slide.y = 0; }
            Behavior on opacity { NumberAnimation { duration: 150; easing.type: Easing.OutCubic } }
            MouseArea { anchors.fill: parent }

            Column {
                id: content
                x: 16; y: 16
                width: parent.width - 32
                spacing: 12

                // header
                Item {
                    width: parent.width
                    height: 38
                    Column {
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: 2
                        Text {
                            text: "Sistem" + (root.host ? "  ·  " + root.host : "")
                            color: root.cText
                            font { family: root.fUi; pixelSize: 16; weight: Font.DemiBold }
                        }
                        Text {
                            text: root.model + (root.threads ? "  ·  " + root.threads + " thread" : "")
                            color: root.cMuted
                            font { family: root.fUi; pixelSize: 12 }
                        }
                    }
                    Rectangle {
                        anchors.right: parent.right
                        anchors.verticalCenter: parent.verticalCenter
                        width: 34; height: 34; radius: 17
                        color: closeMa.containsMouse ? root.cSurface2 : "transparent"
                        Text {
                            anchors.centerIn: parent
                            text: root.ic(0xf0156)
                            color: root.cMuted
                            font { family: root.fIcon; pixelSize: 17 }
                        }
                        MouseArea { id: closeMa; anchors.fill: parent; hoverEnabled: true; onClicked: Qt.quit() }
                    }
                }

                Grid {
                    id: grid
                    columns: 2
                    spacing: 12
                    width: parent.width
                    readonly property real cw: (width - 12) / 2

                    // ── CPU ─────────────────────────────
                    Card {
                        width: grid.cw
                        glyph: root.ic(0xf0ee0)
                        title: "CPU"
                        tint: root.cAccent
                        big: Math.round(root.cpu * 100) + "%"
                        sub: (root.freqGhz > 0 ? root.freqGhz.toFixed(2) + " GHz  ·  " : "") + "load " + root.load
                        Graph {
                            width: parent.width; height: 74
                            maxValue: 100
                            series: [{ data: root.cpuHist, color: root.cAccent }]
                        }
                        // bar per core
                        Row {
                            width: parent.width
                            height: 22
                            spacing: 2
                            Repeater {
                                model: root.cores
                                delegate: Rectangle {
                                    id: core
                                    required property real modelData
                                    width: (parent.width - 2 * (root.cores.length - 1)) / Math.max(1, root.cores.length)
                                    height: parent.height
                                    radius: 3
                                    color: root.cSurface2
                                    Rectangle {
                                        anchors.bottom: parent.bottom
                                        width: parent.width
                                        height: Math.max(2, parent.height * core.modelData)
                                        radius: 3
                                        color: core.modelData > 0.85 ? root.cWarn : root.cAccent
                                        opacity: 0.55 + 0.45 * core.modelData
                                        Behavior on height { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
                                    }
                                }
                            }
                        }
                    }

                    // ── Memori ──────────────────────────
                    Card {
                        width: grid.cw
                        glyph: root.ic(0xf035b)
                        title: "Memori"
                        tint: root.cTeal
                        big: Math.round(root.memPct * 100) + "%"
                        sub: root.gib(root.memUsed) + " / " + root.gib(root.memTotal) + " GiB terpakai"
                        Graph {
                            width: parent.width; height: 74
                            maxValue: 100
                            series: [{ data: root.memHist, color: root.cTeal }]
                        }
                        Meter {
                            width: parent.width
                            label: "Swap"
                            value: root.swapTotal > 0 ? root.swapUsed / root.swapTotal : 0
                            detail: root.swapTotal > 0 ? root.gib(root.swapUsed) + " / " + root.gib(root.swapTotal) + " GiB" : "tidak ada"
                            tint: root.cTeal
                        }
                    }

                    // ── Suhu ────────────────────────────
                    Card {
                        width: grid.cw
                        glyph: root.ic(0xf050f)
                        title: "Suhu"
                        tint: root.tempColor(root.cpuTemp)
                        big: root.temps.length ? Math.round(root.cpuTemp) + "°C" : "—"
                        sub: root.temps.length ? "CPU · grafik 60 detik terakhir" : "Sensor tidak terbaca"
                        Graph {
                            width: parent.width; height: 74
                            minValue: 30
                            maxValue: 100
                            series: [{ data: root.tempHist, color: root.tempColor(root.cpuTemp) }]
                        }
                        Flow {
                            width: parent.width
                            spacing: 6
                            Repeater {
                                model: root.temps.filter(t => t.label !== "CPU")
                                delegate: Rectangle {
                                    id: chip
                                    required property var modelData
                                    height: 22
                                    width: chipText.implicitWidth + 16
                                    radius: 11
                                    color: root.cSurface2
                                    Text {
                                        id: chipText
                                        anchors.centerIn: parent
                                        text: chip.modelData.label + "  " + Math.round(chip.modelData.value) + "°"
                                        color: root.tempColor(chip.modelData.value)
                                        font { family: root.fUi; pixelSize: 11; weight: Font.DemiBold }
                                    }
                                }
                            }
                        }
                    }

                    // ── Storage ─────────────────────────
                    Card {
                        width: grid.cw
                        glyph: root.ic(0xf02ca)
                        title: "Storage"
                        tint: root.cViolet
                        big: root.rootFs ? Math.round(root.rootFs.used / root.rootFs.size * 100) + "%" : "—"
                        sub: "<font color='" + root.cViolet + "'>↓</font> baca " + root.rate(root.readBps)
                           + "   <font color='" + root.cAccent + "'>↑</font> tulis " + root.rate(root.writeBps)
                        Graph {
                            width: parent.width; height: 74
                            autoMax: true
                            series: [
                                { data: root.readHist,  color: root.cViolet },
                                { data: root.writeHist, color: root.cAccent }
                            ]
                        }
                        Repeater {
                            model: root.mounts
                            delegate: Meter {
                                id: mt
                                required property var modelData
                                width: parent.width
                                label: modelData.target
                                value: modelData.used / modelData.size
                                detail: root.human(modelData.used) + " / " + root.human(modelData.size)
                                tint: value > 0.9 ? root.cUrgent : value > 0.8 ? root.cWarn : root.cViolet
                            }
                        }
                    }
                }

                // ── proses teratas ──────────────────────
                Rectangle {
                    width: parent.width
                    height: procCol.implicitHeight + 24
                    radius: 16
                    color: root.cSurface
                    border.color: root.cBorder
                    Column {
                        id: procCol
                        x: 14; y: 12
                        width: parent.width - 28
                        spacing: 6
                        Item {
                            width: parent.width; height: 18
                            Text {
                                text: "PROSES TERATAS"
                                color: root.cMuted
                                font { family: root.fUi; pixelSize: 11; weight: Font.DemiBold; letterSpacing: 0.6 }
                            }
                            Text {
                                anchors.right: parent.right
                                text: "CPU        RAM"
                                color: root.cMuted
                                font { family: root.fUi; pixelSize: 11; weight: Font.DemiBold }
                            }
                        }
                        Repeater {
                            model: root.procs
                            delegate: Item {
                                id: pr
                                required property var modelData
                                width: parent.width
                                height: 22
                                Text {
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: parent.width - 120
                                    elide: Text.ElideRight
                                    text: pr.modelData.name
                                    color: root.cText
                                    font { family: root.fUi; pixelSize: 13 }
                                }
                                Text {
                                    anchors.right: memTxt.left
                                    anchors.rightMargin: 14
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 46
                                    horizontalAlignment: Text.AlignRight
                                    text: pr.modelData.cpu.toFixed(1) + "%"
                                    color: pr.modelData.cpu > 50 ? root.cWarn : root.cAccent
                                    font { family: root.fUi; pixelSize: 12; weight: Font.DemiBold }
                                }
                                Text {
                                    id: memTxt
                                    anchors.right: parent.right
                                    anchors.verticalCenter: parent.verticalCenter
                                    width: 40
                                    horizontalAlignment: Text.AlignRight
                                    text: pr.modelData.mem.toFixed(1) + "%"
                                    color: root.cTeal
                                    font { family: root.fUi; pixelSize: 12; weight: Font.DemiBold }
                                }
                            }
                        }
                    }
                }

                Rectangle {
                    width: parent.width
                    height: 42
                    radius: 12
                    color: btopMa.containsMouse ? root.cSurface2 : root.cSurface
                    border.color: root.cBorder
                    Row {
                        anchors.centerIn: parent
                        spacing: 8
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: root.ic(0xf0128)
                            color: root.cText
                            font { family: root.fIcon; pixelSize: 15 }
                        }
                        Text {
                            anchors.verticalCenter: parent.verticalCenter
                            text: "Buka btop"
                            color: root.cText
                            font { family: root.fUi; pixelSize: 13 }
                        }
                    }
                    MouseArea {
                        id: btopMa
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: { Quickshell.execDetached(["alacritty", "-e", "btop"]); Qt.quit(); }
                    }
                }
            }
        }
    }

    // ═════════ KOMPONEN ══════════════════════════════════

    // kartu metrik: ikon + judul, angka besar, keterangan, lalu isi (grafik dsb)
    component Card: Rectangle {
        id: card
        property string glyph
        property string title
        property string big
        property string sub
        property color tint: root.cAccent
        default property alias body: bodyCol.data
        height: 222
        radius: 16
        color: root.cSurface
        border.color: root.cBorder

        Column {
            x: 14; y: 12
            width: parent.width - 28
            spacing: 10

            Item {
                width: parent.width
                height: 40
                Rectangle {
                    id: badge
                    width: 28; height: 28; radius: 9
                    color: Qt.rgba(card.tint.r, card.tint.g, card.tint.b, 0.14)
                    Text {
                        anchors.centerIn: parent
                        text: card.glyph
                        color: card.tint
                        font { family: root.fIcon; pixelSize: 15 }
                    }
                }
                Text {
                    anchors.left: badge.right
                    anchors.leftMargin: 8
                    anchors.verticalCenter: badge.verticalCenter
                    text: card.title
                    color: root.cMuted
                    font { family: root.fUi; pixelSize: 12; weight: Font.DemiBold }
                }
                Text {
                    anchors.right: parent.right
                    anchors.top: parent.top
                    anchors.topMargin: -4
                    text: card.big
                    color: root.cText
                    font { family: root.fUi; pixelSize: 26; weight: Font.Bold }
                }
                Text {
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: -4
                    text: card.sub
                    textFormat: Text.StyledText
                    elide: Text.ElideRight
                    color: root.cMuted
                    font { family: root.fUi; pixelSize: 11 }
                }
            }
            Column {
                id: bodyCol
                width: parent.width
                spacing: 10
            }
        }
    }

    // grafik area: garis halus + gradasi, garis bantu putus-putus, titik terakhir
    component Graph: Canvas {
        id: g
        property var series: []          // [{data:[...], color}]
        property real minValue: 0
        property real maxValue: 100
        property bool autoMax: false
        antialiasing: true
        onSeriesChanged: requestPaint()
        onWidthChanged: requestPaint()

        onPaint: {
            const ctx = getContext("2d");
            ctx.reset();
            const w = width, h = height, pad = 3;
            // garis bantu
            ctx.strokeStyle = Qt.rgba(1, 1, 1, 0.06);
            ctx.lineWidth = 1;
            ctx.setLineDash([3, 4]);
            for (let i = 1; i < 4; i++) {
                const y = Math.round(h * i / 4) + 0.5;
                ctx.beginPath(); ctx.moveTo(0, y); ctx.lineTo(w, y); ctx.stroke();
            }
            ctx.setLineDash([]);

            let hi = maxValue;
            if (autoMax) {
                hi = 1;
                series.forEach(s => s.data.forEach(v => { if (v > hi) hi = v; }));
                hi *= 1.15;
            }
            const span = Math.max(1e-9, hi - minValue);
            const n = root.histLen;
            const X = i => w - (n - 1 - i) * (w / (n - 1));
            const Y = v => pad + (h - 2 * pad) * (1 - Math.max(0, Math.min(1, (v - minValue) / span)));

            series.forEach(s => {
                const d = s.data;
                if (!d || d.length < 2) return;
                const off = n - d.length;
                const pts = d.map((v, i) => [X(i + off), Y(v)]);

                // kurva halus (midpoint quadratic)
                const path = () => {
                    ctx.moveTo(pts[0][0], pts[0][1]);
                    for (let i = 1; i < pts.length - 1; i++) {
                        const mx = (pts[i][0] + pts[i + 1][0]) / 2, my = (pts[i][1] + pts[i + 1][1]) / 2;
                        ctx.quadraticCurveTo(pts[i][0], pts[i][1], mx, my);
                    }
                    const last = pts[pts.length - 1];
                    ctx.lineTo(last[0], last[1]);
                };

                const c = s.color;
                const grad = ctx.createLinearGradient(0, 0, 0, h);
                grad.addColorStop(0, Qt.rgba(c.r, c.g, c.b, 0.32));
                grad.addColorStop(1, Qt.rgba(c.r, c.g, c.b, 0.0));
                ctx.beginPath(); path();
                ctx.lineTo(pts[pts.length - 1][0], h); ctx.lineTo(pts[0][0], h); ctx.closePath();
                ctx.fillStyle = grad; ctx.fill();

                ctx.beginPath(); path();
                ctx.strokeStyle = c; ctx.lineWidth = 2; ctx.lineJoin = "round"; ctx.stroke();

                const last = pts[pts.length - 1];
                ctx.beginPath(); ctx.arc(last[0] - 3, last[1], 3, 0, Math.PI * 2);
                ctx.fillStyle = c; ctx.fill();
            });
        }
    }

    // bar horizontal dengan label kiri & detail kanan
    component Meter: Column {
        id: mtr
        property string label
        property string detail
        property real value: 0
        property color tint: root.cAccent
        spacing: 4
        Item {
            width: parent.width
            height: 14
            Text {
                text: mtr.label
                color: root.cText
                font { family: root.fUi; pixelSize: 11; weight: Font.DemiBold }
            }
            Text {
                anchors.right: parent.right
                text: mtr.detail
                color: root.cMuted
                font { family: root.fUi; pixelSize: 11 }
            }
        }
        Rectangle {
            width: parent.width
            height: 6
            radius: 3
            color: root.cSurface2
            Rectangle {
                width: Math.max(height, parent.width * Math.min(1, mtr.value))
                height: parent.height
                radius: 3
                color: mtr.tint
                Behavior on width { NumberAnimation { duration: 400; easing.type: Easing.OutCubic } }
            }
        }
    }
}
