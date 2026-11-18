import SwiftUI
import UIKit

/// The iOS side of the Mac's `AppModel.debugCommand`. `ios/scripts/ctl.sh <cmd>` writes the command
/// into the container's Caches/debug-command and posts a Darwin notification, which wakes us here;
/// `simctl openurl` with cicada-dev://debug?cmd=… works too but asks for confirmation every time.
/// Same names as on the Mac where the command means the same thing.
enum DebugChannel {
    static let name = "com.wquguru.cicada.debug" as CFString
    static var file: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("debug-command")
    }

    @MainActor static func listen(_ model: AppModel) {
        guard DevBuild.isDev else { return }
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(center, Unmanaged.passUnretained(model).toOpaque(), { _, observer, _, _, _ in
            guard let observer else { return }
            let model = Unmanaged<AppModel>.fromOpaque(observer).takeUnretainedValue()
            DispatchQueue.main.async { MainActor.assumeIsolated { DebugChannel.drain(model) } }
        }, name, nil, .deliverImmediately)
    }

    /// One command per line, run in order.
    @MainActor static func drain(_ model: AppModel) {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return }
        try? FileManager.default.removeItem(at: file)
        for line in text.split(separator: "\n") where !line.isEmpty { model.debugCommand(String(line)) }
    }
}

extension AppModel {
    /// The meeting a fix command means: the live one, else the open one, else the newest.
    private var fixSession: String { store.liveID ?? selection ?? store.sessions.first?.id ?? "" }

