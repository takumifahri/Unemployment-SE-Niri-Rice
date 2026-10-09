//@ pragma IconTheme Papirus-Dark
pragma ComponentBehavior: Bound

// FR Navy — layar pilih area QR (dibuka oleh `fr-wifiqr image`)
//   QR yang terdeteksi otomatis langsung ditandai.
//   Tarik kotak di mana saja untuk memilih area lain, klik kotak putus-putus untuk memilihnya.
//   Enter = sambung · A = seluruh gambar · Esc = batal
// Env: FR_QR_IMAGE (gambar), FR_QR_CHOICE (file tempat menulis pilihan untuk fr-wifiqr)

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
    readonly property color cOnAccent: "#0B0F17"
    readonly property color cWarn:     "#F2C46D"
    readonly property color cUrgent:   "#F27A7A"
    readonly property string fUi:   "Inter"
    readonly property string fIcon: "JetBrainsMono Nerd Font"
    function ic(cp) { return String.fromCodePoint(cp); }

    readonly property string imagePath: Quickshell.env("FR_QR_IMAGE")
    readonly property string choiceFile: Quickshell.env("FR_QR_CHOICE")
    readonly property string tool: Quickshell.env("HOME") + "/.local/bin/fr-wifiqr"

    // ── state ────────────────────────────────────────────
    property var detected: []          // hasil scan seluruh gambar (dengan rect)
    property var result: []            // hasil scan pilihan saat ini
    property var sel: null             // [x, y, w, h] piksel gambar; null = seluruh gambar
    property bool scanning: false
    readonly property var best: result.length ? result[0] : null

    function scan(rect) {
        scanning = true;
        scanProc.command = rect ? [tool, "scan", imagePath, "--rect", rect.map(v => Math.round(v)).join(",")]
                                : [tool, "scan", imagePath];
        scanProc.running = true;
    }
    Process {
        id: scanProc
        stdout: StdioCollector {
            onStreamFinished: {
                let list = [];
                try { list = JSON.parse(this.text.trim() || "[]"); } catch (e) {}
                root.result = list;
                // scan pertama (seluruh gambar): simpan & pilih QR Wi-Fi yang terdeteksi
                if (root.sel === null && root.detected.length === 0 && list.length) {
                    root.detected = list.filter(c => c.rect);
                    const w = list.find(c => c.wifi && c.rect);
                    if (w) root.sel = w.rect;
                }
                root.scanning = false;
            }
        }
    }

    function finish(value) {
        saveProc.command = ["sh", "-c", 'printf %s "$1" > "$2"', "sh", value, choiceFile];
        saveProc.running = true;
    }
    Process { id: saveProc; onExited: Qt.quit() }

    function confirm() {
        if (!best || scanning) return;
        finish(sel ? sel.map(v => Math.round(v)).join(",") : "all");
    }
    function selectAll() { sel = null; scan(null); }

    Component.onCompleted: scan(null)

    PanelWindow {
        id: win
        anchors { top: true; bottom: true; left: true; right: true }
        color: "transparent"
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Overlay
        WlrLayershell.namespace: "fr-wifiqr"
        WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive

        Rectangle { anchors.fill: parent; color: root.tone(root.cBg, 0.86) }

        Item {
            anchors.fill: parent
            focus: true
            Keys.onPressed: e => {
                if (e.key === Qt.Key_Escape) root.finish("");
                else if (e.key === Qt.Key_Return || e.key === Qt.Key_Enter) root.confirm();
                else if (e.key === Qt.Key_A) root.selectAll();
                else return;
                e.accepted = true;
            }
        }

        // judul
        Column {
            id: header
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.top: parent.top
            anchors.topMargin: 36
            spacing: 4
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Pilih QR Wi-Fi"
                color: root.cText
                font { family: root.fUi; pixelSize: 20; weight: Font.Bold }
            }
            Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "Tarik kotak di sekitar QR  ·  klik kotak putus-putus untuk memilihnya"
                color: root.cMuted
                font { family: root.fUi; pixelSize: 13 }
            }
        }

        // gambar + pilihan
        Item {
            id: stage
            anchors { top: header.bottom; bottom: bar.top; left: parent.left; right: parent.right
                      topMargin: 24; bottomMargin: 24; leftMargin: 80; rightMargin: 80 }

            Image {
                id: img
                anchors.fill: parent
                source: "file://" + root.imagePath
                fillMode: Image.PreserveAspectFit
                smooth: true
                mipmap: true
                asynchronous: true
                // pemetaan piksel gambar ↔ layar
                readonly property real k: implicitWidth > 0 ? paintedWidth / implicitWidth : 1
                readonly property real ox: (width - paintedWidth) / 2
                readonly property real oy: (height - paintedHeight) / 2
                function toView(r) { return Qt.rect(ox + r[0] * k, oy + r[1] * k, r[2] * k, r[3] * k); }
                function toImage(x, y) {
                    return [Math.max(0, Math.min(implicitWidth, (x - ox) / k)),
                            Math.max(0, Math.min(implicitHeight, (y - oy) / k))];
                }
            }

            // gelapkan di luar pilihan
            Item {
                anchors.fill: parent
                visible: root.sel !== null && img.status === Image.Ready
                readonly property rect v: root.sel ? img.toView(root.sel) : Qt.rect(0, 0, 0, 0)
                readonly property color dim: root.tone(root.cBg, 0.62)
                Rectangle { x: img.ox; y: img.oy; width: img.paintedWidth; height: Math.max(0, parent.v.y - img.oy); color: parent.dim }
                Rectangle { x: img.ox; y: parent.v.y + parent.v.height; width: img.paintedWidth
                            height: Math.max(0, img.oy + img.paintedHeight - parent.v.y - parent.v.height); color: parent.dim }
                Rectangle { x: img.ox; y: parent.v.y; width: Math.max(0, parent.v.x - img.ox); height: parent.v.height; color: parent.dim }
                Rectangle { x: parent.v.x + parent.v.width; y: parent.v.y
                            width: Math.max(0, img.ox + img.paintedWidth - parent.v.x - parent.v.width); height: parent.v.height; color: parent.dim }
            }

            // QR terdeteksi lain (putus-putus)
            Repeater {
                model: root.detected
                delegate: Canvas {
                    id: det
                    required property var modelData
                    readonly property rect v: img.toView(modelData.rect)
                    x: v.x - 6; y: v.y - 6; width: v.width + 12; height: v.height + 12
                    visible: img.status === Image.Ready
                    onWidthChanged: requestPaint()
                    onPaint: {
                        const c = getContext("2d"); c.reset();
                        c.setLineDash([6, 5]); c.lineWidth = 2;
                        c.strokeStyle = det.modelData.wifi ? root.cAccent : root.cMuted;
                        c.strokeRect(1, 1, width - 2, height - 2);
                    }
                }
            }

            // kotak pilihan dengan siku di sudut
            Item {
                id: selBox
                visible: root.sel !== null && img.status === Image.Ready
                readonly property rect v: root.sel ? img.toView(root.sel) : Qt.rect(0, 0, 0, 0)
                x: v.x; y: v.y; width: v.width; height: v.height
                readonly property color col: root.scanning ? root.cMuted : root.best && root.best.wifi ? root.cAccent
                                           : root.best ? root.cWarn : root.cUrgent
                Rectangle { anchors.fill: parent; color: "transparent"; border.width: 1; border.color: root.tone(selBox.col, 0.6) }
                Repeater {
                    model: 4
                    delegate: Item {
                        required property int index
                        readonly property bool r: index % 2 === 1
                        readonly property bool b: index >= 2
                        x: r ? selBox.width - 22 + 3 : -3
                        y: b ? selBox.height - 22 + 3 : -3
                        width: 22; height: 22
                        Rectangle { x: parent.r ? parent.width - 4 : 0; width: 4; height: parent.height; radius: 2; color: selBox.col }
                        Rectangle { y: parent.b ? parent.height - 4 : 0; width: parent.width; height: 4; radius: 2; color: selBox.col }
                    }
                }
            }

            // garis bantu saat menarik
            Rectangle {
                id: rubber
                visible: drag.active
                color: root.tone(root.cAccent, 0.12)
                border.color: root.cAccent
                border.width: 2
            }

            MouseArea {
                id: drag
                anchors.fill: parent
                cursorShape: Qt.CrossCursor
                property bool active: false
                property real sx: 0
                property real sy: 0
                onPressed: m => { sx = m.x; sy = m.y; active = false; }
                onPositionChanged: m => {
                    if (!pressed) return;
                    if (!active && Math.hypot(m.x - sx, m.y - sy) > 6) active = true;
                    if (!active) return;
                    rubber.x = Math.min(sx, m.x); rubber.y = Math.min(sy, m.y);
                    rubber.width = Math.abs(m.x - sx); rubber.height = Math.abs(m.y - sy);
                }
                onReleased: m => {
                    if (active) {
                        active = false;
                        const a = img.toImage(Math.min(sx, m.x), Math.min(sy, m.y));
                        const b = img.toImage(Math.max(sx, m.x), Math.max(sy, m.y));
                        if (b[0] - a[0] >= 12 && b[1] - a[1] >= 12) {
                            root.sel = [a[0], a[1], b[0] - a[0], b[1] - a[1]];
                            root.scan(root.sel);
                        }
                        return;
                    }
                    // klik: pilih QR terdeteksi di bawah kursor
                    const p = img.toImage(m.x, m.y);
                    const hit = root.detected.find(c => p[0] >= c.rect[0] && p[0] <= c.rect[0] + c.rect[2]
                                                        && p[1] >= c.rect[1] && p[1] <= c.rect[1] + c.rect[3]);
                    if (hit) { root.sel = hit.rect; root.scan(hit.rect); }
                }
            }
        }

        // bilah bawah: status + tombol
        Rectangle {
            id: bar
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 36
            width: Math.min(parent.width - 80, 720)
            height: 68
            radius: 20
            color: root.cBg
            border.color: root.cBorder

            Rectangle {
                id: badge
                x: 14
                anchors.verticalCenter: parent.verticalCenter
                width: 40; height: 40; radius: 12
                color: root.tone(statusCol.color, 0.14)
                Text {
                    id: statusCol
                    anchors.centerIn: parent
                    color: root.scanning ? root.cMuted : root.best && root.best.wifi ? root.cAccent : root.best ? root.cWarn : root.cUrgent
                    text: root.ic(root.scanning ? 0xf0450 : root.best && root.best.wifi ? 0xf05a9 : root.best ? 0xf0432 : 0xf0433)
                    font { family: root.fIcon; pixelSize: 20 }
                    RotationAnimation on rotation { running: root.scanning; loops: Animation.Infinite; from: 0; to: 360; duration: 900 }
                }
            }
            Column {
                anchors.left: badge.right
                anchors.leftMargin: 12
                anchors.right: buttons.left
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 2
                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    color: root.cText
                    font { family: root.fUi; pixelSize: 15; weight: Font.DemiBold }
                    text: root.scanning ? "Membaca QR…"
                        : root.best && root.best.wifi ? root.best.ssid
                        : root.best ? "QR ini bukan Wi-Fi"
                        : root.sel ? "Tidak ada QR di area ini" : "QR tidak terdeteksi otomatis"
                }
                Text {
                    width: parent.width
                    elide: Text.ElideRight
                    color: root.cMuted
                    font { family: root.fUi; pixelSize: 12 }
                    text: root.scanning ? ""
                        : root.best && root.best.wifi ? (root.best.type === "NOPASS" ? "Tanpa password" : root.best.type)
                                                        + (root.best.hidden ? "  ·  tersembunyi" : "") + "  ·  Enter untuk sambung"
                        : root.best ? root.best.text + "  ·  Enter untuk salin"
                        : "Tarik kotak sedikit lebih lebar dari QR-nya"
                }
            }
            Row {
                id: buttons
                anchors.right: parent.right
                anchors.rightMargin: 12
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8
                BarButton { label: "Seluruh gambar"; visible: root.sel !== null; onClicked: root.selectAll() }
                BarButton { label: "Batal"; onClicked: root.finish("") }
                BarButton {
                    primary: true
                    enabled: !root.scanning && root.best !== null
                    label: root.best && !root.best.wifi ? "Salin" : "Sambung"
                    onClicked: root.confirm()
                }
            }
        }
    }

    component BarButton: Rectangle {
        id: bb
        property string label
        property bool primary: false
        signal clicked()
        height: 40
        width: bbText.implicitWidth + 32
        radius: 12
        opacity: enabled ? 1 : 0.4
        color: primary ? (bbMa.containsMouse ? Qt.lighter(root.cAccent, 1.08) : root.cAccent)
                       : (bbMa.containsMouse ? root.cSurface2 : root.cSurface)
        border.color: primary ? root.cAccent : root.cBorder
        Text {
            id: bbText
            anchors.centerIn: parent
            text: bb.label
            color: bb.primary ? root.cOnAccent : root.cText
            font { family: root.fUi; pixelSize: 13; weight: Font.DemiBold }
        }
        MouseArea {
            id: bbMa
            anchors.fill: parent
            enabled: bb.enabled
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: bb.clicked()
        }
    }
}
