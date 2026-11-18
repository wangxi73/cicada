import Accelerate
import CoreML
import Foundation

enum Fbank {
    static let bins = 80
    static let frameLength = 400
    static let shift = 160
    private static let fftSize = 512

    private static let window: [Float] = (0..<frameLength).map {
        pow(0.5 - 0.5 * cos(2 * Float.pi * Float($0) / Float(frameLength - 1)), 0.85)
    }

    private static let melBanks: [Float] = {
        func mel(_ f: Double) -> Double { 1127 * log(1 + f / 700) }
        let cols = fftSize / 2 + 1
        let lo = mel(20), hi = mel(8000), delta = (hi - lo) / Double(bins + 1)
        var w = [Float](repeating: 0, count: bins * cols)
        for m in 0..<bins {
            let left = lo + Double(m) * delta, center = left + delta, right = center + delta
            for k in 0..<(fftSize / 2) {
                let x = mel(Double(k) * 16000 / Double(fftSize))
                let v = min((x - left) / (center - left), (right - x) / (right - center))
                if v > 0 { w[m * cols + k] = Float(v) }
            }
        }
        return w
    }()

    private static let setup = vDSP_create_fftsetup(9, FFTRadix(kFFTRadix2))!

    static func compute(_ samples: [Float]) -> [Float] {
        guard samples.count >= frameLength else { return [] }
        let frames = 1 + (samples.count - frameLength) / shift
        let cols = fftSize / 2 + 1
        var out = [Float](repeating: 0, count: frames * bins)
        var frame = [Float](repeating: 0, count: fftSize)
        var re = [Float](repeating: 0, count: fftSize / 2), im = re
        var power = [Float](repeating: 0, count: cols)
        var mels = [Float](repeating: 0, count: bins)
        for f in 0..<frames {
            let start = f * shift
            for i in 0..<frameLength { frame[i] = samples[start + i] * 32768 }
            for i in frameLength..<fftSize { frame[i] = 0 }
            var mean: Float = 0
            vDSP_meanv(frame, 1, &mean, vDSP_Length(frameLength))
            for i in 0..<frameLength { frame[i] -= mean }
            for i in stride(from: frameLength - 1, to: 0, by: -1) { frame[i] -= 0.97 * frame[i - 1] }
            frame[0] -= 0.97 * frame[0]
            vDSP_vmul(frame, 1, window, 1, &frame, 1, vDSP_Length(frameLength))
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBytes { raw in
                        vDSP_ctoz(raw.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(fftSize / 2))
                    }
                    vDSP_fft_zrip(setup, &split, 1, 9, FFTDirection(FFT_FORWARD))
                }
            }
            power[0] = re[0] * re[0] / 4
            power[cols - 1] = im[0] * im[0] / 4
            for k in 1..<(fftSize / 2) { power[k] = (re[k] * re[k] + im[k] * im[k]) / 4 }
            vDSP_mmul(melBanks, 1, power, 1, &mels, 1, vDSP_Length(bins), 1, vDSP_Length(cols))
            for b in 0..<bins { out[f * bins + b] = log(max(mels[b], .ulpOfOne)) }
        }
        return out
    }
}

final class MobileVoiceprints: @unchecked Sendable {
    static let minSeconds = 0.5
    static let maxSeconds = 20.0
    private let model: MLModel

    private init(model: MLModel) { self.model = model }

    static func load() throws -> MobileVoiceprints {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU
        if let compiledURL = Bundle.main.url(forResource: "SpeakerEmbedding", withExtension: "mlmodelc") {
            return MobileVoiceprints(model: try MLModel(contentsOf: compiledURL, configuration: config))
        }
        guard let pkg = Bundle.main.url(forResource: "SpeakerEmbedding", withExtension: "mlpackage") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let compiled = try MLModel.compileModel(at: pkg)
        return MobileVoiceprints(model: try MLModel(contentsOf: compiled, configuration: config))
    }

    func embed(_ samples: [Float]) -> [Float]? {
        guard Double(samples.count) >= Self.minSeconds * 16000 else { return nil }
        let clip = samples.count > Int(Self.maxSeconds * 16000) ? Array(samples.prefix(Int(Self.maxSeconds * 16000))) : samples
        var feats = Fbank.compute(clip)
        let frames = feats.count / Fbank.bins
        guard frames >= 50 else { return nil }
        for b in 0..<Fbank.bins {
            var sum: Float = 0
            for f in 0..<frames { sum += feats[f * Fbank.bins + b] }
            let mean = sum / Float(frames)
            for f in 0..<frames { feats[f * Fbank.bins + b] -= mean }
        }
        guard let input = try? MLMultiArray(shape: [1, NSNumber(value: frames), NSNumber(value: Fbank.bins)], dataType: .float32) else { return nil }
        feats.withUnsafeBufferPointer { src in
            input.withUnsafeMutableBytes { dst, _ in
                dst.copyMemory(from: UnsafeRawBufferPointer(src))
            }
        }
        guard let out = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["feats": input])),
              let embs = out.featureValue(for: "embs")?.multiArrayValue else { return nil }
        var v = (0..<embs.count).map { Float(truncating: embs[$0]) }
        var norm: Float = 0
        vDSP_svesq(v, 1, &norm, vDSP_Length(v.count))
        guard norm > 0 else { return nil }
        vDSP_vsdiv(v, 1, [norm.squareRoot()], &v, 1, vDSP_Length(v.count))
        return v
    }
}

