import Foundation
import Combine

@MainActor
final class GenAIClient: ObservableObject {
    enum RouteMode: String, CaseIterable {
        case autoVPN = "auto"
        case directFloodgate = "floodgate"
        case macBridge = "mac"
        case antLing = "ling"
    }

    @Published var routeMode: RouteMode {
        didSet { UserDefaults.standard.set(routeMode.rawValue, forKey: "routeMode") }
    }
    @Published var aiModel: String {
        didSet { UserDefaults.standard.set(aiModel, forKey: "aiModel") }
    }
    @Published var macBridgeURL: String {
        didSet { UserDefaults.standard.set(Self.normalizeBridgeURL(macBridgeURL), forKey: "macBridgeURL") }
    }
    @Published var floodgateToken: String {
        didSet { UserDefaults.standard.set(floodgateToken, forKey: "floodgateToken") }
    }
    @Published var lingKey: String {
        didSet { UserDefaults.standard.set(lingKey, forKey: "lingKey") }
    }
    @Published var connectionStatus: String = "准备就绪 · Apple VPN Floodgate"
    @Published var activeRouteLabel: String = "Floodgate Direct"
    @Published var lastLatencyMs: Int?

    static let models = ["gemini-3.8-flash", "gemini-3.7-flash", "Ling-3.1-flash"]
    static let quickHosts = [
        ("17.87.15.76", "http://17.87.15.76:11213"),
        ("Mac.local", "http://xis-MacBook-Pro.local:11213"),
        ("10.0.1.66", "http://10.0.1.66:11213"),
        ("192.168.1.1", "http://192.168.1.1:11213")
    ]

    private static let embeddedFloodgateToken = ""
    private static let embeddedLingKey = ""

    init() {
        let rawMode = UserDefaults.standard.string(forKey: "routeMode") ?? "auto"
        self.routeMode = RouteMode(rawValue: rawMode) ?? .autoVPN
        self.aiModel = UserDefaults.standard.string(forKey: "aiModel") ?? "gemini-3.8-flash"
        self.macBridgeURL = UserDefaults.standard.string(forKey: "macBridgeURL") ?? "http://17.87.15.76:11213"
        let savedFG = UserDefaults.standard.string(forKey: "floodgateToken") ?? ""
        self.floodgateToken = savedFG.isEmpty ? Self.embeddedFloodgateToken : savedFG
        let savedLing = UserDefaults.standard.string(forKey: "lingKey") ?? ""
        self.lingKey = savedLing.isEmpty ? Self.embeddedLingKey : savedLing
        Task { await refreshFloodgateTokenAndProbe() }
    }

    static func normalizeBridgeURL(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.isEmpty { return "http://17.87.15.76:11213" }
        if !s.lowercased().hasPrefix("http://") && !s.lowercased().hasPrefix("https://") {
            s = "http://" + s
        }
        if s.hasSuffix("/") { s.removeLast() }
        if let url = URL(string: s), url.port == nil && !(url.host ?? "").contains("apple.com") {
            s += ":11213"
        }
        return s
    }

    func refreshFloodgateTokenAndProbe() async {
        let started = Date()
        let bridge = Self.normalizeBridgeURL(macBridgeURL)
        if let url = URL(string: bridge + "/api/floodgate-token") {
            var req = URLRequest(url: url)
            req.timeoutInterval = 2.5
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse)?.statusCode == 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let tok = obj["token"] as? String, !tok.isEmpty {
                self.floodgateToken = tok
            }
        }
        if await testDirectFloodgate() {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lastLatencyMs = ms
            activeRouteLabel = "Apple VPN · Floodgate 直连"
            connectionStatus = "已直连 floodgate.g.apple.com (\(ms)ms)"
            return
        }
        if await testMacBridge() {
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            lastLatencyMs = ms
            activeRouteLabel = "Apple VPN / LAN · Mac 桥接"
            connectionStatus = "已连接 Mac GenAI 桥接 (\(ms)ms)"
            return
        }
        activeRouteLabel = "云端备用 · Ling / Google"
        connectionStatus = "未检测到 Apple VPN，已启用云端备用通道"
    }

    private func testDirectFloodgate() async -> Bool {
        guard !floodgateToken.isEmpty,
              let url = URL(string: "https://floodgate.g.apple.com/api/gemini/v1/publishers/google/models/gemini-3.8-flash:generateContent") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("Bearer \(floodgateToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": "hi"]]]],
            "generationConfig": ["maxOutputTokens": 1, "thinkingConfig": ["thinkingBudget": 0]]
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }

    private func testMacBridge() async -> Bool {
        let bridge = Self.normalizeBridgeURL(macBridgeURL)
        guard let url = URL(string: bridge + "/api/openai/v1/models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 3
        guard let (_, resp) = try? await URLSession.shared.data(for: req) else { return false }
        return (resp as? HTTPURLResponse)?.statusCode == 200
    }
}

