import Speech
import AVFoundation
let path = CommandLine.arguments[1], loc = CommandLine.arguments[2]
let t = SpeechTranscriber(locale: Locale(identifier: loc), transcriptionOptions: [], reportingOptions: [], attributeOptions: [])
let f = try AVAudioFile(forReading: URL(fileURLWithPath: path))
print("file", f.processingFormat, Double(f.length)/f.processingFormat.sampleRate, "s")
let a = try await SpeechAnalyzer(inputAudioFile: f, modules: [t], finishAfterFile: true)
_ = a
var text = ""
for try await r in t.results { text += String(r.text.characters) }
print(loc, "=>", text)
