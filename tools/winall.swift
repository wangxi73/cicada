import CoreGraphics
let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as! [[String: Any]]
for w in list { let o = w[kCGWindowOwnerName as String] as? String ?? "?"; let pid = w[kCGWindowOwnerPID as String] as? Int ?? 0
 if pid == Int(CommandLine.arguments[1])! { let b = w[kCGWindowBounds as String] as! [String: Any]; print(o, w[kCGWindowNumber as String]!, b["Width"]!, b["Height"]!, w[kCGWindowIsOnscreen as String] ?? false) } }
