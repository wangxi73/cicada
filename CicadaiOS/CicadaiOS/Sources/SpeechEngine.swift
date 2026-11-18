import AVFoundation
import Combine
import Foundation
import ReplayKit

@MainActor
final class CicadaMobileViewModel: ObservableObject {
    @Published public var genai = GenAIClient()
    @Published var isListening = false
    @Published var webexMixMode = true
    @Published var speakerVoicesEnabled = true
    @Published var fixMisheard: Bool = UserDefaults.standard.object(forKey: "fixMisheard") as? Bool ?? true {
        didSet { UserDefaults.standard.set(fixMisheard, forKey: "fixMisheard") }
    }
    @Published var askNames: Bool = UserDefaults.standard.object(forKey: "askNames") as? Bool ?? true {
        didSet { UserDefaults.standard.set(askNames, forKey: "askNames") }
    }
    @Published var codeSwitchRefine: Bool = UserDefaults.standard.object(forKey: "codeSwitchRefine") as? Bool ?? true {
        didSet { UserDefaults.standard.set(codeSwitchRefine, forKey: "codeSwitchRefine") }
    }
    private let speakerTagger = MobileSpeakerTagger()
    @Published var replayKitActive = false
    @Published var isInterpretingHold = false
    @Published var speakingStatus = ""
    @Published var sourceLang: String = UserDefaults.standard.string(forKey: "sourceLang") ?? "en" {
        didSet { UserDefaults.standard.set(sourceLang, forKey: "sourceLang") }
    }
    @Published var targetLang: String = UserDefaults.standard.string(forKey: "targetLang") ?? "zh-CN" {
        didSet { UserDefaults.standard.set(targetLang, forKey: "targetLang") }
    }
    @Published var notesLang: String = UserDefaults.standard.string(forKey: "notesLang") ?? "zh-CN" {
        didSet {
            UserDefaults.standard.set(notesLang, forKey: "notesLang")
            if !currentSession.lines.isEmpty { updateNotesNow() }
        }
    }
    @Published var speakFromLang: String = UserDefaults.standard.string(forKey: "speakFromLang") ?? "zh-CN" {
        didSet { UserDefaults.standard.set(speakFromLang, forKey: "speakFromLang") }
    }
    @Published var ttsVoice: String = UserDefaults.standard.string(forKey: "ttsVoice") ?? "Kore" {
        didSet { UserDefaults.standard.set(ttsVoice, forKey: "ttsVoice") }
    }

    @Published var liveSourceVolatile = ""
    @Published var liveTranslatedVolatile = ""
    @Published var audioLevel: Float = 0
    @Published var updatingNotes = false
    @Published var currentSession = MeetingSession()
    @Published var history: [MeetingSession] = []
    @Published var vocabulary: [WordTermItem] = []
    @Published var speakerProfiles: [SpeakerProfileItem] = []
    @Published var isPlayingAudio = false
    @Published var playbackTime: TimeInterval = 0
    @Published var playbackDuration: TimeInterval = 0

    private let audioEngine = AVAudioEngine()
    private var notesTimer: Timer?
    private var nextLineID = 1

    // Pure AVAudioEngine VAD buffer (16 kHz mono Int16) - never touches SFSpeechRecognizer / assistantd
    private var vadSamples: [Int16] = []
    private var vadVoicedFrames = 0
    private var vadSilenceFrames = 0
    private var holdSamples: [Int16] = []
    private var meetingAudioSamples: [Int16] = []

    private var player: AVAudioPlayer?
    private var sessionPlayer: AVAudioPlayer?
    private var playbackTimer: Timer?
    private let synth = AVSpeechSynthesizer()

    init() {
        loadHistory()
        loadVocabulary()
        loadSpeakerProfiles()
    }

    func toggleListening() {
        isListening ? stopListening() : startListening()
    }

    func startListening() {
        AVAudioApplication.requestRecordPermission { [weak self] allowed in
            guard allowed else { return }
            Task { @MainActor in
                self?.beginSessionAndTap()
            }
        }
    }

