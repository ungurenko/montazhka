@preconcurrency import AVFoundation
import CoreVideo
import Foundation

/// Звук у склейки. `clickRatio` — во сколько раз самый резкий перепад у склейки
/// больше обычного для этого куска; `dropoutMS` — длина провала в тишину (0 — нет);
/// `levelJumpDB` — громкость до склейки минус громкость после (со знаком).
struct SeamAudioFinding: Equatable, Sendable {
    let clickRatio: Double
    let click: Bool
    let dropoutMS: Double
    let levelJumpDB: Double
}

/// Слова у склейки: что должно звучать по ленте и что слышно в готовом файле
/// (нормализованные слова). `suspect` — пропало слово у самой склейки.
struct SeamWordFinding: Equatable, Sendable {
    let expected: [String]
    let heard: [String]
    let missing: [String]
    let suspect: Bool
}

/// Слово с временем в секундах готового файла.
struct SeamWord: Equatable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

enum SeamProbeError: LocalizedError {
    case noAudio
    case noVideo
    case unreadable
    case noFrame(Double)

    var errorDescription: String? {
        switch self {
        case .noAudio: "В файле нет звуковой дорожки."
        case .noVideo: "В файле нет видеодорожки."
        case .unreadable: "Не удалось прочитать файл."
        case .noFrame(let time): "Не удалось прочитать кадр на \(String(format: "%.2f", time)) с."
        }
    }
}

/// Проверка склеек в готовом файле: щелчок, провал звука, скачок громкости,
/// чёрный кадр, пропавшее слово. Всё это подсказки агенту, а не приговор:
/// пороги стартовые и подбираются на реальных экспортах.
enum SeamProbe {
    /// Сколько секунд файла смотреть по каждую сторону склейки.
    static let window = 1.5

    /// Щелчок: самый резкий перепад в ±5 мс от склейки…
    static let clickHalfSpan = 0.005
    /// …больше 99-го процентиля перепадов окна во столько раз.
    static let clickRatioThreshold = 4.0
    /// Перепады тише ≈ −80 dBFS не слышны. Это пол для процентиля: в цифровой
    /// тишине он нулевой, и без пола отношение стало бы бесконечным.
    static let clickFloor = 1e-4

    /// Провал: RMS окнами по 5 мс с шагом 1 мс…
    static let dropoutFrame = 0.005
    static let dropoutHop = 0.001
    /// …ищем в ±150 мс от склейки самый длинный тихий участок…
    static let dropoutZone = 0.150
    /// …не короче 20 мс и тише −45 dBFS…
    static let dropoutMinLength = 0.020
    static let dropoutQuietDB = -45.0
    /// …с резкими краями: 5 мс прямо перед ним и 5 мс прямо после громче −30 dBFS.
    /// Дыра в сплошном звуке обрывает его за доли миллисекунды, а обычная пауза между
    /// словами (в ней стоит почти каждая склейка) начинается с затухания и кончается
    /// нарастанием — такие края тише порога, и пауза провалом не считается.
    static let dropoutEdge = 0.005
    static let dropoutLoudDB = -30.0

    /// Скачок громкости: RMS 300 мс до склейки минус 300 мс после.
    static let levelSpan = 0.300
    /// Цифровая тишина считается как −100 dBFS, а не минус бесконечность.
    static let silenceDB = -100.0

    /// Чёрный кадр: средняя яркость ниже 0.03. Тёмная сцена может честно лежать
    /// рядом с порогом — агент видит это как подсказку и смотрит кадр сам.
    static let blackLuma = 0.03
    /// Ширина миниатюры, по которой считается яркость.
    static let lumaWidth = 64

    /// Пропавшее слово «у склейки»: кончилось не раньше чем за 0.2 с до неё
    /// или началось не позже чем через 0.2 с после.
    static let wordTouch = 0.2

    /// Частота, в которой `samples(url:)` отдаёт звук.
    static let readSampleRate = 48_000.0

    // MARK: - Звук

    /// `samples` — моно-звук окна, `cutOffset` — секунды от начала окна до склейки.
    static func audio(samples: [Float], sampleRate: Double, cutOffset: Double) -> SeamAudioFinding {
        guard samples.count > 1, sampleRate > 0 else {
            return SeamAudioFinding(clickRatio: 0, click: false, dropoutMS: 0, levelJumpDB: 0)
        }
        let cut = min(max(Int((cutOffset * sampleRate).rounded()), 0), samples.count)
        let ratio = clickRatio(samples, sampleRate: sampleRate, cut: cut)
        return SeamAudioFinding(
            clickRatio: ratio, click: ratio >= clickRatioThreshold,
            dropoutMS: dropoutMS(samples, sampleRate: sampleRate, cut: cut),
            levelJumpDB: levelJumpDB(samples, sampleRate: sampleRate, cut: cut))
    }

