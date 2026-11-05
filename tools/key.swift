import CoreGraphics
import Foundation

// Hold a key or the right ⌥ alone, as the talk key would be held.
//   key                      ⌥ Space for 1.5 s (the old default)
//   key right [seconds]      right ⌥ on its own
//   key <keyCode> <carbonModifiers> [seconds]   e.g. key 49 4096 → ⌃ Space
let args = CommandLine.arguments
let hold = useconds_t((Double(args.count > 3 ? args[3] : (args.count == 3 && args[1] == "right" ? args[2] : "1.5")) ?? 1.5) * 1_000_000)

if args.count > 1 && args[1] == "right" {
    let down = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: true)!
    down.type = .flagsChanged
    down.flags = CGEventFlags(rawValue: CGEventFlags.maskAlternate.rawValue | 0x40)
    down.post(tap: .cghidEventTap)
    usleep(hold)
    let up = CGEvent(keyboardEventSource: nil, virtualKey: 61, keyDown: false)!
    up.type = .flagsChanged
    up.flags = CGEventFlags(rawValue: 0)
    up.post(tap: .cghidEventTap)
    exit(0)
}

let code = CGKeyCode(args.count > 1 ? Int(args[1]) ?? 49 : 49)
let carbon = args.count > 2 ? Int(args[2]) ?? 2048 : 2048
var flags = CGEventFlags()
if carbon & 256 != 0 { flags.insert(.maskCommand) }
if carbon & 512 != 0 { flags.insert(.maskShift) }
if carbon & 2048 != 0 { flags.insert(.maskAlternate) }
if carbon & 4096 != 0 { flags.insert(.maskControl) }
let d = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true)!; d.flags = flags; d.post(tap: .cghidEventTap)
usleep(hold)
let u = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false)!; u.flags = flags; u.post(tap: .cghidEventTap)
