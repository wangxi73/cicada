import Foundation
import SwiftUI

enum CicadaPalette {
    static let ink = Color(red: 0.08, green: 0.09, blue: 0.11)
    static let ground = Color(red: 0.953, green: 0.957, blue: 0.965)
    static let line = Color(red: 0.894, green: 0.902, blue: 0.918)
    static let secondary = Color(red: 0.353, green: 0.373, blue: 0.42)
    static let tertiary = Color(red: 0.42, green: 0.44, blue: 0.50)
    static let accent = Color(red: 0.91, green: 0.33, blue: 0.17)
    static let accentPale = Color(red: 0.99, green: 0.93, blue: 0.906)
    static let ok = Color(red: 0.122, green: 0.478, blue: 0.271)
    static let okPale = Color(red: 0.906, green: 0.961, blue: 0.925)
    static let raised = Color(red: 0.961, green: 0.965, blue: 0.973)
}

struct LangOption: Identifiable, Equatable {
    let id: String
    let name: String
    let locale: String
    let englishName: String
}

let supportedLanguages: [LangOption] = [
    LangOption(id: "en", name: "English", locale: "en-US", englishName: "English"),
    LangOption(id: "zh-CN", name: "简体中文", locale: "zh-CN", englishName: "Simplified Chinese"),
    LangOption(id: "ja", name: "日本語", locale: "ja-JP", englishName: "Japanese"),
    LangOption(id: "ko", name: "한국어", locale: "ko-KR", englishName: "Korean"),
    LangOption(id: "de", name: "Deutsch", locale: "de-DE", englishName: "German"),
    LangOption(id: "fr", name: "Français", locale: "fr-FR", englishName: "French"),
    LangOption(id: "es", name: "Español", locale: "es-ES", englishName: "Spanish"),
]

struct TranscriptLine: Identifiable, Codable, Equatable {
    var id: Int
    var timestamp: TimeInterval
    var speaker: String
    var sourceText: String
    var translatedText: String
    var isMe: Bool
    var fixes: [LineFixItem]? = nil

    var shownSourceText: String {
        guard let fixes, !fixes.isEmpty else { return sourceText }
        var out = sourceText
        for f in fixes where f.applied {
            if !f.from.isEmpty, out.contains(f.from) {
                out = out.replacingOccurrences(of: f.from, with: f.to)
            }
        }
        return out
    }
}

struct LineFixItem: Identifiable, Codable, Equatable {
    var id: String { "\(from)->\(to)" }
    var from: String
    var to: String
    var confidence: Double = 0.9
    var ask: Bool? = nil
    var off: Bool? = nil
    var user: Bool? = nil

    var applied: Bool { ask != true && off != true }
}

struct WordTermItem: Identifiable, Codable, Equatable {
    var id: String { word.lowercased() }
    var word: String
    var heard: [String] = []
    var addedAt: Date = Date()
    var usedCount: Int = 0
}

struct SpeakerProfileItem: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var centroid: [Float]
    var sampleCount: Int = 1
}

struct NoteTopicItem: Identifiable, Codable, Equatable {
    var id: String { title }
    var title: String
    var points: [String]
}

struct NoteConclusionItem: Identifiable, Codable, Equatable {
    var id: String { text }
    var text: String
    var lines: [Int]?
}

struct NoteTodoItem: Identifiable, Codable, Equatable {
    var id: String { text }
    var text: String
    var owner: String?
    var lines: [Int]?
}

struct NoteTermItem: Identifiable, Codable, Equatable {
    var id: String { name }
    var name: String
    var note: String?
}

struct MeetingNotesData: Codable, Equatable {
    var title: String = ""
    var summary: String = ""
    var topics: [NoteTopicItem] = []
    var conclusions: [NoteConclusionItem] = []
    var todos: [NoteTodoItem] = []
    var terms: [NoteTermItem] = []

    var isEmpty: Bool {
        summary.isEmpty && topics.isEmpty && conclusions.isEmpty && todos.isEmpty
    }
}

struct MeetingSession: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var startedAt: Date = Date()
    var endedAt: Date?
    var title: String = "新会议记录"
    var sourceLang: String = "en"
    var targetLang: String = "zh-CN"
    var lines: [TranscriptLine] = []
    var notes: MeetingNotesData = MeetingNotesData()
    var audioFilename: String? = nil
    var speakerNames: [String: String]? = nil

    func displaySpeaker(for line: TranscriptLine) -> String {
        if line.isMe { return line.speaker }
        return speakerNames?[line.speaker] ?? line.speaker
    }
}