    private func beginSessionAndTap() {
        if currentSession.endedAt != nil || currentSession.lines.isEmpty {
            currentSession = MeetingSession(sourceLang: sourceLang, targetLang: targetLang)
            nextLineID = 1
            speakerTagger.reset()
        }
        isListening = true
        vadSamples.removeAll()
        vadVoicedFrames = 0
        vadSilenceFrames = 0
        meetingAudioSamples.removeAll()
        startPureAudioTap()
        notesTimer?.invalidate()
        notesTimer = Timer.scheduledTimer(withTimeInterval: 12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateNotesNow() }
        }
    }

    func stopListening() {
        isListening = false
        notesTimer?.invalidate()
        flushVADSegment(force: true)
        stopPureAudioTap()
        liveSourceVolatile = ""
        currentSession.endedAt = Date()
        if !meetingAudioSamples.isEmpty {
            let filename = "cicada_audio_\(currentSession.id).wav"
            let wav = Self.makeWAV(samples16kMono: meetingAudioSamples)
            let url = audioURL(filename: filename)
            try? wav.write(to: url)
            currentSession.audioFilename = filename
            meetingAudioSamples.removeAll()
        }
        if !currentSession.lines.isEmpty {
            updateNotesNow()
            saveCurrentSession()
        }
    }

    private func startPureAudioTap() {
        stopPureAudioTap()
        let session = AVAudioSession.sharedInstance()
        let opts: AVAudioSession.CategoryOptions = webexMixMode
            ? [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP]
            : [.defaultToSpeaker]
        try? session.setCategory(.playAndRecord, mode: .default, options: opts)
        try? session.setActive(true, options: .notifyOthersOnDeactivation)
        installInterruptionObserver()

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0 else { return }
        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buf, _ in
            guard let self, let ch = buf.floatChannelData else { return }
            let n = Int(buf.frameLength)
            guard n > 0 else { return }
            var sum: Float = 0
            for i in 0..<n { sum += ch[0][i] * ch[0][i] }
            let rms = (sum / Float(n)).squareRoot()
            let scaledLevel = min(1.0, rms * 6.0)
            let step = max(1, Int((buf.format.sampleRate / 16000.0).rounded()))
            var downsampled: [Int16] = []
            downsampled.reserveCapacity(n / step + 1)
            var idx = 0
            while idx < n {
                let s = max(-1.0, min(1.0, ch[0][idx] * 1.8))
                downsampled.append(Int16(s * 32767.0))
                idx += step
            }
            Task { @MainActor in
                self.audioLevel = scaledLevel
                if self.isInterpretingHold {
                    if self.holdSamples.count < 16000 * 45 {
                        self.holdSamples.append(contentsOf: downsampled)
                    }
                } else if self.isListening {
                    self.meetingAudioSamples.append(contentsOf: downsampled)
                    self.processVADChunk(downsampled, rms: rms)
                }
            }
        }
        try? audioEngine.start()
    }

    private func stopPureAudioTap() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
    }

    private func processVADChunk(_ chunk: [Int16], rms: Float) {
        let isVoiced = rms >= 0.008
        if isVoiced {
            vadVoicedFrames += 1
            vadSilenceFrames = 0
            vadSamples.append(contentsOf: chunk)
            let secs = Double(vadSamples.count) / 16000.0
            liveSourceVolatile = String(format: "正在收音识别 (%.1fs)…", secs)
            if vadSamples.count >= 16000 * 6 {
                flushVADSegment(force: true)
            }
        } else if !vadSamples.isEmpty {
            vadSilenceFrames += 1
            vadSamples.append(contentsOf: chunk)
            if vadSilenceFrames >= 14 {
                flushVADSegment(force: false)
            }
        }
    }

    private func flushVADSegment(force: Bool) {
        let samples = vadSamples
        let voiced = vadVoicedFrames
        vadSamples.removeAll()
        vadVoicedFrames = 0
        vadSilenceFrames = 0
        liveSourceVolatile = ""
        guard voiced >= 4, samples.count >= 4800 else { return }

        let wav = Self.makeWAV(samples16kMono: samples)
        let lineID = nextLineID
        nextLineID += 1
        let elapsed = Date().timeIntervalSince(currentSession.startedAt)
        let placeholder = TranscriptLine(id: lineID, timestamp: elapsed, speaker: "会场", sourceText: "正在识别…", translatedText: "正在翻译…", isMe: false)
        currentSession.lines.append(placeholder)
        if speakerVoicesEnabled {
            speakerTagger.identify(samples16k: samples) { [weak self] label in
                guard let self, let idx = self.currentSession.lines.firstIndex(where: { $0.id == lineID }) else { return }
                self.currentSession.lines[idx].speaker = label
            }
        }

        let src = sourceLang
        let dst = targetLang
        let glossary = currentSession.notes.terms.map(\.name)
        let words = vocabulary.map { $0.heard.isEmpty ? $0.word : "\($0.word) (misheard: \($0.heard.joined(separator: ", ")))" }
        let recent = currentSession.lines.filter { $0.id != lineID && $0.sourceText != "正在识别…" }.suffix(3).map(\.shownSourceText)
        let useCodeSwitch = codeSwitchRefine
        let useFixes = fixMisheard
        let askUnknown = askNames

        Task {
            if let result = await genai.transcribeAndTranslate(
                audioWAV: wav, sourceLang: src, targetLang: dst,
                glossary: glossary, wordList: words, recent: recent,
                codeSwitchRefine: useCodeSwitch, fixMisheard: useFixes
            ) {
                if let idx = currentSession.lines.firstIndex(where: { $0.id == lineID }) {
                    currentSession.lines[idx].sourceText = result.source
                    currentSession.lines[idx].translatedText = result.translation
                    var lineFixes = result.fixes.map { f -> LineFixItem in
                        var item = f
                        if !askUnknown { item.ask = nil }
                        return item
                    }
                    if useFixes {
                        lineFixes = mergeKnownFixes(source: result.source, existing: lineFixes)
                    }
                    currentSession.lines[idx].fixes = lineFixes.isEmpty ? nil : lineFixes
                    saveCurrentSession()
                }
                if currentSession.lines.count == 1 || currentSession.lines.count % 3 == 0 {
                    updateNotesNow()
                }
            } else {
                currentSession.lines.removeAll { $0.id == lineID }
            }
        }
    }
}

