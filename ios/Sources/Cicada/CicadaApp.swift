import Combine
import SwiftUI

@main
struct CicadaApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(model.ling)
                .environmentObject(model.notes)
                .environmentObject(model.room)
                .onOpenURL { model.open($0) }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    model.room.appBecameActive()
                }
                .modifier(DevWindow(model: model))
        }
    }
}

enum AppTab: String { case records, settings, search }

/// Settings the iOS app shares with the Mac by name (AppSettings in Settings.swift), so a record
/// and its languages mean the same thing on both.
enum Pref {
    /// 对方说: "auto" or a `sourceLanguages` locale.
    static let source = "sourceMode"
    /// 翻译成: "system" or a `targetLanguages` code.
    static let target = "target"
    static let model = "aiModel"
    /// 说话人识别.
    static let voices = "speakerVoices"
    /// 纪要语言: "mine" (the language meetings are translated into) or "source" (the meeting's own).
    static let notesLanguage = "notesLanguage"
    /// 会中改正听错的词, and 没见过的名字和专称先问我.
    static let fixMisheard = "fixMisheard"
    static let askNames = "askNames"
    static let codeSwitchRefine = "codeSwitchRefine"
    /// 声音来源 (iOS only): "room", people at the table, or "speaker", video this phone plays aloud.
    static let hear = "iosHear"
    static var speakerMode: Bool { UserDefaults.standard.string(forKey: hear) == "speaker" }

    /// 对方说 on iOS: one language the user picks (detecting it comes later); the Mac's "auto" reads as English.
    static var sourceLang: Lang {
        let v = UserDefaults.standard.string(forKey: source) ?? "en-US"
        return sourceLanguages.first { $0.locale == v } ?? sourceLanguages[0]
    }

    /// 对方说 in the UI's language ("英语", "English"), as the Mac's menu shows it.
    static func name(of lang: Lang) -> String {
        Locale.current.localizedString(forLanguageCode: lang.code) ?? lang.name
    }
    static var sourceName: String { name(of: sourceLang) }

    /// "英 → 中" for two translation codes, as a meeting row says it.
    static func pairText(_ source: String, _ target: String) -> String {
        let line = TranscriptLine(id: "", t: 0, speaker: "them", src: "", dst: nil, srcLang: source, dstLang: target)
        let s = Session(id: "", title: "", startedAt: Date(), endedAt: nil, lines: [line], hasAudio: false)
        return RecordList.pair(s, short: true) ?? ""
    }

    static var targetCode: String {
        let t = UserDefaults.standard.string(forKey: target) ?? "system"
        return t == "system" ? myLanguage(systemLanguages: Locale.preferredLanguages) : t
    }
}

/// 改正听错的词's two switches, by the Mac's names (AppSettings).
@MainActor
final class FixPrefs: FixSwitches {
    var fixMisheard: Bool { UserDefaults.standard.bool(forKey: Pref.fixMisheard) }
    var askNames: Bool { UserDefaults.standard.bool(forKey: Pref.askNames) }
}