    private static func clickRatio(_ samples: [Float], sampleRate: Double, cut: Int) -> Double {
        // steps[n - 1] = |x[n] − x[n − 1]|
        let steps = (1..<samples.count).map { abs(samples[$0] - samples[$0 - 1]) }
        let half = Int((clickHalfSpan * sampleRate).rounded())
        let lower = max(1, cut - half)
        let upper = min(samples.count - 1, cut + half)
        guard lower <= upper else { return 0 }
        let local = Double((lower...upper).map { steps[$0 - 1] }.max() ?? 0)
        let sorted = steps.sorted()
        let p99 = Double(sorted[Int((Double(sorted.count - 1) * 0.99).rounded())])
        return local / max(p99, clickFloor)
    }

    private static func dropoutMS(_ samples: [Float], sampleRate: Double, cut: Int) -> Double {
        let frame = max(1, Int((dropoutFrame * sampleRate).rounded()))
        let hop = max(1, Int((dropoutHop * sampleRate).rounded()))
        let zone = Int((dropoutZone * sampleRate).rounded())
        let edge = max(1, Int((dropoutEdge * sampleRate).rounded()))
        let zoneStart = max(0, cut - zone)
        let zoneEnd = min(samples.count, cut + zone)
        guard zoneEnd - zoneStart >= frame else { return 0 }

        // Тихий участок [start, end) в зоне засчитывается, только если звук громкий
        // вплотную к обоим его краям. Край за пределами окна подтвердить нечем — не провал.
        func abrupt(_ start: Int, _ end: Int) -> Bool {
            start - edge >= 0 && end + edge <= samples.count
                && rmsDB(samples, (start - edge)..<start) > dropoutLoudDB
                && rmsDB(samples, end..<(end + edge)) > dropoutLoudDB
        }
        var longest = 0
        var run: (start: Int, end: Int)?
        func close() {
            if let quiet = run, quiet.end - quiet.start > longest, abrupt(quiet.start, quiet.end) {
                longest = quiet.end - quiet.start
            }
            run = nil
        }
        for start in stride(from: zoneStart, through: zoneEnd - frame, by: hop) {
            if rmsDB(samples, start..<(start + frame)) < dropoutQuietDB {
                run = (run?.start ?? start, start + frame)
            } else {
                close()
            }
        }
        close()
        let length = Double(longest) / sampleRate
        return length >= dropoutMinLength - 1e-9 ? (length * 1000).rounded() : 0
    }

    private static func levelJumpDB(_ samples: [Float], sampleRate: Double, cut: Int) -> Double {
        let span = Int((levelSpan * sampleRate).rounded())
        let before = max(0, cut - span)..<cut
        let after = cut..<min(samples.count, cut + span)
        guard !before.isEmpty, !after.isEmpty else { return 0 }
        return rmsDB(samples, before) - rmsDB(samples, after)
    }

    /// RMS участка в dBFS; пустой участок — тишина.
    private static func rmsDB(_ samples: [Float], _ range: Range<Int>) -> Double {
        guard !range.isEmpty else { return silenceDB }
        var sum = 0.0
        for index in range { sum += Double(samples[index]) * Double(samples[index]) }
        let rms = (sum / Double(range.count)).squareRoot()
        return max(silenceDB, 20 * log10(max(rms, 1e-12)))
    }

    // MARK: - Слова

    /// Выравнивание слов ленты и повторной расшифровки (правило совпадения как у дублей:
    /// целиком или общее начало от 4 букв). `missing` — слова ленты без пары.
    static func words(expected: [SeamWord], heard: [SeamWord], cut: Double) -> SeamWordFinding {
        let expectedWords = expected.compactMap(normalized)
        let heardWords = heard.compactMap(normalized)
        let expectedTokens = expectedWords.map(\.text)
        let heardTokens = heardWords.map(\.text)
        let matched = Set(RetakeFinder.alignment(expectedTokens, heardTokens).map(\.0))
        let missing = expectedWords.indices.filter { !matched.contains($0) }
        return SeamWordFinding(
            expected: expectedTokens, heard: heardTokens,
            missing: missing.map { expectedTokens[$0] },
            suspect: missing.contains { touches(expectedWords[$0], cut: cut) })
    }

    private static func normalized(_ word: SeamWord) -> SeamWord? {
        let text = TranscriptSearch.normalize(word.text)
        return text.isEmpty ? nil : SeamWord(text: text, start: word.start, end: word.end)
    }

    private static func touches(_ word: SeamWord, cut: Double) -> Bool {
        if word.end <= cut { return cut - word.end <= wordTouch }
        if word.start >= cut { return word.start - cut <= wordTouch }
        return true  // слово перекрывает склейку
    }