extension CicadaMobileViewModel {
    private var vocabularyURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cicada_vocabulary.json")
    }

    private var profilesURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cicada_speaker_profiles.json")
    }

    func audioURL(filename: String) -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent(filename)
    }

    func loadVocabulary() {
        guard let data = try? Data(contentsOf: vocabularyURL),
              let saved = try? JSONDecoder().decode([WordTermItem].self, from: data) else { return }
        vocabulary = saved
    }

    func saveVocabulary() {
        if let data = try? JSONEncoder().encode(vocabulary) {
            try? data.write(to: vocabularyURL)
        }
    }

    func addVocabulary(word: String, heard: String = "") {
        let clean = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        let heardClean = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = vocabulary.firstIndex(where: { $0.word.caseInsensitiveCompare(clean) == .orderedSame }) {
            if !heardClean.isEmpty, !vocabulary[idx].heard.contains(heardClean) {
                vocabulary[idx].heard.append(heardClean)
            }
            vocabulary[idx].usedCount += 1
        } else {
            vocabulary.insert(WordTermItem(word: clean, heard: heardClean.isEmpty ? [] : [heardClean]), at: 0)
        }
        saveVocabulary()
    }

    func importVocabularyText(_ text: String) {
        let parts = text.components(separatedBy: CharacterSet(charactersIn: "\n,;，；"))
        for p in parts { addVocabulary(word: p) }
    }

    func removeVocabulary(word: String) {
        vocabulary.removeAll { $0.word == word }
        saveVocabulary()
    }

    private func mergeKnownFixes(source: String, existing: [LineFixItem]) -> [LineFixItem] {
        var out = existing
        for term in vocabulary {
            for h in term.heard where h.count >= 2 && source.contains(h) {
                if !out.contains(where: { $0.from == h }) {
                    out.append(LineFixItem(from: h, to: term.word, confidence: 1.0))
                }
            }
        }
        return out
    }

    var pendingAskFix: (lineID: Int, fix: LineFixItem)? {
        for l in currentSession.lines {
            if let f = l.fixes?.first(where: { $0.ask == true && $0.off != true }) {
                return (l.id, f)
            }
        }
        return nil
    }

    func answerFix(_ fix: LineFixItem, accept: Bool) {
        if accept { addVocabulary(word: fix.to, heard: fix.from) }
        for i in currentSession.lines.indices {
            guard var fixes = currentSession.lines[i].fixes else { continue }
            for j in fixes.indices where fixes[j].from == fix.from && fixes[j].to == fix.to {
                if accept {
                    fixes[j].ask = nil
                    fixes[j].user = true
                } else {
                    fixes[j].ask = nil
                    fixes[j].off = true
                }
            }
            currentSession.lines[i].fixes = fixes
        }
        saveCurrentSession()
    }

    func revertFix(_ fix: LineFixItem, lineID: Int) {
        guard let i = currentSession.lines.firstIndex(where: { $0.id == lineID }),
              var fixes = currentSession.lines[i].fixes else { return }
        for j in fixes.indices where fixes[j].from == fix.from && fixes[j].to == fix.to {
            fixes[j].off = true
            fixes[j].ask = nil
        }
        currentSession.lines[i].fixes = fixes
        saveCurrentSession()
    }

    func editLineSource(lineID: Int, newText: String) {
        let clean = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let i = currentSession.lines.firstIndex(where: { $0.id == lineID }) else { return }
        let oldShown = currentSession.lines[i].shownSourceText
        guard clean != oldShown else { return }
        let f = LineFixItem(from: oldShown, to: clean, confidence: 1.0, user: true)
        var list = currentSession.lines[i].fixes ?? []
        list.append(f)
        currentSession.lines[i].fixes = list
        saveCurrentSession()
    }

    func loadSpeakerProfiles() {
        guard let data = try? Data(contentsOf: profilesURL),
              let saved = try? JSONDecoder().decode([SpeakerProfileItem].self, from: data) else { return }
        speakerProfiles = saved
        speakerTagger.setSavedProfiles(saved)
    }

    func saveSpeakerProfiles() {
        if let data = try? JSONEncoder().encode(speakerProfiles) {
            try? data.write(to: profilesURL)
        }
        speakerTagger.setSavedProfiles(speakerProfiles)
    }

    func renameSpeaker(rawLabel: String, to newName: String) {
        let clean = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        var map = currentSession.speakerNames ?? [:]
        map[rawLabel] = clean
        currentSession.speakerNames = map
        saveCurrentSession()
        speakerTagger.centroid(for: rawLabel) { [weak self] centroid in
            guard let self, let centroid else { return }
            if let idx = self.speakerProfiles.firstIndex(where: { $0.name == clean }) {
                self.speakerProfiles[idx].centroid = centroid
                self.speakerProfiles[idx].sampleCount += 1
            } else {
                self.speakerProfiles.append(SpeakerProfileItem(name: clean, centroid: centroid))
            }
            self.saveSpeakerProfiles()
        }
    }

    func deleteSpeakerProfile(_ id: String) {
        speakerProfiles.removeAll { $0.id == id }
        saveSpeakerProfiles()
    }

    func saveEditedNotes(title: String, summary: String, topics: [NoteTopicItem]) {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cleanTitle.isEmpty {
            currentSession.title = cleanTitle
            currentSession.notes.title = cleanTitle
        }
        currentSession.notes.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        currentSession.notes.topics = topics
        saveCurrentSession()
    }

    func toggleAudioPlayback(for session: MeetingSession) {
        if isPlayingAudio {
            sessionPlayer?.pause()
            isPlayingAudio = false
            playbackTimer?.invalidate()
            return
        }
        guard let filename = session.audioFilename else { return }
        let url = audioURL(filename: filename)
        if sessionPlayer?.url != url {
            try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try? AVAudioSession.sharedInstance().setActive(true)
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
            sessionPlayer = p
            playbackDuration = p.duration
        }
        sessionPlayer?.play()
        isPlayingAudio = true
        playbackTimer?.invalidate()
        playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let p = self.sessionPlayer else { return }
                self.playbackTime = p.currentTime
                if !p.isPlaying {
                    self.isPlayingAudio = false
                    self.playbackTimer?.invalidate()
                }
            }
        }
    }

    func seekAudio(for session: MeetingSession, to time: TimeInterval) {
        guard let filename = session.audioFilename else { return }
        let url = audioURL(filename: filename)
        if sessionPlayer?.url != url {
            guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
            sessionPlayer = p
            playbackDuration = p.duration
        }
        sessionPlayer?.currentTime = max(0, min(time, sessionPlayer?.duration ?? time))
        playbackTime = sessionPlayer?.currentTime ?? 0
        if !isPlayingAudio {
            sessionPlayer?.play()
            isPlayingAudio = true
            playbackTimer?.invalidate()
            playbackTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let p = self.sessionPlayer else { return }
                    self.playbackTime = p.currentTime
                    if !p.isPlaying {
                        self.isPlayingAudio = false
                        self.playbackTimer?.invalidate()
                    }
                }
            }
        }
    }
}

