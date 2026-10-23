import QtQuick
import QtQuick.Controls

// Pilihan (sesi / user). Transparan seperti FrButton; popup bergaya panel FR.
ComboBox {
    id: control

    property var pal
    property real s: 1
    property int glyph: 0
    property bool alignRight: false
    // true = teks utama (nama user): warna teks penuh, tebal, 18px
    property bool strong: false
    // true = daftar terbuka ke atas (dipakai di bawah layar)
    property bool openUp: false

    implicitHeight: 44 * s
    implicitWidth: label.implicitWidth + (glyph ? 26 : 0) * s + 56 * s
    font.family: pal.font
    font.pixelSize: (strong ? 18 : 15) * s
    font.weight: strong ? Font.DemiBold : Font.Normal
    hoverEnabled: true

    readonly property bool lit: hovered || activeFocus || popup.visible

    contentItem: Item {
        Row {
            anchors.left: parent.left
            anchors.leftMargin: 13 * control.s
            anchors.verticalCenter: parent.verticalCenter
            spacing: 9 * control.s
            Text {
                visible: control.glyph !== 0
                text: control.glyph ? String.fromCodePoint(control.glyph) : ""
                font.family: control.pal.iconFont
                font.pixelSize: 17 * control.s
                color: control.lit ? control.pal.accent : control.pal.muted
                anchors.verticalCenter: parent.verticalCenter
            }
            Text {
                id: label
                text: control.displayText
                font: control.font
                color: control.lit || control.strong ? control.pal.text : control.pal.muted
                anchors.verticalCenter: parent.verticalCenter
            }
        }
    }

    indicator: Text {
        x: control.width - width - 14 * control.s
        anchors.verticalCenter: parent.verticalCenter
        text: String.fromCodePoint(0xF0140)   // chevron-down
        font.family: control.pal.iconFont
        font.pixelSize: 15 * control.s
        color: control.pal.muted
        rotation: control.popup.visible ? 180 : 0
        Behavior on rotation { NumberAnimation { duration: 160; easing.type: Easing.OutCubic } }
    }

    background: Rectangle {
        radius: height / 2
        color: Qt.rgba(control.pal.bg.r, control.pal.bg.g, control.pal.bg.b, control.lit ? 0.5 : 0)
        border.width: control.activeFocus ? 1.5 : 0
        border.color: control.pal.accent
        Behavior on color { ColorAnimation { duration: 150 } }
    }

    delegate: ItemDelegate {
        id: item
        required property int index
        required property var model
        width: control.popup.width - 12 * control.s
        x: 6 * control.s
        height: 40 * control.s
        highlighted: control.highlightedIndex === index
        contentItem: Text {
            leftPadding: 10 * control.s
            text: item.model[control.textRole]
            font: control.font
            color: item.index === control.currentIndex ? control.pal.accent : control.pal.text
            verticalAlignment: Text.AlignVCenter
            elide: Text.ElideRight
        }
        background: Rectangle {
            radius: 10 * control.s
            color: item.highlighted ? control.pal.surface2 : "transparent"
        }
    }

    popup: Popup {
        x: control.alignRight ? control.width - width : 0
        y: control.openUp ? -implicitHeight - 6 * control.s : control.height + 6 * control.s
        width: Math.max(control.width, 220 * control.s)
        implicitHeight: Math.min(contentItem.implicitHeight + 12 * control.s, 300 * control.s)
        padding: 6 * control.s
        contentItem: ListView {
            clip: true
            implicitHeight: contentHeight
            model: control.popup.visible ? control.delegateModel : null
            currentIndex: control.highlightedIndex
        }
        background: Rectangle {
            radius: 16 * control.s
            color: control.pal.surface
            border.width: 1
            border.color: control.pal.border
        }
    }
}