    func debugCommand(_ cmd: String) {
        debugLog("debug command: \(cmd)")
        let (name, arg) = cmd.split(separator: ":", maxSplits: 1).map(String.init).splitPair
        switch name {
        case "open":
            tab = .records
            selection = nil
        case "settings":
            // iPhone: the tab; iPad: the sheet (the app can't tell which from here, so both).
            tab = .settings
            showSettings = true
        case "closeSettings":
            showSettings = false
            tab = .records
        case "listen", "start":
            startListening()
        case "window":
            // window:half|landscape|landscapeHalf|full: the iPad window drawn at that size (DevWindow).
            let s = UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen.bounds.size }.first ?? .zero
            let (short, long) = (min(s.width, s.height), max(s.width, s.height))
            switch arg {
            case "half": devWindow = CGSize(width: (short - 10) / 2, height: long)
            case "landscape": devWindow = CGSize(width: long, height: short)
            case "landscapeHalf": devWindow = CGSize(width: (long - 10) / 2, height: short)
            default: devWindow = nil
            }
            debugLog("window: \(arg) \(devWindow.map { "\($0)" } ?? "screen")")
        case "stop":
            stopListening()
        case "import":
            // What the import button shows until M3.
            comingSoon = L("导入录音或视频")
        case "hear":
            // hear:room|speaker, 声音来源
            UserDefaults.standard.set(arg == "speaker" ? "speaker" : "room", forKey: Pref.hear)
        case "interrupt":
            // interrupt:began|ended, what the system sends for a call or Siri
            room.debugInterrupt(arg != "ended")
        case "pip":
            pip.start()
        case "livePage":
            livePage = arg == "notes" ? .notes : .subtitles
        case "source":
            // source:<locale>, 对方说 (en-US, ja-JP…)
            UserDefaults.standard.set(arg, forKey: Pref.source)
        case "target":
            // target:<code|system>, 翻译成
            UserDefaults.standard.set(arg, forKey: Pref.target)
        case "focusSpeaker":
            // focusSpeaker:<speaker number>, as tapping a chip; empty clears it
            focusSpeaker = Int(arg)
        case "play":
            NotificationCenter.default.post(name: .debugPlay, object: Double(arg) ?? 0)
        case "search":
            tab = .search
            searchPath = []
            query = arg
        case "mainShow":
            // mainShow:<id>[,transcript|notes]; an empty id is the newest meeting
            let parts = arg.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            tab = .records
            selection = parts.first.flatMap { id in store.sessions.contains(where: { $0.id == id }) ? id : nil }
                ?? store.sessions.first?.id
            if parts.count > 1 { recordPage = parts[1] == "notes" ? .notes : .transcript }
        case "back":
            selection = nil
            searchPath = []
            comingSoon = nil
        case "reload":
            store = SessionStore()
            notes = NotesEngine(ling: ling, store: store)
            wireNotes()
            fixes = makeFixes()
        case "generateNotes":
            // generateNotes:<id>, as the record page's 生成纪要 (needs a key).
            generateNotes(arg.isEmpty ? (selection ?? store.sessions.first?.id ?? "") : arg)
        case "rename":
            // rename:<id>,<title> (an empty title goes back to the automatic one)
            let parts = arg.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            rename(parts[0], to: parts.count > 1 ? parts[1] : "")
        case "delete":
            deleteSession(arg)
        case "speakers":
            UserDefaults.standard.set(arg == "on", forKey: Pref.voices)
            TranscriptExport.voices = arg == "on"
            objectWillChange.send()
        case "notesLang":
            UserDefaults.standard.set(arg, forKey: Pref.notesLanguage)
        case "nameSpeaker":
            // nameSpeaker:<id>,<voice>,<name>
            let p = arg.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if p.count == 3, let v = Int(p[1]) { renameSpeaker(session: p[0], voice: v, p[2]) }
        case "mergeSpeaker":
            // mergeSpeaker:<id>,<from voice>,<into voice>
            let p = arg.split(separator: ",").map(String.init)
            if p.count == 3, let a = Int(p[1]), let b = Int(p[2]) { mergeSpeaker(session: p[0], a, into: b) }
        case "speakerPrompt":
            // speakerPrompt:<speaker number>: the 是谁 prompt a chip's 改名字 opens
            namingSpeaker = Int(arg)
        case "undoSpeaker":
            undoSpeakerEdit()
        // 改正听错的词, by the Mac's names: switches, the word list, and the fixes of a meeting
        // (the live one, or `<id>`, else the open one or the newest).
        case "fixes": UserDefaults.standard.set(arg != "off", forKey: Pref.fixMisheard)
        case "askNames": UserDefaults.standard.set(arg != "off", forKey: Pref.askNames)
        case "silentListen":
            // A meeting without the microphone or the recognizer, fed lines by `heard:`.
            RoomListen.silent = arg != "off"
        case "heard": room.debugHeard(arg)
        case "vocabAdd":   // vocabAdd:Morpho=莫拉、莫法 (several lines with "|")
            let r = vocabulary.importText(arg.replacingOccurrences(of: "|", with: "\n"))
            debugLog("vocab: added=\(r.added) updated=\(r.updated) skipped=\(r.skipped)")
        case "vocabRemove": vocabulary.remove(arg)
        case "vocabState":
            debugLog("vocab: \(vocabulary.terms.count) terms")
            for t in vocabulary.terms { contentLog("VOCAB \(t.word) heard=\(t.heard) source=\(t.source) fixes=\(t.fixes)") }
        case "fixState":
            let id = arg.isEmpty ? fixSession : arg
            let lines = store.session(id)?.lines ?? []
            let all = lines.flatMap { $0.fixes ?? [] }
            debugLog("fix state \(id): lines=\(lines.filter { $0.fixes != nil }.count) applied=\(all.filter(\.applied).count) "
                     + "asked=\(all.filter { $0.ask == true }.count) off=\(all.filter { $0.off == true }.count) on=\(FixPrefs().fixMisheard)")
            for l in lines where l.fixes != nil {
                contentLog("FIXED \(l.id) \(l.fixes!.map { "\($0.from)→\($0.to)\($0.ask == true ? "?" : $0.off == true ? "✗" : "")" }) | \(l.shown)")
            }
        // What the AI service would propose for a live line, without asking it (no key needed):
        // proposeFix:<line id>=<from>><to>@<confidence>[|…]
        case "proposeFix":
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let id = store.liveID, let l = store.session(id)?.lines.first(where: { $0.id == p[0] }) else { break }
            let edits = p[1].split(separator: "|").compactMap { e -> Correction.Edit? in
                let ft = e.split(separator: ">", maxSplits: 1).map(String.init)
                guard ft.count == 2 else { return nil }
                let tc = ft[1].split(separator: "@").map(String.init)
                return Correction.Edit(from: ft[0], to: tc[0], confidence: tc.count > 1 ? Double(tc[1]) ?? 0.9 : 0.9)
            }
            fixes.received(l.src, edits)
        case "fixAnswer":  // fixAnswer:yes|no[,<id>]
            let parts = arg.split(separator: ",", maxSplits: 1).map(String.init)
            let id = parts.count > 1 ? parts[1] : fixSession
            if let first = fixes.asking(in: id) ?? fixes.pending(in: id).first.map({ ($0.line, $0.fix, 1, 1) }) {
                fixes.answer(first.fix, yes: parts.first == "yes", in: id)
            }
        // The recheck without audio: line `<id>` settles as `<text>` and is translated (and fixed) again.
        case "resettle":   // resettle:<line id>=<text>
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2, let id = store.liveID, let rec = store.session(id)?.lines.first(where: { $0.id == p[0] }) else { break }
            store.setSource(in: id, lineID: rec.id, p[1])
            fixes.applyKnown(lineID: rec.id, in: id)
            Task { [weak self] in
                guard let self, let out = await self.translator.translate(p[1], source: rec.srcLang, target: rec.dstLang, kind: .sentence) else { return }
                self.store.setTranslation(in: id, lineID: rec.id, out)
            }
        case "fixLater":
            let id = arg.isEmpty ? store.liveID ?? "" : arg
            if let a = fixes.asking(in: id) { fixes.later(a.fix, in: id) }
        case "fixUndo": fixes.undo()
        case "fixEdit":   // fixEdit:<line id>=<new text>[|one|keep0][,<session id>]
            let (head, sid) = { () -> (String, String) in
                if let c = arg.lastIndex(of: ","), !arg[arg.index(after: c)...].contains("=") { return (String(arg[..<c]), String(arg[arg.index(after: c)...])) }
                return (arg, fixSession)
            }()
            let p = head.split(separator: "=", maxSplits: 1).map(String.init)
            guard p.count == 2 else { break }
            let opts = p[1].split(separator: "|").map(String.init)
            let n = fixes.edit(lineID: p[0], in: sid, to: opts[0], everywhere: !opts.contains("one"), remember: !opts.contains("keep0"))
            debugLog("fix edit changed \(n) lines")
        case "fixRevert":  // fixRevert:<line id>[,<session id>]: the line's first applied fix
            let parts = arg.split(separator: ",", maxSplits: 1).map(String.init)
            let id = parts.count > 1 ? parts[1] : fixSession
            if let l = store.session(id)?.lines.first(where: { $0.id == parts.first }), let f = l.fixes?.first(where: \.applied) {
                fixes.revert(f, lineID: l.id, in: id)
            }
        // The fix screens, for screenshots: a record line tapped open, 改这句… on a line (of the open
        // record), 设置 › 词表, 粘贴导入 with text ("|" for new lines), a word opened, a word swiped away.
        case "openLine": openLine = arg.isEmpty ? nil : arg
        case "scrollTo": NotificationCenter.default.post(name: .debugScroll, object: arg)
        case "fixEditor":   // fixEditor:<line id>[=<start text>]
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            let sid = selection ?? fixSession
            if let l = store.session(sid)?.lines.first(where: { $0.id == p.first }) {
                editingLine = LineEdit(session: sid, line: l.id, start: p.count > 1 ? p[1] : l.shown)
            }
        case "closeEditor": editingLine = nil
        case "wordList":
            tab = .settings
            showSettings = true
            showWordList = arg != "off"
        case "wordImport": wordImport = arg == "off" ? nil : arg.replacingOccurrences(of: "|", with: "\n")
        case "wordEdit": editingWord = arg.isEmpty ? nil : arg
        case "wordHeard":   // wordHeard:<word>=<heard form>, as typed on an opened word
            let p = arg.split(separator: "=", maxSplits: 1).map(String.init)
            if p.count == 2, let t = vocabulary.terms.first(where: { $0.word == p[0] }) { addHeard(p[1], to: t) }
        case "wordDelete":
            if let t = vocabulary.terms.first(where: { $0.word == arg }) { deleteWord(t) }
        case "state":
            debugLog("room running=\(room.isRunning) lines=\(room.lines.count) draft=\(room.draft.count) level=\(room.level) status=\(room.status) speaker=\(room.speakerMode) paused=\(room.paused) pip=\(pip.isActive) session=\(room.sessionID ?? "-")")
            debugLog("state tab=\(tab.rawValue) selection=\(selection ?? "-") page=\(recordPage) sessions=\(store.sessions.count) query=\(query) notesLang=\(notesLanguageCode(selection ?? store.sessions.first?.id ?? "")) undo=\(speakerUndo?.text ?? "-")")
        default:
            debugLog("debug command unknown: \(cmd)")
        }
    }
}

/// Dev only: the iPad windows the simulator can't be put into from a script. There is no
/// Simulator.app to rotate it, iPadOS refuses a programmatic rotation in windowed mode, and no API
/// sizes a window. So the app is laid out at that window's size and size class, scaled to fit.
struct DevWindow: ViewModifier {
    @ObservedObject var model: AppModel

    func body(content: Content) -> some View {
        if let size = model.devWindow {
            GeometryReader { geo in
                let scale = min(1, geo.size.width / size.width, geo.size.height / size.height)
                content
                    // iPadOS gives a window regular width from about 678 points.
                    .environment(\.horizontalSizeClass, size.width >= 678 ? .regular : .compact)
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .scaleEffect(scale, anchor: .topLeading)
                    .frame(width: size.width * scale, height: size.height * scale, alignment: .topLeading)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
            .background(Color(white: 0.3).ignoresSafeArea())
        } else {
            content
        }
    }
}

private extension Array where Element == String {
    var splitPair: (String, String) { (first ?? "", count > 1 ? self[1] : "") }
}