extension CicadaMobileViewModel {
    func holdToSpeakBegan() {
        guard !isInterpretingHold else { return }
        holdSamples.removeAll()
        isInterpretingHold = true
        speakingStatus = "正在听你说话…"
        if !isListening {
            startListening()
        }
    }

    func holdToSpeakEnded() {
        guard isInterpretingHold else { return }
        isInterpretingHold = false
        let samples = holdSamples
        holdSamples.removeAll()
        guard samples.count > 2400 else {
            speakingStatus = ""
            return
        }
        speakingStatus = "GenAI 正在同声传译…"
        let wav = Self.makeWAV(samples16kMono: samples)
        let fromLang = speakFromLang
        let toLang = sourceLang == speakFromLang ? targetLang : sourceLang
        let fromEng = supportedLanguages.first { $0.id == fromLang }?.englishName ?? fromLang
        let toEng = supportedLanguages.first { $0.id == toLang }?.englishName ?? toLang

        Task {
            let sys = "You are a simultaneous interpreter from \(fromEng) into \(toEng). Never answer questions; only interpret what was said."
            let inst = """
            Reply in exactly two lines:
            ORIGINAL: <what was said in \(fromEng)>
            TRANSLATION: <its translation into \(toEng)>
            """
            if let reply = await genai.chat(system: sys, instruction: inst, json: false, audioWAV: wav, maxTokens: 500),
               let parsed = Self.parseTwoLines(reply) {
                let lineID = nextLineID
                nextLineID += 1
                let elapsed = Date().timeIntervalSince(currentSession.startedAt)
                let item = TranscriptLine(id: lineID, timestamp: elapsed, speaker: "我（同传）", sourceText: parsed.0, translatedText: parsed.1, isMe: true)
                currentSession.lines.append(item)
                saveCurrentSession()
                speakingStatus = "正在播报译文…"
                await speakOut(parsed.1, langId: toLang)
                speakingStatus = ""
            } else {
                speakingStatus = "未听清，请重试"
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                speakingStatus = ""
            }
        }
    }