extension GenAIClient {
    func chat(system: String, instruction: String, json: Bool = false, audioWAV: Data? = nil, maxTokens: Int = 1024) async -> String? {
        let started = Date()
        let gemModel = aiModel.hasPrefix("Ling-") ? "gemini-3.8-flash" : aiModel
        var userParts: [[String: Any]] = []
        if let wav = audioWAV {
            userParts.append(["inlineData": ["mimeType": "audio/wav", "data": wav.base64EncodedString()]])
        }
        userParts.append(["text": instruction])
        var genConfig: [String: Any] = [
            "temperature": 0.2,
            "maxOutputTokens": maxTokens,
            "thinkingConfig": ["thinkingBudget": 0]
        ]
        if json { genConfig["responseMimeType"] = "application/json" }
        let gemBody: [String: Any] = [
            "systemInstruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": userParts]],
            "generationConfig": genConfig
        ]

        // 1. Direct Floodgate over Apple VPN
        if routeMode == .autoVPN || routeMode == .directFloodgate {
            let fgURL = "https://floodgate.g.apple.com/api/gemini/v1/publishers/google/models/\(gemModel):generateContent"
            if let reply = await callGemini(urlStr: fgURL, body: gemBody, bearer: floodgateToken, json: json) {
                lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                activeRouteLabel = "Apple VPN · Floodgate 直连"
                return reply
            }
        }

        // 2. Mac Bridge over Apple VPN / LAN (also refreshes token)
        if routeMode == .autoVPN || routeMode == .macBridge {
            let bridge = Self.normalizeBridgeURL(macBridgeURL)
            let macURL = "\(bridge)/api/gemini/v1beta/models/\(gemModel):generateContent"
            if let reply = await callGemini(urlStr: macURL, body: gemBody, bearer: nil, json: json) {
                lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                activeRouteLabel = "Apple VPN / LAN · Mac 桥接"
                return reply
            }
        }

        // 3. Ant Ling Fallback (works without VPN)
        if !lingKey.isEmpty {
            if let reply = await callLing(system: system, instruction: instruction, json: json, audioWAV: audioWAV, maxTokens: maxTokens) {
                lastLatencyMs = Int(Date().timeIntervalSince(started) * 1000)
                activeRouteLabel = "云端 · Ling 3.1 Flash"
                return reply
            }
        }
        return nil
    }

    private func callGemini(urlStr: String, body: [String: Any], bearer: String?, json: Bool) async -> String? {
        guard let url = URL(string: urlStr) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 18
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let bearer, !bearer.isEmpty {
            req.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cands = root["candidates"] as? [[String: Any]],
              let content = cands.first?["content"] as? [String: Any],
              let parts = content["parts"] as? [[String: Any]] else { return nil }
        let raw = parts.compactMap { p -> String? in
            if (p["thought"] as? Bool) == true { return nil }
            return p["text"] as? String
        }.joined()
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if json, trimmed.hasPrefix("```") {
            if let nl = trimmed.firstIndex(of: "\n") { trimmed = String(trimmed[trimmed.index(after: nl)...]) }
            if trimmed.hasSuffix("```") { trimmed = String(trimmed.dropLast(3)).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    private func callLing(system: String, instruction: String, json: Bool, audioWAV: Data?, maxTokens: Int) async -> String? {
        guard let url = URL(string: "https://api.ant-ling.com/v1/chat/completions") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 18
        req.setValue("Bearer \(lingKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let modelName = audioWAV != nil ? "Ming-3.0-audio-flash" : "Ling-3.1-flash"
        var body: [String: Any] = [
            "model": modelName,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": audioWAV.map { wav -> Any in
                    [["type": "audio_url", "audio_url": ["url": "data:audio/wav;base64," + wav.base64EncodedString()]],
                     ["type": "text", "text": instruction]]
                } ?? instruction]
            ],
            "max_tokens": maxTokens,
            "temperature": 0.2,
            "thinking": ["type": "disabled"]
        ]
        if json { body["response_format"] = ["type": "json_object"] }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let msg = choices.first?["message"] as? [String: Any],
              let text = msg["content"] as? String else { return nil }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func translate(_ text: String, from: String, to: String, glossary: [String] = []) async -> String {
        guard !text.isEmpty, from != to else { return text }
        let targetLang = supportedLanguages.first { $0.id == to }?.englishName ?? to
        var sys = "You are a simultaneous conference interpreter. Translate the subtitle naturally into \(targetLang). Output ONLY the translation."
        if !glossary.isEmpty { sys += "\nGlossary: " + glossary.joined(separator: "; ") }
        sys += "\nSubtitle: " + text
        if let out = await chat(system: sys, instruction: "Translate.", maxTokens: 300), !out.isEmpty {
            return out
        }
        return await googleTranslateFallback(text, to: to) ?? text
    }

    private func googleTranslateFallback(_ text: String, to: String) async -> String? {
        var comps = URLComponents(string: "https://translate.googleapis.com/translate_a/single")!
        comps.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: to),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: text)
        ]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let lines = arr.first as? [[Any]] else { return nil }
        return lines.compactMap { $0.first as? String }.joined()
    }

    func synthesizeWAV(_ text: String, voiceName: String = "Kore") async -> Data? {
        let body: [String: Any] = [
            "contents": [["role": "user", "parts": [["text": text]]]],
            "generationConfig": [
                "responseModalities": ["AUDIO"],
                "speechConfig": ["voiceConfig": ["prebuiltVoiceConfig": ["voiceName": voiceName]]]
            ]
        ]
        let endpoints: [(String, String?)] = [
            ("https://floodgate.g.apple.com/api/gemini/v1/publishers/google/models/gemini-3.8-flash-lite-tts:generateContent", floodgateToken),
            ("\(Self.normalizeBridgeURL(macBridgeURL))/api/gemini/v1beta/models/gemini-3.8-flash-lite-tts:generateContent", nil)
        ]
        for (u, tok) in endpoints {
            guard let url = URL(string: u) else { continue }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.timeoutInterval = 12
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let tok, !tok.isEmpty { req.setValue("Bearer \(tok)", forHTTPHeaderField: "Authorization") }
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse)?.statusCode == 200,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let cands = root["candidates"] as? [[String: Any]],
                  let content = cands.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]],
                  let inline = parts.first?["inlineData"] as? [String: Any],
                  let b64 = inline["data"] as? String,
                  let raw = Data(base64Encoded: b64), !raw.isEmpty else { continue }
            return raw
        }
        return nil
    }
}
