import QtQuick
import QtQuick.Controls
import QtQuick.Effects

// FR — layar login SDDM. Wallpaper lockscreen (blur + redup seperti hyprlock) jadi panggung:
// jam besar di kiri bawah, panel kaca setinggi layar di kanan berisi login, sesi, dan daya.
// Warna, nama, foto, dan wallpaper diisi `fr-sddm sync` dari config rice.
Rectangle {
    id: root
    width: 1920
    height: 1080

    // ── palet (kunci sama dengan fr-theme/themes.json) ─────────────
    QtObject {
        id: pal
        readonly property color bg:       config.bg       || "#0B0F17"
        readonly property color surface:  config.surface  || "#121826"
        readonly property color surface2: config.surface2 || "#1A2233"
        readonly property color border:   config.border   || "#24304A"
        readonly property color text:     config.text     || "#E6EAF2"
        readonly property color muted:    config.muted    || "#8A96AD"
        readonly property color accent:   config.accent   || "#6EA8FE"
        readonly property color warn:     config.warn     || "#F2C46D"
        readonly property color urgent:   config.urgent   || "#F27A7A"
        readonly property string font:     config.font     || "Inter"
        readonly property string iconFont: config.iconFont || "JetBrainsMono Nerd Font"
    }

    // efek MultiEffect butuh GPU (RHI); di renderer software, UI tetap tampil tanpa efek
    readonly property bool fx: GraphicsInfo.api !== GraphicsInfo.Software && GraphicsInfo.api !== GraphicsInfo.Unknown

    function num(v, d) { var n = Number(v); return v === undefined || v === "" || isNaN(n) ? d : n }

    // skala dari tinggi layar (1.0 = 1080p); posisi di bawah ini meniru hyprlock-editorial
    readonly property real s: Math.max(0.75, Math.min(1.4, height / 1080))
    readonly property real side: 96 * s
    readonly property var loc: Qt.locale(config.locale || "id_ID")

    property int userIndex: userModel.lastIndex >= 0 ? userModel.lastIndex : 0
    property int sessionIndex: sessionModel.lastIndex >= 0 ? sessionModel.lastIndex : 0
    property bool busy: false
    property int attempts: 0
    property bool failed: false

    color: pal.bg

    // role SDDM UserModel: Qt.UserRole + 1..4
    function userData(role) {
        if (userModel.count === 0) return ""
        var v = userModel.data(userModel.index(userIndex, 0), role)
        return v === undefined || v === null ? "" : String(v)
    }
    readonly property string userName: userData(257)
    readonly property bool isProfileUser: (config.displayUser || "") !== "" && config.displayUser === userName
    readonly property string displayName: isProfileUser && config.displayName ? config.displayName
                                        : userData(258) !== "" ? userData(258) : userName
    readonly property string avatarSource: isProfileUser && config.avatar ? Qt.resolvedUrl(config.avatar) : userData(260)

    function doLogin() {
        if (busy || userName === "" || password.text.length === 0) return
        busy = true
        failed = false
        sddm.login(userName, password.text, sessionIndex)
    }

    Connections {
        target: sddm
        function onLoginFailed() {
            root.busy = false
            root.attempts += 1
            root.failed = true
            password.text = ""
            shake.restart()
            password.forceActiveFocus()
        }
        function onLoginSucceeded() { fadeOut.start() }
    }

    // ── wallpaper: blur + redup seperti background{} hyprlock ───────
    Item {
        id: wall
        anchors.fill: parent
        layer.enabled: root.fx
        layer.effect: MultiEffect {
            blurEnabled: root.num(config.blur, 0.45) > 0
            blur: root.num(config.blur, 0.45)
            blurMax: 48
            saturation: root.num(config.saturation, 0.1)
        }

        Image {
            anchors.fill: parent
            source: config.background || ""
            fillMode: Image.PreserveAspectCrop
            asynchronous: true
            cache: false
            visible: status === Image.Ready
        }
        Loader {
            anchors.fill: parent
            active: config.backgroundType === "video" && (config.video || "") !== ""
            source: "VideoBg.qml"
            onLoaded: item.file = Qt.resolvedUrl(config.video)
        }
    }

    // redup: dikali, bukan dikurangi (seperti brightness=0.74 di hyprlock), jadi bayangan nggak jadi hitam pekat
    Rectangle {
        anchors.fill: parent
        color: pal.bg
        opacity: root.num(config.dim, 0.3)
    }

    // ── layout ─────────────────────────────────────────────────────
    // Kiri: jam besar di atas wallpaper. Kanan: panel kaca setinggi layar berisi login.
    readonly property real panelW: Math.min(480 * s, width * 0.36)
    readonly property real floor: 96 * s
    property date now: new Date()
    Timer { interval: 1000; running: true; repeat: true; onTriggered: root.now = new Date() }

    function greeting() {
        var h = now.getHours()
        return h < 11 ? "Selamat pagi" : h < 15 ? "Selamat siang" : h < 18 ? "Selamat sore" : "Selamat malam"
    }

    // tombol ikon bulat (daya) dengan tooltip
    component RoundBtn: AbstractButton {
        id: rb
        property int glyph: 0
        property bool danger: false
        width: 44 * root.s; height: width
        hoverEnabled: true
        focusPolicy: Qt.TabFocus
        Accessible.name: text
        onHoveredChanged: bottomBar.hint = hovered ? text : ""
        onActiveFocusChanged: bottomBar.hint = activeFocus ? text : ""
        contentItem: Text {
            text: String.fromCodePoint(rb.glyph)
            font.family: pal.iconFont
            font.pixelSize: 18 * root.s
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            color: rb.hovered || rb.activeFocus ? (rb.danger ? pal.urgent : pal.accent) : pal.muted
            Behavior on color { ColorAnimation { duration: 150 } }
        }
        background: Rectangle {
            radius: width / 2
            color: rb.hovered || rb.activeFocus ? Qt.rgba(pal.surface2.r, pal.surface2.g, pal.surface2.b, 0.9)
                                               : Qt.rgba(1, 1, 1, 0.04)
            border.width: 1
            border.color: rb.activeFocus ? pal.accent : Qt.rgba(1, 1, 1, 0.07)
            Behavior on color { ColorAnimation { duration: 150 } }
        }
    }

    // ── kiri: jam ──────────────────────────────────────────────────
    Item {
        id: left
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: panel.left

        // bayangan teks seperti di lockscreen
        layer.enabled: root.fx
        layer.effect: MultiEffect {
            shadowEnabled: true
            shadowColor: Qt.rgba(0, 0, 0, 0.5)
            shadowBlur: 0.7
            shadowVerticalOffset: 3
            autoPaddingEnabled: false
        }

        // atas: logo + hostname
        Row {
            x: root.side
            y: 48 * root.s
            spacing: 10 * root.s
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: ""
                font.family: pal.iconFont
                font.pixelSize: 18 * root.s
                color: pal.accent
            }
            Text {
                anchors.verticalCenter: parent.verticalCenter
                text: sddm.hostName
                font.family: pal.font
                font.weight: Font.Medium
                font.pixelSize: 14 * root.s
                color: pal.text
                opacity: 0.85
            }
        }

        Column {
            id: clock
            x: root.side
            anchors.bottom: parent.bottom
            anchors.bottomMargin: root.floor - 24 * root.s
            spacing: 0
            opacity: 0
            transform: Translate { id: clockT; y: 18 * root.s }

            // label tanggal kecil berspasi, gaya editorial
            Row {
                spacing: 12 * root.s
                Rectangle {
                    width: 28 * root.s; height: 3 * root.s; radius: height / 2
                    color: pal.accent
                    anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                    text: root.loc.toString(root.now, "dddd · d MMMM").toUpperCase()
                    font.family: pal.font
                    font.weight: Font.Bold
                    font.pixelSize: 14 * root.s
                    font.letterSpacing: 3.5 * root.s
                    color: pal.accent
                }
            }
            Row {
                spacing: 0
                Text {
                    text: Qt.formatDateTime(root.now, "HH")
                    font.family: pal.font
                    font.weight: Font.ExtraBold
                    font.pixelSize: 210 * root.s
                    font.letterSpacing: -8 * root.s
                    color: pal.text
                }
                Text {
                    text: ":"
                    font.family: pal.font
                    font.weight: Font.ExtraBold
                    font.pixelSize: 210 * root.s
                    color: pal.accent
                    leftPadding: 2 * root.s
                    rightPadding: 2 * root.s
                    // titik dua sedikit naik biar sejajar tengah angka
                    transform: Translate { y: -12 * root.s }
                    SequentialAnimation on opacity {
                        loops: Animation.Infinite
                        NumberAnimation { to: 0.35; duration: 900; easing.type: Easing.InOutSine }
                        NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
                    }
                }
                Text {
                    text: Qt.formatDateTime(root.now, "mm")
                    font.family: pal.font
                    font.weight: Font.ExtraBold
                    font.pixelSize: 210 * root.s
                    font.letterSpacing: -8 * root.s
                    color: pal.text
                }
            }
        }
    }

    // ── kanan: panel kaca ──────────────────────────────────────────
    Item {
        id: panel
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        anchors.right: parent.right
        width: root.panelW
        clip: true
        opacity: 0
        transform: Translate { id: panelT; x: 40 * root.s }

        // kaca: wallpaper di belakang panel diblur lebih kuat + tint warna tema
        ShaderEffectSource {
            id: behind
            visible: false
            sourceItem: wall
            sourceRect: Qt.rect(root.width - panel.width, 0, panel.width, panel.height)
        }
        MultiEffect {
            anchors.fill: parent
            visible: root.fx
            source: behind
            blurEnabled: true
            blur: 1.0
            blurMax: 64
            saturation: 0.15
            autoPaddingEnabled: false   // jangan meluber ke luar panel
        }
        Rectangle {
            anchors.fill: parent
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(pal.bg.r, pal.bg.g, pal.bg.b, 0.50) }
                GradientStop { position: 1.0; color: Qt.rgba(pal.bg.r, pal.bg.g, pal.bg.b, 0.72) }
            }
        }
        // garis tepi kiri: sorot tipis
        Rectangle {
            width: 1
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            gradient: Gradient {
                GradientStop { position: 0.0; color: Qt.rgba(1, 1, 1, 0.02) }
                GradientStop { position: 0.5; color: Qt.rgba(1, 1, 1, 0.12) }
                GradientStop { position: 1.0; color: Qt.rgba(1, 1, 1, 0.02) }
            }
        }

        readonly property real pad: 56 * root.s

        // ── isi tengah panel ──
        Column {
            id: card
            anchors.centerIn: parent
            anchors.verticalCenterOffset: -24 * root.s
            width: panel.width - panel.pad * 2
            spacing: 0

            // avatar dengan cincin aksen + pendar
            Item {
                anchors.horizontalCenter: parent.horizontalCenter
                width: 132 * root.s; height: width

                Rectangle {   // pendar
                    anchors.centerIn: parent
                    width: parent.width * 1.5; height: width
                    radius: width / 2
                    visible: root.fx
                    color: pal.accent
                    opacity: 0.22
                    layer.enabled: root.fx
                    layer.effect: MultiEffect { blurEnabled: true; blur: 1.0; blurMax: 64 }
                }
                Rectangle {   // cincin
                    anchors.fill: parent
                    radius: width / 2
                    color: "transparent"
                    border.width: 2.5 * root.s
                    border.color: pal.accent
                }
                Item {
                    id: avatar
                    anchors.fill: parent
                    anchors.margins: 9 * root.s

                    Rectangle {
                        anchors.fill: parent
                        radius: width / 2
                        color: pal.surface2
                        Text {
                            anchors.centerIn: parent
                            visible: avatarImg.status !== Image.Ready || !root.fx
                            text: root.displayName.length ? root.displayName.charAt(0).toUpperCase() : "?"
                            font.family: pal.font
                            font.weight: Font.Bold
                            font.pixelSize: 48 * root.s
                            color: pal.accent
                        }
                    }
                    Image {
                        id: avatarImg
                        anchors.fill: parent
                        source: root.avatarSource
                        sourceSize: Qt.size(width * 2, height * 2)
                        fillMode: Image.PreserveAspectCrop
                        asynchronous: true
                        visible: false
                    }
                    Rectangle {
                        id: avatarMask
                        anchors.fill: parent
                        radius: width / 2
                        visible: false
                        layer.enabled: true
                    }
                    MultiEffect {
                        anchors.fill: parent
                        source: avatarImg
                        visible: avatarImg.status === Image.Ready && root.fx
                        maskEnabled: true
                        maskSource: avatarMask
                    }
                }
            }

            Item { width: 1; height: 28 * root.s }

            Text {
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.greeting() + ","
                font.family: pal.font
                font.pixelSize: 16 * root.s
                color: pal.muted
            }
            Item { width: 1; height: 4 * root.s }

            // satu user: nama besar / banyak user: pilihan user
            Text {
                visible: userModel.count <= 1
                width: parent.width
                horizontalAlignment: Text.AlignHCenter
                text: root.displayName
                font.family: pal.font
                font.weight: Font.Bold
                font.pixelSize: 32 * root.s
                font.letterSpacing: -0.5 * root.s
                color: pal.text
                elide: Text.ElideRight
            }
            FrCombo {
                visible: userModel.count > 1
                anchors.horizontalCenter: parent.horizontalCenter
                implicitHeight: 46 * root.s
                pal: pal; s: root.s
                strong: true
                font.pixelSize: 28 * root.s
                font.weight: Font.Bold
                model: userModel
                textRole: "realName"
                displayText: root.displayName
                currentIndex: root.userIndex
                onActivated: function(i) { root.userIndex = i; root.failed = false; password.forceActiveFocus() }
                Accessible.name: "Pilih akun"
            }

            Item { width: 1; height: 36 * root.s }

            // field password
            Item {
                id: field
                width: parent.width
                height: 56 * root.s

                transform: Translate { id: shakeT }
                SequentialAnimation {
                    id: shake
                    NumberAnimation { target: shakeT; property: "x"; to: -10; duration: 50 }
                    NumberAnimation { target: shakeT; property: "x"; to: 10; duration: 70 }
                    NumberAnimation { target: shakeT; property: "x"; to: -6; duration: 70 }
                    NumberAnimation { target: shakeT; property: "x"; to: 0; duration: 60 }
                }

                TextField {
                    id: password
                    objectName: "password"
                    anchors.fill: parent
                    echoMode: TextInput.Password
                    passwordCharacter: "●"
                    verticalAlignment: TextInput.AlignVCenter
                    leftPadding: 50 * root.s
                    rightPadding: 60 * root.s
                    font.family: pal.font
                    font.pixelSize: 14 * root.s
                    font.letterSpacing: text.length ? 5 * root.s : 0
                    color: pal.text
                    selectionColor: pal.accent
                    selectedTextColor: pal.bg
                    placeholderText: "Password"
                    placeholderTextColor: Qt.rgba(pal.text.r, pal.text.g, pal.text.b, 0.42)
                    enabled: !root.busy
                    focus: true
                    Accessible.name: "Password " + root.displayName
                    onAccepted: root.doLogin()
                    onTextEdited: root.failed = false
                    background: Rectangle {
                        radius: height / 2
                        color: Qt.rgba(pal.surface.r, pal.surface.g, pal.surface.b, 0.75)
                        border.width: password.activeFocus || root.failed || keyboard.capsLock ? 2 * root.s : 1
                        border.color: root.busy ? pal.accent
                                    : root.failed ? pal.urgent
                                    : keyboard.capsLock ? pal.warn
                                    : password.activeFocus ? Qt.rgba(pal.accent.r, pal.accent.g, pal.accent.b, 0.7)
                                    : Qt.rgba(1, 1, 1, 0.1)
                        Behavior on border.color { ColorAnimation { duration: 180 } }
                    }
                }
                Text {
                    anchors.left: parent.left
                    anchors.leftMargin: 20 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    text: String.fromCodePoint(0xF033E)   // gembok
                    font.family: pal.iconFont
                    font.pixelSize: 17 * root.s
                    color: password.activeFocus ? pal.accent : pal.muted
                    Behavior on color { ColorAnimation { duration: 180 } }
                }
                AbstractButton {
                    id: go
                    anchors.right: parent.right
                    anchors.rightMargin: 6 * root.s
                    anchors.verticalCenter: parent.verticalCenter
                    width: 44 * root.s; height: width
                    hoverEnabled: true
                    focusPolicy: Qt.TabFocus
                    enabled: password.text.length > 0 && !root.busy
                    Accessible.name: "Masuk"
                    onClicked: root.doLogin()
                    contentItem: Text {
                        text: String.fromCodePoint(root.busy ? 0xF0772 : 0xF0054)
                        font.family: pal.iconFont
                        font.pixelSize: 19 * root.s
                        color: go.enabled || root.busy ? pal.bg : pal.muted
                        horizontalAlignment: Text.AlignHCenter
                        verticalAlignment: Text.AlignVCenter
                        RotationAnimation on rotation {
                            running: root.busy; loops: Animation.Infinite
                            from: 0; to: 360; duration: 900
                        }
                    }
                    background: Rectangle {
                        radius: width / 2
                        color: go.enabled || root.busy ? (go.hovered ? Qt.lighter(pal.accent, 1.1) : pal.accent)
                                                       : Qt.rgba(1, 1, 1, 0.06)
                        border.width: go.activeFocus ? 2 : 0
                        border.color: pal.text
                        Behavior on color { ColorAnimation { duration: 180 } }
                    }
                }
            }

            Item { width: 1; height: 14 * root.s }

            // status (tinggi dipesan biar layout nggak loncat)
            Text {
                width: parent.width
                height: 18 * root.s
                horizontalAlignment: Text.AlignHCenter
                font.family: pal.font
                font.pixelSize: 13 * root.s
                text: root.failed ? "Password salah, coba lagi (" + root.attempts + ")"
                    : keyboard.capsLock ? "Caps Lock nyala"
                    : "Tekan Enter untuk masuk"
                color: root.failed ? pal.urgent
                     : keyboard.capsLock ? pal.warn
                     : Qt.rgba(pal.text.r, pal.text.g, pal.text.b, 0.45)
                Behavior on color { ColorAnimation { duration: 180 } }
            }
        }

        // ── bawah panel: sesi + daya ──
        Rectangle {
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: bottomBar.top
            anchors.leftMargin: panel.pad
            anchors.rightMargin: panel.pad
            anchors.bottomMargin: 20 * root.s
            height: 1
            color: Qt.rgba(1, 1, 1, 0.07)
        }
        Item {
            id: bottomBar
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            anchors.leftMargin: panel.pad - 13 * root.s
            anchors.rightMargin: panel.pad
            anchors.bottomMargin: 40 * root.s
            height: 44 * root.s
            property string hint: ""

            // nama tombol daya yang sedang ditunjuk
            Text {
                anchors.right: parent.right
                anchors.bottom: parent.top
                anchors.bottomMargin: 30 * root.s
                text: bottomBar.hint
                opacity: bottomBar.hint ? 1 : 0
                font.family: pal.font
                font.pixelSize: 12 * root.s
                font.letterSpacing: 1 * root.s
                color: pal.muted
                Behavior on opacity { NumberAnimation { duration: 140 } }
            }

            FrCombo {
                id: sessionBox
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                pal: pal; s: root.s
                glyph: 0xF0379
                openUp: true
                model: sessionModel
                textRole: "name"
                currentIndex: root.sessionIndex
                onActivated: function(i) { root.sessionIndex = i; password.forceActiveFocus() }
                Accessible.name: "Sesi"
            }
            Row {
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                spacing: 8 * root.s
                RoundBtn { visible: sddm.canSuspend;  glyph: 0xF0904; text: "Tidur";       onClicked: sddm.suspend() }
                RoundBtn { visible: sddm.canReboot;   glyph: 0xF0709; text: "Mulai ulang"; onClicked: sddm.reboot() }
                RoundBtn { visible: sddm.canPowerOff; glyph: 0xF0425; text: "Matikan";     danger: true; onClicked: sddm.powerOff() }
            }
        }
    }

    // masuk: panel geser dari kanan, jam naik pelan
    ParallelAnimation {
        running: true
        NumberAnimation { target: panel;  property: "opacity"; to: 1; duration: 520; easing.type: Easing.OutCubic }
        NumberAnimation { target: panelT; property: "x";       to: 0; duration: 620; easing.type: Easing.OutCubic }
        SequentialAnimation {
            PauseAnimation { duration: 120 }
            ParallelAnimation {
                NumberAnimation { target: clock;  property: "opacity"; to: 1; duration: 620; easing.type: Easing.OutCubic }
                NumberAnimation { target: clockT; property: "y";       to: 0; duration: 720; easing.type: Easing.OutCubic }
            }
        }
    }

    // fade pas login berhasil
    Rectangle {
        anchors.fill: parent
        color: pal.bg
        opacity: 0
        NumberAnimation on opacity { id: fadeOut; running: false; to: 1; duration: 350 }
    }

    Component.onCompleted: password.forceActiveFocus()
}
