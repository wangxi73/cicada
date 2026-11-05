import Foundation
import CoreGraphics
// usage: mouse move x y | mouse drag x1 y1 x2 y2 | mouse dclick x y | mouse click x y | mouse scroll x y lines
// (Cocoa coords, origin bottom-left of main screen; scroll lines > 0 scrolls the content up, toward older lines)
let a = CommandLine.arguments
let H = CGDisplayBounds(CGMainDisplayID()).height
func p(_ x: String, _ y: String) -> CGPoint { CGPoint(x: Double(x)!, y: Double(H) - Double(y)!) }
func post(_ t: CGEventType, _ pt: CGPoint, clicks: Int64 = 1) {
  let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: pt, mouseButton: .left)!
  e.setIntegerValueField(.mouseEventClickState, value: clicks); e.post(tap: .cghidEventTap)
}
switch a[1] {
case "move": post(.mouseMoved, p(a[2], a[3]))
case "drag":
  let s = p(a[2], a[3]), d = p(a[4], a[5])
  post(.mouseMoved, s); usleep(900_000)            // rest so editing activates
  post(.leftMouseDown, s); usleep(80_000)
  for i in 1...20 { let f = Double(i)/20; post(.leftMouseDragged, CGPoint(x: s.x + (d.x-s.x)*f, y: s.y + (d.y-s.y)*f)); usleep(20_000) }
  post(.leftMouseUp, d)
case "dclick":
  let s = p(a[2], a[3]); post(.mouseMoved, s); usleep(600_000)
  post(.leftMouseDown, s, clicks: 1); post(.leftMouseUp, s, clicks: 1); usleep(50_000)
  post(.leftMouseDown, s, clicks: 2); post(.leftMouseUp, s, clicks: 2)
case "click":
  let s = p(a[2], a[3]); post(.mouseMoved, s); usleep(300_000)
  post(.leftMouseDown, s); post(.leftMouseUp, s)
case "scroll":
  post(.mouseMoved, p(a[2], a[3])); usleep(200_000)
  let n = Int32(a[4])!
  for _ in 0..<abs(n) {
    CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: n > 0 ? 3 : -3, wheel2: 0, wheel3: 0)!.post(tap: .cghidEventTap)
    usleep(30_000)
  }
default: break
}
