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
/// (нормализованные слова). `suspect` — пропало слово у самой склейки; `atCut` — эти слова
/// со временем ленты, чтобы проверить, звучат ли они в файле на самом деле.
struct SeamWordFinding: Equatable, Sendable {
    let expected: [String]
    let heard: [String]
    let missing: [String]
    let suspect: Bool
    var atCut: [SeamWord] = []
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

    /// Громкость речи у склейки сравнивается, только если с каждой стороны есть слово не дальше 0,3 с…
    static let levelWordReach = 0.3
    /// …и мерится по словам в пределах 1 с с каждой стороны…
    static let levelPhraseReach = 1.0
    /// …участок короче 20 мс не мерится: в нём только край слова.
    static let levelMinimumSpan = 0.020
    /// Без расшифровки речь — окна по 5 мс громче −40 dBFS…
    static let voicedFrameDB = -40.0
    /// …и её должно быть не меньше 100 мс в 300 мс с каждой стороны; меньше — там пауза.
    static let voicedMinimum = 0.100

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

    /// RMS участка `from…to` (секунды от начала окна) в dBFS; nil — участок короче
    /// `levelMinimumSpan` или вне окна.
    static func spanDB(samples: [Float], sampleRate: Double, from: Double, to: Double) -> Double? {
        let lower = max(0, Int((from * sampleRate).rounded()))
        let upper = min(samples.count, Int((to * sampleRate).rounded()))
        guard upper > lower, Double(upper - lower) >= levelMinimumSpan * sampleRate - 1e-9 else { return nil }
        return rmsDB(samples, lower..<upper)
    }

    /// RMS нескольких участков вместе (секунды от начала окна) в dBFS; nil — вместе они короче
    /// `levelMinimumSpan`. Пересекающиеся участки считаются один раз.
    static func spansDB(samples: [Float], sampleRate: Double, spans: [(from: Double, to: Double)]) -> Double? {
        var covered = [Bool](repeating: false, count: samples.count)
        for span in spans {
            let lower = max(0, Int((span.from * sampleRate).rounded()))
            let upper = min(samples.count, Int((span.to * sampleRate).rounded()))
            if upper > lower { for index in lower..<upper { covered[index] = true } }
        }
        var sum = 0.0
        var count = 0
        for index in samples.indices where covered[index] {
            sum += Double(samples[index]) * Double(samples[index])
            count += 1
        }
        guard count > 0, Double(count) >= levelMinimumSpan * sampleRate - 1e-9 else { return nil }
        return max(silenceDB, 20 * log10(max((sum / Double(count)).squareRoot(), 1e-12)))
    }

    /// Скачок громкости речи без расшифровки: громкость только «звучащих» окон по 5 мс
    /// (громче `voicedFrameDB`) в 300 мс до склейки минус такая же после. Пауза у склейки —
    /// обычное дело, поэтому если с одной стороны речи меньше `voicedMinimum`, сравнивать нечего: nil.
    static func voicedLevelJumpDB(samples: [Float], sampleRate: Double, cutOffset: Double) -> Double? {
        let frame = max(1, Int((dropoutFrame * sampleRate).rounded()))
        let span = Int((levelSpan * sampleRate).rounded())
        let cut = min(max(Int((cutOffset * sampleRate).rounded()), 0), samples.count)
        func voicedDB(_ range: Range<Int>) -> Double? {
            var power = 0.0
            var frames = 0
            for start in stride(from: range.lowerBound, through: range.upperBound - frame, by: frame) {
                let level = rmsDB(samples, start..<(start + frame))
                guard level > voicedFrameDB else { continue }
                power += pow(10, level / 10)
                frames += 1
            }
            guard frames > 0, Double(frames * frame) >= voicedMinimum * sampleRate - 1e-9 else { return nil }
            return 10 * log10(power / Double(frames))
        }
        guard let before = voicedDB(max(0, cut - span)..<cut),
            let after = voicedDB(cut..<min(samples.count, cut + span))
        else { return nil }
        return before - after
    }

    /// На сколько дБ участок слова `from…to` (секунды от начала окна) в готовом файле тише,
    /// чем в склейке проекта, с поправкой на громкость всего окна: экспорт выравнивает громкость
    /// и улучшает голос, а сравнивать нужно само слово. nil — участок не измерить.
    static func wordDeficitDB(
        file: [Float], source: [Float], sampleRate: Double, from: Double, to: Double
    ) -> Double? {
        let whole = Double(min(file.count, source.count)) / sampleRate
        guard let fileWord = spanDB(samples: file, sampleRate: sampleRate, from: from, to: to),
            let sourceWord = spanDB(samples: source, sampleRate: sampleRate, from: from, to: to),
            let fileWindow = spanDB(samples: file, sampleRate: sampleRate, from: 0, to: whole),
            let sourceWindow = spanDB(samples: source, sampleRate: sampleRate, from: 0, to: whole)
        else { return nil }
        return (sourceWord - sourceWindow) - (fileWord - fileWindow)
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
        let atCut = missing.map { expectedWords[$0] }.filter { touches($0, cut: cut) }
        return SeamWordFinding(
            expected: expectedTokens, heard: heardTokens,
            missing: missing.map { expectedTokens[$0] },
            suspect: !atCut.isEmpty, atCut: atCut)
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
        try await meanLuma(asset: asset, times: times, onReaderStart: {})
    }

