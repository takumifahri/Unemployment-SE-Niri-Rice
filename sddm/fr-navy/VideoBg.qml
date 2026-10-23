import QtQuick
import QtMultimedia

// Dimuat lewat Loader hanya kalau backgroundType=video,
// jadi mode gambar tetap jalan walau qt6-multimedia belum terpasang.
Video {
    property url file
    source: file
    fillMode: VideoOutput.PreserveAspectCrop
    loops: MediaPlayer.Infinite
    muted: true
    Component.onCompleted: play()
}