    // MARK: - Картинка

    static func isBlack(meanLuma: Double) -> Bool {
        meanLuma < blackLuma
    }

    /// Средняя яркость (0…1, Rec. 709) кадров в моменты `times`, по миниатюре шириной
    /// `lumaWidth` точек. Кадр читается `AVAssetReaderTrackOutput` из первой видеодорожки
    /// готового файла: AVAssetImageGenerator с композициями отдаёт на роликах с iPhone
    /// (HEVC, 60 к/с) чёрные кадры, а чтение показывает ровно то, что лежит в файле.
    static func meanLuma(asset: AVAsset, times: [Double]) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SeamProbeError.noVideo
        }
        return try times.map { try frameLuma(asset: asset, track: track, at: $0) }
    }

    private static func frameLuma(asset: AVAsset, track: AVAssetTrack, at time: Double) throws -> Double {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SeamProbeError.unreadable }
        reader.add(output)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, time), preferredTimescale: 600), duration: CMTime(value: 1, timescale: 5))
        guard reader.startReading() else { throw SeamProbeError.unreadable }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), let image = CMSampleBufferGetImageBuffer(sample),
            let luma = luma(of: image)
        else { throw SeamProbeError.noFrame(time) }
        return luma
    }

    /// Средняя яркость BGRA-кадра по сетке `lumaWidth` × (пропорциональная высота) точек.
    private static func luma(of buffer: CVPixelBuffer) -> Double? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0, CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA,
            let base = CVPixelBufferGetBaseAddress(buffer)
        else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = base.assumingMemoryBound(to: UInt8.self)
        let columns = min(lumaWidth, width)
        let rows = max(1, Int((Double(height) * Double(columns) / Double(width)).rounded()))
        var total = 0.0
        for row in 0..<rows {
            let y = min(height - 1, Int((Double(row) + 0.5) * Double(height) / Double(rows)))
            for column in 0..<columns {
                let x = min(width - 1, Int((Double(column) + 0.5) * Double(width) / Double(columns)))
                let pixel = pixels + y * bytesPerRow + x * 4
                total += 0.0722 * Double(pixel[0]) + 0.7152 * Double(pixel[1]) + 0.2126 * Double(pixel[2])
            }
        }
        return total / Double(rows * columns) / 255
    }

    // MARK: - Чтение звука

    /// Моно Float32 48 кГц на отрезке `from…to` секунд файла, выровненный по времени файла.
    /// Первый буфер может начаться не ровно на `from` (у AAC есть «разгон» кодера ~2112
    /// сэмплов), поэтому сдвиг берётся из его метки времени: лишнее отрезается, недостающее
    /// (до начала файла) заполняется тишиной. Если файл кончается раньше `to`, звука меньше.
    static func samples(url: URL, from: Double, to: Double) async throws -> (samples: [Float], sampleRate: Double) {
        let wanted = Int(((to - from) * readSampleRate).rounded())
        guard wanted > 0 else { return ([], readSampleRate) }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw SeamProbeError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: readSampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
            ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SeamProbeError.unreadable }
        reader.add(output)
        let scale = CMTimeScale(readSampleRate)
        reader.timeRange = CMTimeRange(
            start: CMTime(seconds: max(0, from), preferredTimescale: scale),
            end: CMTime(seconds: to, preferredTimescale: scale))
        guard reader.startReading() else { throw SeamProbeError.unreadable }
        defer { reader.cancelReading() }

        var result: [Float] = []
        result.reserveCapacity(wanted)
        var skip: Int?
        while result.count < wanted, let sample = output.copyNextSampleBuffer() {
            var chunk = floats(sample)
            if skip == nil {
                let pts = CMSampleBufferGetPresentationTimeStamp(sample)
                let shift = pts.isNumeric ? Int(((pts.seconds - from) * readSampleRate).rounded()) : 0
                result.append(contentsOf: repeatElement(0, count: min(max(shift, 0), wanted)))
                skip = max(-shift, 0)
            }
            let dropped = min(skip ?? 0, chunk.count)
            chunk.removeFirst(dropped)
            skip = (skip ?? 0) - dropped
            result.append(contentsOf: chunk)
        }
        if reader.status == .failed { throw reader.error ?? SeamProbeError.unreadable }
        return (Array(result.prefix(wanted)), readSampleRate)
    }

    private static func floats(_ sample: CMSampleBuffer) -> [Float] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let length = CMBlockBufferGetDataLength(block)
        var values = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
        guard !values.isEmpty else { return [] }
        let status = values.withUnsafeMutableBytes {
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: $0.count, destination: $0.baseAddress!)
        }
        return status == kCMBlockBufferNoErr ? values : []
    }
}