    /// Локальный счётчик для повторяемых замеров; состояние читателей не разделяется между запросами.
    static func meanLuma(asset: AVAsset, times: [Double], onReaderStart: () -> Void) async throws -> [Double] {
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw SeamProbeError.noVideo
        }
        var result: [Double] = []
        var index = 0
        while index < times.count {
            if index + 1 < times.count, canReadPair(times[index], times[index + 1]) {
                let pair = try? autoreleasepool {
                    try pairedFrameLuma(
                        asset: asset, track: track, first: times[index], second: times[index + 1],
                        onReaderStart: onReaderStart)
                }
                if let pair {
                    result += pair
                } else {
                    // Неоднозначная метка или ошибка декодера: сохраняем прежние кадры и порядок ошибок.
                    for time in times[index...(index + 1)] {
                        result.append(
                            try autoreleasepool {
                                try frameLuma(asset: asset, track: track, at: time, onReaderStart: onReaderStart)
                            })
                    }
                }
                index += 2
            } else {
                result.append(
                    try autoreleasepool {
                        try frameLuma(asset: asset, track: track, at: times[index], onReaderStart: onReaderStart)
                    })
                index += 1
            }
        }
        return result
    }

    private static let frameReadWindow = CMTime(value: 1, timescale: 5)

    private static func frameTime(_ seconds: Double) -> CMTime {
        CMTime(seconds: max(0, seconds), preferredTimescale: 600)
    }

    private static func canReadPair(_ first: Double, _ second: Double) -> Bool {
        guard first.isFinite, second.isFinite, second >= first, second - first <= frameReadWindow.seconds else {
            return false
        }
        return CMTimeCompare(CMTimeSubtract(frameTime(second), frameTime(first)), frameReadWindow) <= 0
    }

    /// Храним только яркость предыдущего кадра: полноразмерные буферы пары не накапливаются.
    private static func pairedFrameLuma(
        asset: AVAsset, track: AVAssetTrack, first: Double, second: Double, onReaderStart: () -> Void
    ) throws -> [Double]? {
        let start = frameTime(first), target = frameTime(second)
        let range = CMTimeRange(start: start, duration: frameReadWindow)
        let (reader, output) = try frameReader(asset: asset, track: track, range: range, onReaderStart: onReaderStart)
        defer { reader.cancelReading() }
        guard let firstFrame = nextFrameLuma(output) else { return nil }
        let firstLuma = firstFrame.luma
        var previousTime = firstFrame.time
        guard previousTime.isNumeric, CMTimeCompare(previousTime, start) == 0 else { return nil }
        if CMTimeCompare(start, target) == 0 { return [firstLuma, firstLuma] }
        var previousLuma = firstLuma
        while let next = nextFrameLuma(output) {
            let time = next.time
            guard time.isNumeric, CMTimeCompare(time, previousTime) > 0 else { return nil }
            // Отдельный reader подрезает PTS первого кадра под начало диапазона.
            // Нужен кадр, который покрывает target, а не следующий кадр после target.
            if CMTimeCompare(time, target) > 0 { return [firstLuma, previousLuma] }
            let value = next.luma
            if CMTimeCompare(time, target) == 0 { return [firstLuma, value] }
            previousTime = time
            previousLuma = value
        }
        // У последнего кадра длительность может быть неизвестна; проверит исходный одиночный путь.
        return nil
    }

    private static func nextFrameLuma(_ output: AVAssetReaderTrackOutput) -> (time: CMTime, luma: Double)? {
        autoreleasepool {
            guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample),
                let value = luma(of: buffer)
            else { return nil }
            return (CMSampleBufferGetPresentationTimeStamp(sample), value)
        }
    }

    private static func frameLuma(
        asset: AVAsset, track: AVAssetTrack, at time: Double, onReaderStart: () -> Void
    ) throws -> Double {
        let (reader, output) = try frameReader(
            asset: asset, track: track,
            range: CMTimeRange(start: frameTime(time), duration: frameReadWindow), onReaderStart: onReaderStart)
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), let image = CMSampleBufferGetImageBuffer(sample),
            let luma = luma(of: image)
        else { throw SeamProbeError.noFrame(time) }
        return luma
    }

    private static func frameReader(
        asset: AVAsset, track: AVAssetTrack, range: CMTimeRange, onReaderStart: () -> Void
    ) throws -> (AVAssetReader, AVAssetReaderTrackOutput) {
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw SeamProbeError.unreadable }
        reader.add(output)
        reader.timeRange = range
        guard reader.startReading() else { throw SeamProbeError.unreadable }
        onReaderStart()
        return (reader, output)
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
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: pcmSettings)
        return try read(reader, output, from: from, to: to, wanted: wanted)
    }

    /// То же для склейки проекта (AVComposition): звуковые дорожки смешиваются, как при записи.
    static func samples(asset: AVAsset, from: Double, to: Double) async throws -> (samples: [Float], sampleRate: Double)
    {
        let wanted = Int(((to - from) * readSampleRate).rounded())
        guard wanted > 0 else { return ([], readSampleRate) }
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { throw SeamProbeError.noAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: pcmSettings)
        return try read(reader, output, from: from, to: to, wanted: wanted)
    }

    /// Моно Float32 48 кГц.
    private static var pcmSettings: [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: readSampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }

    private static func read(
        _ reader: AVAssetReader, _ output: AVAssetReaderOutput, from: Double, to: Double, wanted: Int
    ) throws -> (samples: [Float], sampleRate: Double) {
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
