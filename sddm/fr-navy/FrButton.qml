import QtQuick
import QtQuick.Controls

// Tombol ikon Nerd Font + label, transparan sampai di-hover (dipakai di kanan atas)
AbstractButton {
    id: control

    property var pal
    property real s: 1
    property int glyph: 0
    property bool danger: false

    readonly property bool lit: hovered || activeFocus

    implicitHeight: 44 * s
    implicitWidth: row.implicitWidth + 26 * s
    focusPolicy: Qt.TabFocus
    hoverEnabled: true
    Accessible.name: text

    contentItem: Item {
        Row {
            id: row
            anchors.centerIn: parent
            spacing: 9 * control.s
            Text {
                text: String.fromCodePoint(control.glyph)
                font.family: control.pal.iconFont
                font.pixelSize: 17 * control.s
                color: control.lit ? (control.danger ? control.pal.urgent : control.pal.accent) : control.pal.muted
                anchors.verticalCenter: parent.verticalCenter
                Behavior on color { ColorAnimation { duration: 150 } }
            }
            Text {
                text: control.text
                font.family: control.pal.font
                font.pixelSize: 15 * control.s
                color: control.lit ? control.pal.text : control.pal.muted
                anchors.verticalCenter: parent.verticalCenter
                Behavior on color { ColorAnimation { duration: 150 } }
            }
        }
    }

    background: Rectangle {
        radius: height / 2
        color: Qt.rgba(control.pal.bg.r, control.pal.bg.g, control.pal.bg.b, control.down ? 0.7 : control.lit ? 0.5 : 0)
        border.width: control.activeFocus ? 1.5 : 0
        border.color: control.pal.accent
        Behavior on color { ColorAnimation { duration: 150 } }
    }
}