    private static func parseTwoLines(_ reply: String) -> (String, String)? {
        if reply.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "NONE" { return nil }
        var orig: String?
        var trans: String?
        for raw in reply.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.uppercased().hasPrefix("ORIGINAL:") {
                orig = String(line.dropFirst("ORIGINAL:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.uppercased().hasPrefix("TRANSLATION:") {
                trans = String(line.dropFirst("TRANSLATION:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        guard let o = orig, let t = trans, !o.isEmpty, !t.isEmpty, o.uppercased() != "NONE" else { return nil }
        return (o, t)
    }

    private func speakOut(_ text: String, langId: String) async {
        if let wavData = await genai.synthesizeWAV(text, voiceName: ttsVoice, language: langId) {
            let finalWAV = Self.ensureWAVHeader(wavData, sampleRate: 24000)
            if let p = try? AVAudioPlayer(data: finalWAV) {
                self.player = p
                p.play()
                return
            }
        }
        let u = AVSpeechUtterance(string: text)
        let locale = supportedLanguages.first { $0.id == langId }?.locale ?? "en-US"
        u.voice = AVSpeechSynthesisVoice(language: locale)
        synth.speak(u)
    }

    private static func ensureWAVHeader(_ data: Data, sampleRate: UInt32) -> Data {
        if data.count > 4, String(data: data.prefix(4), encoding: .ascii) == "RIFF" {
            return data
        }
        var out = Data()
        let dataSize = UInt32(data.count)
        let totalSize = dataSize + 36
        let byteRate = sampleRate * 2
        let blockAlign: UInt16 = 2
        let bitsPerSample: UInt16 = 16
        out.append("RIFF".data(using: .ascii)!)
        withUnsafeBytes(of: totalSize.littleEndian) { out.append(contentsOf: $0) }
        out.append("WAVEfmt ".data(using: .ascii)!)
        withUnsafeBytes(of: UInt32(16).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt16(1).littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: sampleRate.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: byteRate.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: blockAlign.littleEndian) { out.append(contentsOf: $0) }
        withUnsafeBytes(of: bitsPerSample.littleEndian) { out.append(contentsOf: $0) }
        out.append("data".data(using: .ascii)!)
        withUnsafeBytes(of: dataSize.littleEndian) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }

    private static func makeWAV(samples16kMono: [Int16]) -> Data {
        var pcm = Data(capacity: samples16kMono.count * 2)
        for s in samples16kMono {
            withUnsafeBytes(of: s.littleEndian) { pcm.append(contentsOf: $0) }
        }
        return ensureWAVHeader(pcm, sampleRate: 16000)
    }

    func updateNotesNow() {
        let validLines = currentSession.lines.filter { $0.sourceText != "正在识别…" }
        guard !validLines.isEmpty, !updatingNotes else { return }
        updatingNotes = true
        let transcriptText = validLines.map { line in
            "\(line.id) [\(Self.clock(line.timestamp))] \(line.speaker): \(line.sourceText) (\(line.translatedText))"
        }.joined(separator: "\n")
        let noteLang = supportedLanguages.first { $0.id == notesLang }?.englishName ?? "Simplified Chinese"

        Task {
            defer { updatingNotes = false }
            let instruction = """
            Organize this meeting transcript into structured JSON in \(noteLang):
            {
              "title": "<concise meeting title>",
              "summary": "<2-4 sentence executive summary>",
              "topics": [{"title": "<topic>", "points": ["<point 1>", "<point 2>"]}],
              "conclusions": [{"text": "<key decision>", "lines": [1]}],
              "todos": [{"text": "<action item>", "owner": "<person>", "lines": [1]}],
              "terms": [{"name": "<term or name>", "note": "<brief explanation>"}]
            }
            Output valid JSON only.
            """
            if let jsonStr = await genai.chat(system: transcriptText, instruction: instruction, json: true, maxTokens: 1400),
               let data = jsonStr.data(using: .utf8),
               let decoded = try? JSONDecoder().decode(MeetingNotesData.self, from: data) {
                currentSession.notes = decoded
                if !decoded.title.isEmpty { currentSession.title = decoded.title }
                saveCurrentSession()
            }
        }
    }

    private var historyURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("cicada_sessions.json")
    }

    func saveCurrentSession() {
        guard !currentSession.lines.isEmpty else { return }
        if let idx = history.firstIndex(where: { $0.id == currentSession.id }) {
            history[idx] = currentSession
        } else {
            history.insert(currentSession, at: 0)
        }
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: historyURL)
        }
    }

    func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let saved = try? JSONDecoder().decode([MeetingSession].self, from: data) else { return }
        history = saved
    }

    func exportMarkdown(_ session: MeetingSession) -> String {
        var md = "# \(session.title)\n\n"
        if !session.notes.summary.isEmpty {
            md += "## 总结\n\(session.notes.summary)\n\n"
        }
        if !session.notes.topics.isEmpty {
            md += "## 议题要点\n"
            for t in session.notes.topics {
                md += "### \(t.title)\n"
                for p in t.points { md += "- \(p)\n" }
            }
            md += "\n"
        }
        if !session.notes.conclusions.isEmpty {
            md += "## 结论\n"
            for c in session.notes.conclusions { md += "- \(c.text)\n" }
            md += "\n"
        }
        if !session.notes.todos.isEmpty {
            md += "## 待办\n"
            for td in session.notes.todos { md += "- [ ] \(td.text) \(td.owner.map { "(@\($0))" } ?? "")\n" }
            md += "\n"
        }
        md += "## 双语文字记录\n"
        for l in session.lines {
            md += "- **[\(Self.clock(l.timestamp))] \(l.speaker)**: \(l.sourceText)\n  - \(l.translatedText)\n"
        }
        return md
    }

    static func clock(_ t: TimeInterval) -> String {
        let s = max(0, Int(t))
        return String(format: "%02d:%02d", s / 60, s % 60)
    }

    private static var interruptionRegistered = false

    func installInterruptionObserver() {
        guard !Self.interruptionRegistered else { return }
        Self.interruptionRegistered = true
        NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let self else { return }
            let typeVal = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            if typeVal == AVAudioSession.InterruptionType.ended.rawValue {
                Task { @MainActor in
                    if self.isListening {
                        try? AVAudioSession.sharedInstance().setActive(true)
                        self.startListening()
                    }
                }
            }
        }
    }

    func toggleReplayKitAudioCapture() {
        let recorder = RPScreenRecorder.shared()
        if replayKitActive {
            recorder.stopCapture { [weak self] _ in
                Task { @MainActor in self?.replayKitActive = false }
            }
            return
        }
        recorder.isMicrophoneEnabled = true
        recorder.startCapture(handler: { _, _, _ in
        }, completionHandler: { [weak self] error in
            Task { @MainActor in
                self?.replayKitActive = (error == nil)
                if error == nil && !(self?.isListening ?? false) {
                    self?.startListening()
                }
            }
        })
    }
}