/// Wires the shared engines to the screens, like the Mac's AppModel. M1: the records, the key and
/// their notes.
@MainActor
final class AppModel: ObservableObject {
    @Published var store = SessionStore()
    let ling = LingClient()
    lazy var notes = NotesEngine(ling: ling, store: store)
    lazy var translator = TranslationService(ling: ling)
    lazy var room: RoomListen = {
        let r = RoomListen(store: store, translator: translator, notes: notes)
        r.onStateChange = { [weak self] in self?.listeningChanged() }
        r.onLine = { [weak self] line in self?.showOnLockScreen(line) }
        // The floating window follows the 字幕 page: what is being said, else the newest line.
        roomWatch = r.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async { self?.showInPiP() }
        }
        return r
    }()
    let pip = PiPSubtitles()
    private var roomWatch: AnyCancellable?
    let liveActivity = LiveActivityController()
    /// 词表 and 改正听错的词, the Mac's own engines.
    let vocabulary = Vocabulary(url: Vocabulary.defaultURL)
    lazy var fixes = makeFixes()
    /// 正在听's 字幕 / 纪要 switch, so a debug command can flip it.
    @Published var livePage: LivePage = .subtitles
    /// The record page's picked speaker (scheme A: only they are drawn in ink).
    @Published var focusSpeaker: Int?
    @Published var tab: AppTab = .records
    @Published var selection: String?
    /// A meeting opened from 搜索 (iPhone).
    @Published var searchPath: [String] = []
    /// The record page's 文字记录 / 纪要 switch, kept here so a debug command can flip it.
    @Published var recordPage: RecordPage = .transcript
    @Published var query = ""
    /// iPad: settings is a sheet over the records.
    @Published var showSettings = false
    /// What the 听会议室 card and the import button would start; they come with M2 and M3.
    @Published var comingSoon: String?
    /// "说话人 6 已改成 David · 撤销", for a few seconds after a speaker edit, as on the Mac.
    @Published var speakerUndo: SpeakerUndo?
    /// The speaker number whose 是谁 prompt is open on the record page.
    @Published var namingSpeaker: Int?
    /// 改正听错的词: the line being rewritten (改这句…), the record line tapped open, and 设置 › 词表's
    /// state (pushed, 粘贴导入's text, the word being edited, the word just deleted).
    @Published var editingLine: LineEdit?
    @Published var openLine: String?
    @Published var showWordList = false
    @Published var wordImport: String?
    @Published var editingWord: String?
    @Published var deletedWord: DeletedWord?
    @Published var wordConflict: WordConflict?
    /// Dev only: the iPad window size `window:` lays the app out at (DevWindow in Debug.swift).
    @Published var devWindow: CGSize?

    init() {
        UserDefaults.standard.register(defaults: [Pref.source: "en-US", Pref.voices: true, Pref.model: LingClient.models[0], Pref.notesLanguage: "mine",
                                                  Pref.fixMisheard: true, Pref.askNames: true, Pref.codeSwitchRefine: true])
        TranscriptExport.voices = UserDefaults.standard.bool(forKey: Pref.voices)
        // Ling only for now: the Mac's other services (AIProvider) come to iOS with their settings.
        ling.config = {
            AIConfig(provider: .ling, base: AIProvider.ling.base,
                     textModel: UserDefaults.standard.string(forKey: Pref.model) ?? LingClient.models[0])
        }
        wireNotes()
        wireFixes()
        #if targetEnvironment(simulator)
        HostRecognizer.install()
        #endif
        DebugChannel.listen(self)
        debugLog("ios launch \(DevBuild.label ?? "release") sessions=\(store.sessions.count) key=\(ling.hasKey)")
        if ling.hasKey { Task { await ling.check() } }
    }

    // MARK: 听会议室

    func startListening() {
        guard !room.isRunning else { return }
        selection = nil
        searchPath = []
        tab = .records
        fixes.meetingStarted()
        room.start(source: Pref.sourceLang.locale, target: Pref.targetCode, voices: UserDefaults.standard.bool(forKey: Pref.voices),
                   speaker: Pref.speakerMode)
    }

    private func showInPiP() {
        guard room.isRunning, room.speakerMode else { return }
        let last = room.lines.last
        let shown = last.flatMap { l in store.session(room.sessionID)?.lines.first { $0.id == l.id }?.shown } ?? last?.src
        if room.paused || !room.status.isEmpty {
            pip.show(src: "", dst: "", note: room.paused ? L("已暂停，结束后接着听") : room.status)
        } else if !room.draft.isEmpty {
            pip.show(src: room.draft, dst: room.draftTranslation, note: L("正在听外放…"))
        } else {
            pip.show(src: shown ?? "", dst: last?.dst ?? "", note: shown == nil ? L("正在听外放…") : "")
        }
    }

    func stopListening() { room.stop() }

    /// The Live Activity shows the line as fixed (改正听错的词), like the 字幕 page.
    func showOnLockScreen(_ line: RoomListen.Line) {
        var shown = line
        if let rec = store.session(room.sessionID)?.lines.first(where: { $0.id == line.id }) { shown.src = rec.shown }
        liveActivity.update(line: shown)
    }

    private func listeningChanged() {
        objectWillChange.send()
        pip.setEnabled(room.isRunning && room.speakerMode)
        if room.isRunning, let start = room.startedAt {
            liveActivity.start(startedAt: start, pair: Pref.pairText(room.languagePair.source, room.languagePair.target))
        } else if !room.isRunning {
            liveActivity.end()
        }
    }

    /// Full notes for a stored meeting, as the Mac's 生成纪要.
    func generateNotes(_ id: String) {
        guard ling.hasKey else { return }
        recordPage = .notes
        notes.generate(for: id)
    }

    /// Each finished sentence's translation also asks which words were misheard (Ling only); the
    /// word list's known forms are fixed as soon as a line is written. As the Mac's AppModel.
    func wireFixes() {
        translator.fixContext = { [weak self] text in self?.fixes.context(for: text) }
        translator.onFixes = { [weak self] text, edits in self?.fixes.received(text, edits) }
        translator.useCodeSwitchRefine = { UserDefaults.standard.bool(forKey: Pref.codeSwitchRefine) }
        room.onHeard = { [weak self] session, line in self?.fixes.applyKnown(lineID: line, in: session) }
        room.onSourceRefined = { [weak self] session, line in self?.fixes.applyKnown(lineID: line, in: session) }
    }

    func makeFixes() -> LiveFixes {
        let f = LiveFixes(store: store, vocabulary: vocabulary, settings: FixPrefs())
        f.onChange = { [weak self] in self?.objectWillChange.send() }
        // The lock screen follows a fix on the line it shows.
        f.onLineFixed = { [weak self] session, line in
            guard let self, session == self.room.sessionID, let last = self.room.lines.last, last.id == line.id else { return }
            self.showOnLockScreen(last)
        }
        vocabulary.onChange = { [weak self] in self?.objectWillChange.send() }
        return f
    }

    func wireNotes() {
        notes.language = { [weak self] id in TranslationService.englishName(self?.notesLanguageCode(id) ?? Pref.targetCode) }
    }

    // MARK: Notes language (the Mac's AppModel.notesLanguageCode)

    /// The language the other side spoke most in a meeting.
    func meetingLanguage(_ id: String) -> String? {
        let heard = store.session(id)?.lines.filter { $0.speaker != "me" }.map(\.srcLang) ?? []
        return Dictionary(heard.map { ($0, 1) }, uniquingKeysWith: +).max { $0.value < $1.value }?.key
    }

    func notesLanguageCode(_ id: String) -> String {
        UserDefaults.standard.string(forKey: Pref.notesLanguage) == "source" ? (meetingLanguage(id) ?? Pref.targetCode) : Pref.targetCode
    }

    // MARK: Editing a record (the Mac's rules live in SessionStore)

    /// An unchanged title isn't a rename; an empty one goes back to the automatic title.
    func rename(_ id: String, to title: String) {
        store.rename(id, to: title)
        debugLog("rename \(id) renamed=\(store.session(id)?.renamed ?? false)")
    }

    func deleteSession(_ id: String) {
        if selection == id { selection = nil }
        searchPath.removeAll { $0 == id }
        if speakerUndo?.session == id { speakerUndo = nil }
        store.delete(id)
        debugLog("delete \(id) sessions=\(store.sessions.count)")
    }

    // MARK: 词表

    /// Swiped away: 撤销 in its place for a few seconds, as on the Mac.
    func deleteWord(_ t: Vocabulary.Term) {
        let index = vocabulary.terms.firstIndex(of: t) ?? 0
        vocabulary.remove(t.word)
        let d = DeletedWord(term: t, index: index)
        deletedWord = d
        if editingWord == t.word { editingWord = nil }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            if self?.deletedWord == d { self?.deletedWord = nil }
        }
    }

    /// A heard form typed on a word: added, or, when another word has it, asked about (改给 / 两个都留).
    func addHeard(_ text: String, to t: Vocabulary.Term) {
        let h = text.trimmingCharacters(in: .whitespaces)
        guard !h.isEmpty, h.count <= 40 else { return }
        if let owner = vocabulary.owners(ofHeard: h, except: t.word).first {
            wordConflict = WordConflict(word: t.word, heard: h, owner: owner)
        } else {
            vocabulary.confirm(heard: h, word: t.word, source: t.source)
        }
    }

    // MARK: Speakers (the Mac's AppModel.renameSpeaker / mergeSpeaker / undoSpeakerEdit)

    /// Name a voice ("" keeps 说话人 N, nil goes back to Ling's guess).
    func renameSpeaker(session id: String, voice: Int, _ name: String?) {
        guard let s = store.session(id) else { return }
        let n = SpeakerLabels.voiceNumbers(s.lines)[voice] ?? 0
        let before = SpeakerLabels.label(n, SpeakerLabels.names(s))
        speakerEdit(id) { store.setVoiceName(id, voice: voice, name) }
        let after = store.session(id).map { SpeakerLabels.label(n, SpeakerLabels.names($0)) } ?? before
        if after != before { speakerUndo?.text = L("\(before) 已改成 \(after)") } else { speakerUndo = nil }
    }

    /// Two voices are one person.
    func mergeSpeaker(session id: String, _ from: Int, into: Int) {
        guard let s = store.session(id) else { return }
        let numbers = SpeakerLabels.voiceNumbers(s.lines), names = SpeakerLabels.names(s)
        let a = SpeakerLabels.label(numbers[from] ?? 0, names), b = SpeakerLabels.label(numbers[into] ?? 0, names)
        speakerEdit(id) { store.mergeVoice(id, from, into: into) }
        speakerUndo?.text = L("\(a) 已并入 \(b)")
    }

    func undoSpeakerEdit() {
        guard let u = speakerUndo else { return }
        speakerUndo = nil
        store.restore(u.session, u.snapshot)
        debugLog("speakers: undo \(u.session)")
    }

    private func speakerEdit(_ id: String, _ change: () -> Void) {
        guard let snap = store.voiceSnapshot(id) else { return }
        change()
        let undo = SpeakerUndo(session: id, snapshot: snap, text: "")
        speakerUndo = undo
        debugLog("speakers: edit \(id)")
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            if self?.speakerUndo?.id == undo.id { self?.speakerUndo = nil }
        }
    }

    /// cicada-dev://debug?cmd=… (dev builds only).
    func open(_ url: URL) {
        guard DevBuild.isDev, url.scheme == "cicada-dev", url.host == "debug",
              let cmd = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "cmd" })?.value else { return }
        debugCommand(cmd)
    }
}
