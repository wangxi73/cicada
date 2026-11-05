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

    private let audioEngine = AVAudioEngine()
    private var notesTimer: Timer?
    private var nextLineID = 1

    // Pure AVAudioEngine VAD buffer (16 kHz mono Int16) - never touches SFSpeechRecognizer / assistantd
    private var vadSamples: [Int16] = []
    private var vadVoicedFrames = 0
    private var vadSilenceFrames = 0
    private var holdSamples: [Int16] = []

    private var player: AVAudioPlayer?
    private let synth = AVSpeechSynthesizer()

    init() {
        loadHistory()
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
        startPureAudioTap()
        notesTimer?.invalidate()
        notesTimer = Timer.scheduledTimer(withTimeInterval: 35, repeats: true) { [weak self] _ in
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
        let srcEng = supportedLanguages.first { $0.id == src }?.englishName ?? src
        let dstEng = supportedLanguages.first { $0.id == dst }?.englishName ?? dst
        let glossary = currentSession.notes.terms.map(\.name)

        Task {
            var sys = "You are a live meeting transcriber and interpreter. Listen to the audio and transcribe what is spoken (primarily \(srcEng) or Chinese/English), then translate it into \(dstEng). If the audio is only silence or background noise, reply NONE."
            if !glossary.isEmpty { sys += "\nGlossary: " + glossary.joined(separator: "; ") }
            let inst = """
            If clear speech is heard, reply in exactly two lines:
            ORIGINAL: <exact transcription>
            TRANSLATION: <translation into \(dstEng)>
            If no speech or only noise, reply: NONE
            """
            if let reply = await genai.chat(system: sys, instruction: inst, json: false, audioWAV: wav, maxTokens: 500),
               let parsed = Self.parseTwoLines(reply) {
                if let idx = currentSession.lines.firstIndex(where: { $0.id == lineID }) {
                    currentSession.lines[idx].sourceText = parsed.0
                    currentSession.lines[idx].translatedText = parsed.1
                    saveCurrentSession()
                }
                if currentSession.lines.count == 2 || currentSession.lines.count % 5 == 0 {
                    updateNotesNow()
                }
            } else {
                currentSession.lines.removeAll { $0.id == lineID }
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
        if let wavData = await genai.synthesizeWAV(text, voiceName: ttsVoice) {
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
