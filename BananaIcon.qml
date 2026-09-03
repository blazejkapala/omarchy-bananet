import QtQuick
import qs.Commons

// Bar icon: a banana drawn natively so it follows the theme foreground like
// every other bar glyph (Nerd Font has no banana; the color emoji would clash).
Item {
  id: root

  property real iconSize: Style.font.icon
  property color color: Color.foreground

  width: iconSize
  height: iconSize
  implicitWidth: iconSize
  implicitHeight: iconSize

  onColorChanged: canvas.requestPaint()
  onIconSizeChanged: canvas.requestPaint()

  Canvas {
    id: canvas
    anchors.fill: parent
    antialiasing: true
    onPaint: {
      var ctx = getContext("2d")
      var s = width / 16
      ctx.reset()
      ctx.clearRect(0, 0, width, height)
      ctx.fillStyle = root.color
      ctx.strokeStyle = root.color
      ctx.lineJoin = "round"
      ctx.lineCap = "round"

      // Body: fat crescent with a nub at the bottom tip (prototyped against
      // the 🍌 silhouette; concave side faces up-right).
      ctx.beginPath()
      ctx.moveTo(4.0 * s, 2.6 * s)
      ctx.bezierCurveTo(0.4 * s, 7.6 * s, 3.0 * s, 13.6 * s, 11.2 * s, 14.7 * s)
      ctx.lineTo(13.6 * s, 15.0 * s)
      ctx.bezierCurveTo(14.6 * s, 15.1 * s, 14.6 * s, 13.7 * s, 13.7 * s, 13.6 * s)
      ctx.bezierCurveTo(7.8 * s, 13.0 * s, 5.2 * s, 8.8 * s, 6.9 * s, 2.9 * s)
      ctx.closePath()
      ctx.fill()

      // Stem.
      ctx.lineWidth = Math.max(1, 1.5 * s)
      ctx.beginPath()
      ctx.moveTo(4.7 * s, 2.8 * s)
      ctx.lineTo(4.3 * s, 0.6 * s)
      ctx.stroke()
    }
  }
}
