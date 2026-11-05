import CoreGraphics
import Foundation
// ⌃⌥S tap
let d = CGEvent(keyboardEventSource: nil, virtualKey: 1, keyDown: true)!; d.flags = [.maskControl, .maskAlternate]; d.post(tap: .cghidEventTap)
usleep(80_000)
let u = CGEvent(keyboardEventSource: nil, virtualKey: 1, keyDown: false)!; u.flags = [.maskControl, .maskAlternate]; u.post(tap: .cghidEventTap)