struct MobileVoiceClusterer {
    static let newSeconds = 1.2
    static let join: Float = 0.50
    static let startNew: Float = 0.50
    private(set) var sums: [[Float]] = []
    private(set) var counts: [Int] = []

    mutating func reset() {
        sums.removeAll()
        counts.removeAll()
    }

    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return -1 }
        var dot: Float = 0, sqA: Float = 0, sqB: Float = 0
        vDSP_dotpr(a, 1, b, 1, &dot, vDSP_Length(a.count))
        vDSP_svesq(a, 1, &sqA, vDSP_Length(a.count))
        vDSP_svesq(b, 1, &sqB, vDSP_Length(b.count))
        return dot / max(sqA.squareRoot() * sqB.squareRoot(), .ulpOfOne)
    }

    mutating func label(_ v: [Float], seconds: Double) -> Int? {
        var best = -1, bestSim: Float = -1
        for (i, s) in sums.enumerated() {
            let sim = Self.cosine(v, s)
            if sim > bestSim { bestSim = sim; best = i }
        }
        if best >= 0, bestSim >= Self.join {
            vDSP_vadd(sums[best], 1, v, 1, &sums[best], 1, vDSP_Length(v.count))
            counts[best] += 1
            return best + 1
        }
        if seconds >= Self.newSeconds, sums.isEmpty || bestSim < Self.startNew {
            sums.append(v)
            counts.append(1)
            return sums.count
        }
        return best >= 0 ? (best + 1) : nil
    }

    func centroid(forSpeaker num: Int) -> [Float]? {
        let idx = num - 1
        guard idx >= 0, idx < sums.count else { return nil }
        var out = sums[idx]
        var sq: Float = 0
        vDSP_svesq(out, 1, &sq, vDSP_Length(out.count))
        guard sq > 0 else { return nil }
        vDSP_vsdiv(out, 1, [sq.squareRoot()], &out, 1, vDSP_Length(out.count))
        return out
    }
}

@MainActor
final class MobileSpeakerTagger {
    private let queue = DispatchQueue(label: "com.xiwang.cicada.ios.voiceprint", qos: .utility)
    private nonisolated(unsafe) var model: MobileVoiceprints?
    private nonisolated(unsafe) var loadFailed = false
    private nonisolated(unsafe) var clusterer = MobileVoiceClusterer()
    private nonisolated(unsafe) var savedProfiles: [SpeakerProfileItem] = []
    private nonisolated(unsafe) var matchedNameBySpeaker: [Int: String] = [:]

    func reset() {
        queue.async { [self] in
            clusterer.reset()
            matchedNameBySpeaker.removeAll()
        }
    }

    func setSavedProfiles(_ profiles: [SpeakerProfileItem]) {
        queue.async { [self] in savedProfiles = profiles }
    }

    func centroid(for label: String, completion: @escaping @MainActor ([Float]?) -> Void) {
        let num = Int(label.replacingOccurrences(of: "说话人 ", with: "")) ?? -1
        queue.async { [self] in
            let c = clusterer.centroid(forSpeaker: num)
            Task { @MainActor in completion(c) }
        }
    }

    func identify(samples16k: [Int16], completion: @escaping @MainActor (String) -> Void) {
        let floats = samples16k.map { Float($0) / 32768.0 }
        let seconds = Double(floats.count) / 16000.0
        queue.async { [self] in
            if model == nil, !loadFailed {
                do { model = try MobileVoiceprints.load() } catch { loadFailed = true }
            }
            guard let v = model?.embed(floats),
                  let speakerNum = clusterer.label(v, seconds: seconds) else {
                Task { @MainActor in completion("会场") }
                return
            }
            if matchedNameBySpeaker[speakerNum] == nil, !savedProfiles.isEmpty {
                var bestName: String?
                var bestSim: Float = 0.62
                for p in savedProfiles {
                    let sim = MobileVoiceClusterer.cosine(v, p.centroid)
                    if sim > bestSim {
                        bestSim = sim
                        bestName = p.name
                    }
                }
                if let bestName { matchedNameBySpeaker[speakerNum] = bestName }
            }
            let resolved = matchedNameBySpeaker[speakerNum] ?? "说话人 \(speakerNum)"
            Task { @MainActor in
                completion(resolved)
            }
        }
    }
}
