@preconcurrency import AVFoundation
import Foundation

/// Сквозная самопроверка готового движка: звук, субтитры, склейка и экспорт.
/// Запуск: `.build/debug/Montazhka --selftest`
enum SelfTest {
    // Все записи идут последовательно из единственной задачи runAll.
    private nonisolated(unsafe) static var failures = 0

    private static func check(_ condition: Bool, _ label: String) {
        if condition {
            print("  ✓ \(label)")
        } else {
            failures += 1
            print("  ✗ ПРОВАЛ: \(label)")
        }
    }

    private static func approx(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool {
        abs(a - b) <= tolerance
    }

    /// Главный поток остаётся крутить цикл событий (нужен системным колбэкам),
    /// а тесты по завершении сами выходят из процесса.
    static func run() -> Never {
        setvbuf(stdout, nil, _IONBF, 0)  // вывод без буферизации — виден сразу
        // Сторожевой таймер: молчаливое зависание — тоже провал.
        // Таймаут можно переопределить: MONTAZHKA_SELFTEST_TIMEOUT=<секунды>.
        let timeout =
            ProcessInfo.processInfo.environment["MONTAZHKA_SELFTEST_TIMEOUT"]
            .flatMap(UInt64.init) ?? 120
        Task.detached {
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            print("\nТАЙМАУТ: самопроверка не уложилась в \(timeout) сек")
            dumpOwnStacks()
            exit(3)
        }
        Task.detached {
            await runAll()
            print(failures == 0 ? "\nВСЕ ПРОВЕРКИ ПРОЙДЕНЫ" : "\nПРОВАЛОВ: \(failures)")
            exit(failures == 0 ? 0 : 1)
        }
        RunLoop.main.run()
        exit(2)
    }

    /// Печатает стеки всех потоков через /usr/bin/sample — редкое зависание
    /// (например, стопор системного видеокодировщика) само оставляет улики.
    private static func dumpOwnStacks() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        process.arguments = ["\(getpid())", "3"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        guard (try? process.run()) != nil else {
            print("(не удалось снять стеки: sample недоступен)")
            return
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            print("--- Стеки потоков в момент таймаута ---")
            print(text)
        }
    }

    private static func runAll() async {
        failures += await ShortsSubtitleSelfTest.run()
        await testAudioPipeline()
        await testVoiceEnhance()
        await testBackgroundMusic()
        await testMusicEQ()
    }

    /// Генерирует то же 12-секундное тестовое видео в указанный файл (для ручной проверки интерфейса).
    static func generateDemoVideo(to path: String) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        Task.detached {
            do {
                let segments: [(duration: Double, loud: Bool)] = [
                    (3.0, true), (2.0, false), (3.0, true), (1.5, false), (2.5, true),
                ]
                try await TestVideoFactory.make(segments: segments, to: URL(fileURLWithPath: path))
                print("✓ демо-видео: \(path)")
                exit(0)
            } catch {
                print("✗ не удалось: \(error.localizedDescription)")
                exit(1)
            }
        }
        RunLoop.main.run()
        exit(2)
    }

    /// Типы верхнеуровневых кусков MP4-файла по порядку — для проверки, что `moov`
    /// (оглавление) записан раньше `mdat` (данных): такой файл стримится в мессенджерах.
    private static func topLevelAtoms(of url: URL) -> [String] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var atoms: [String] = []
        var offset = 0
        while offset + 8 <= data.count {
            var size = 0
            for i in 0..<4 { size = size << 8 | Int(data[offset + i]) }
            guard let type = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .ascii) else { break }
            atoms.append(type)
            if size == 1 {  // 64-битный размер в следующих 8 байтах
                guard offset + 16 <= data.count else { break }
                size = 0
                for i in 8..<16 { size = size << 8 | Int(data[offset + i]) }
            } else if size == 0 {
                break  // кусок до конца файла
            }
            guard size >= 8 else { break }
            offset += size
        }
        return atoms
    }

    // MARK: - Звук, склейка, экспорт

    private static func testAudioPipeline() async {
        print("Звук и экспорт (на сгенерированном видео 12 сек):")
        // Речь 0–3, тишина 3–5, речь 5–8, тишина 8–9.5, речь 9.5–12
        let segments: [(duration: Double, loud: Bool)] = [
            (3.0, true), (2.0, false), (3.0, true), (1.5, false), (2.5, true),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            try await TestVideoFactory.make(segments: segments, to: url)
        } catch {
            check(false, "генерация тестового видео (\(error.localizedDescription))")
            return
        }
        check(true, "тестовое видео сгенерировано")

        // Волна
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-cache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let store = WaveformStore(cacheDir: cacheDir)
        guard let peaks = await store.ensure(path: url.path) else {
            check(false, "извлечение волны звука")
            return
        }
        check(approx(Double(peaks.count), 1200, 60), "волна: ~1200 окон по 10 мс (получено \(peaks.count))")

        // Поиск пауз
        let clip = Clip(sourcePath: url.path, start: 0, end: 12)
        var settings = DetectionSettings(thresholdDB: -40, minPauseDuration: 0.8, paddingMS: 150)
        var found = SilenceDetector.findPauses(
            clips: [clip],
            peaksFor: { store.peaks(for: $0) },
            settings: settings)
        check(found.count == 2, "найдены обе паузы (найдено: \(found.count))")
        if found.count == 2 {
            check(
                approx(found[0].start, 3.15, 0.3) && approx(found[0].end, 4.85, 0.3),
                "первая пауза на своём месте (~3.2–4.8)")
            check(
                approx(found[1].start, 8.15, 0.3) && approx(found[1].end, 9.35, 0.3),
                "вторая пауза на своём месте (~8.2–9.3)")
        }

        // Фильтр по минимальной длине
        settings.minPauseDuration = 1.8
        found = SilenceDetector.findPauses(
            clips: [clip],
            peaksFor: { store.peaks(for: $0) },
            settings: settings)
        check(found.count == 1, "минимальная длина 1.8 сек отсекает короткую паузу")

        // Вырезаем паузы и склеиваем: 12 − 2 − 1.5 = 8.5 сек
        var clips = [clip]
        clips = TimelineOps.removingRange(clips: clips, start: 8, end: 9.5)
        clips = TimelineOps.removingRange(clips: clips, start: 3, end: 5)
        check(clips.count == 3, "после вырезки двух пауз осталось 3 куска")

        let (composition, voiceMix) = await CompositionBuilder.build(clips: clips)
        let duration = (try? await composition.load(.duration).seconds) ?? 0
        check(approx(duration, 8.5, 0.2), "длительность склейки 8.5 сек (получено \(String(format: "%.2f", duration)))")
        check(
            voiceMix != nil && voiceMix?.inputParameters.count == 1,
            "на голосовых стыках построены микрозатухания по 8 мс")

        // Экспорт собственным перекодировщиком (компактное качество)
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            let settings = try await Transcoder.settings(
                for: .compact,
                input: ExportInput(
                    composition: composition,
                    audioMix: voiceMix))
            try await Transcoder.export(
                input: ExportInput(
                    composition: composition,
                    audioMix: voiceMix),
                settings: settings, to: out
            ) { _ in }
            check(true, "экспорт завершился")
        } catch {
            check(false, "экспорт завершился (ошибка: \(error.localizedDescription))")
            return
        }

        let exported = AVURLAsset(url: out)
        let exportedDuration = (try? await exported.load(.duration).seconds) ?? 0
        check(
            approx(exportedDuration, 8.5, 0.3),
            "длительность готового MP4 8.5 сек (получено \(String(format: "%.2f", exportedDuration)))")
        let videoTracks = (try? await exported.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await exported.loadTracks(withMediaType: .audio)) ?? []
        check(!videoTracks.isEmpty && !audioTracks.isEmpty, "в готовом файле есть и видео, и звук")

        // Размер не больше оценки с запасом (VBR может недобрать — это нормально)
        let estimate = ExportQuality.compact.estimatedBytes(
            duration: 8.5,
            displaySize: CGSize(width: 320, height: 180))
        let actualSize = (try? FileManager.default.attributesOfItem(atPath: out.path)[.size] as? Int64) ?? 0
        check(
            actualSize > 0 && actualSize <= Int64(Double(estimate) * 1.4),
            "размер файла в пределах оценки (\(actualSize) байт при оценке \(estimate))")

        // moov раньше mdat — файл можно смотреть в мессенджере не скачивая целиком
        let atoms = topLevelAtoms(of: out)
        if let moov = atoms.firstIndex(of: "moov"), let mdat = atoms.firstIndex(of: "mdat") {
            check(moov < mdat, "оглавление MP4 в начале файла (стриминг)")
        } else {
            check(false, "оглавление MP4 в начале файла (куски: \(atoms.joined(separator: ", ")))")
        }
    }

    // MARK: - Улучшение голоса

    private static func testVoiceEnhance() async {
        print("Улучшение голоса (на сгенерированном видео 12 сек):")
        // Громкая речь / шумная «тишина» / тихая речь / шум / громкая речь
        let segments: [(duration: Double, amplitude: Double)] = [
            (3.0, 0.4), (2.0, 0.005), (3.0, 0.1), (2.0, 0.005), (2.0, 0.4),
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-voice-\(UUID().uuidString).mov")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            try await TestVideoFactory.make(segments: segments, to: url)
        } catch {
            check(false, "генерация тестового видео (\(error.localizedDescription))")
            return
        }

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-voice-cache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        let settings = VoiceEnhanceSettings(enabled: true, leveling: 70, noiseReduction: 90, presence: 50)
        let outURL = cacheDir.appendingPathComponent("enhanced.caf")
        do {
            try await VoiceEnhancer.render(
                sourcePath: url.path, settings: settings,
                to: outURL, isCancelled: { false })
        } catch {
            check(false, "обработка звука (\(error))")
            return
        }
        check(FileManager.default.fileExists(atPath: outURL.path), "обработанный файл создан")

        // Длительность сохранилась
        let enhancedAsset = AVURLAsset(url: outURL)
        let enhancedDuration = (try? await enhancedAsset.load(.duration).seconds) ?? 0
        check(
            approx(enhancedDuration, 12.0, 0.05),
            "длительность не поплыла (получено \(String(format: "%.3f", enhancedDuration)))")

        // RMS по сегментам: волна оригинала и обработанного
        let waveStore = WaveformStore(cacheDir: cacheDir)
        guard let origPeaks = await waveStore.ensure(path: url.path),
            let enhPeaks = await waveStore.ensure(path: outURL.path)
        else {
            check(false, "извлечение волны для сравнения")
            return
        }
        // Середины сегментов в окнах по 10 мс (с отступом 0.3 с от краёв)
        func rms(_ peaks: [Float], _ from: Double, _ to: Double) -> Double {
            let a = max(0, Int(from * 100)), b = min(peaks.count, Int(to * 100))
            guard b > a else { return 0 }
            return Double(peaks[a..<b].reduce(0, +)) / Double(b - a)
        }
        let origLoud = rms(origPeaks, 0.3, 2.7)  // речь 0.4
        let origNoise = rms(origPeaks, 3.3, 4.7)  // шум 0.005
        let origQuiet = rms(origPeaks, 5.3, 7.7)  // тихая речь 0.1
        let enhLoud = rms(enhPeaks, 0.3, 2.7)
        let enhNoise = rms(enhPeaks, 3.3, 4.7)
        let enhQuiet = rms(enhPeaks, 5.3, 7.7)

        // Гейт: шум относительно речи стал заметно тише
        if origLoud > 0, enhLoud > 0 {
            let origRatio = origNoise / origLoud
            let enhRatio = enhNoise / enhLoud
            check(
                enhRatio < 0.5 * origRatio,
                "шум в паузах приглушён (было \(String(format: "%.4f", origRatio)), стало \(String(format: "%.4f", enhRatio)))"
            )
            // Выравнивание: разрыв громкой и тихой речи сократился
            let origSpread = origLoud / max(origQuiet, 0.0001)
            let enhSpread = enhLoud / max(enhQuiet, 0.0001)
            check(
                enhSpread < 0.75 * origSpread,
                "громкость выровнена (разрыв был \(String(format: "%.2f", origSpread)), стал \(String(format: "%.2f", enhSpread)))"
            )
        } else {
            check(false, "волна обработанного файла не пустая")
        }

        // Нет клиппинга
        var filePeak: Float = 0
        if let file = try? AVAudioFile(forReading: outURL, commonFormat: .pcmFormatFloat32, interleaved: false),
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768)
        {
            while file.framePosition < file.length {
                guard (try? file.read(into: buf)) != nil, buf.frameLength > 0,
                    let data = buf.floatChannelData
                else { break }
                for ch in 0..<Int(buf.format.channelCount) {
                    for i in 0..<Int(buf.frameLength) { filePeak = max(filePeak, abs(data[ch][i])) }
                }
            }
        }
        check(
            filePeak > 0 && filePeak <= 0.99,
            "нет перегруза (пик \(String(format: "%.3f", filePeak)))")

        // Кэш: первый ensure рендерит, второй отдаёт тот же файл мгновенно
        let enhanceStore = VoiceEnhanceStore(cacheDir: cacheDir)
        if let first = try? await enhanceStore.ensure(source: url.path, settings: settings) {
            let firstMTime =
                (try? FileManager.default.attributesOfItem(atPath: first.path))?[.modificationDate] as? Date
            let second = try? await enhanceStore.ensure(source: url.path, settings: settings)
            let secondMTime = second.flatMap {
                (try? FileManager.default.attributesOfItem(atPath: $0.path))?[.modificationDate] as? Date
            }
            check(
                second == first && firstMTime == secondMTime,
                "повторная обработка берётся из кэша")

            // Склейка с улучшенным звуком: длительность верна, звук на месте
            let clip = Clip(sourcePath: url.path, start: 1.0, end: 11.0)
            let (composition, _) = await CompositionBuilder.build(
                clips: [clip],
                enhancedAudio: [url.path: first])
            let compDuration = (try? await composition.load(.duration).seconds) ?? 0
            let compAudio = (try? await composition.loadTracks(withMediaType: .audio)) ?? []
            var audioDuration = 0.0
            if let audioTrack = compAudio.first,
                let trackRange = try? await audioTrack.load(.timeRange)
            {
                audioDuration = trackRange.duration.seconds
            }
            check(
                approx(compDuration, 10.0, 0.1) && approx(audioDuration, 10.0, 0.1),
                "склейка с улучшенным звуком: 10 сек видео и звука (получено \(String(format: "%.2f", compDuration)) / \(String(format: "%.2f", audioDuration)))"
            )
        } else {
            check(false, "обработка через кэш-хранилище")
        }

    }

    // MARK: - Фоновая музыка

    private static func testBackgroundMusic() async {
        print("Фоновая музыка (видео 12 сек, мелодия 3 сек):")
        // Видео: речь 0–3, тишина 3–6, речь 6–9, тишина 9–12 — в тишине слышно только музыку
        let videoSegments: [(duration: Double, amplitude: Double)] = [
            (3.0, 0.4), (3.0, 0.0), (3.0, 0.4), (3.0, 0.0),
        ]
        let videoURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-music-video-\(UUID().uuidString).mov")
        // «Мелодия» — 3 секунды ровного тона в контейнере .mov (звуковая дорожка оттуда)
        let musicURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-music-\(UUID().uuidString).mov")
        defer {
            try? FileManager.default.removeItem(at: videoURL)
            try? FileManager.default.removeItem(at: musicURL)
        }
        do {
            try await TestVideoFactory.make(segments: videoSegments, to: videoURL)
            try await TestVideoFactory.make(segments: [(3.0, 0.3)], to: musicURL)
        } catch {
            check(false, "генерация тестовых файлов (\(error.localizedDescription))")
            return
        }

        let clip = Clip(sourcePath: videoURL.path, start: 0, end: 12)
        let music = MusicInput(url: musicURL, volume: 0.5)
        let (composition, audioMix) = await CompositionBuilder.build(clips: [clip], music: music)

        // Две звуковые дорожки, музыкальная покрывает всё видео (луп из 4 проигрышей)
        let audioTracks = (try? await composition.loadTracks(withMediaType: .audio)) ?? []
        check(audioTracks.count == 2, "в склейке две звуковые дорожки (получено \(audioTracks.count))")
        var musicCoverage = 0.0
        if audioTracks.count == 2,
            let range = try? await audioTracks[1].load(.timeRange)
        {
            musicCoverage = (range.start + range.duration).seconds
        }
        check(
            approx(musicCoverage, 12.0, 0.1),
            "музыка по кругу покрывает всё видео (получено \(String(format: "%.2f", musicCoverage)))")
        check(
            audioMix != nil && audioMix?.inputParameters.count == 1,
            "микс громкости построен для музыкальной дорожки")

        // Экспорт с музыкой и без — в «тишине» музыкальная версия заметно громче.
        // Идёт через собственный перекодировщик: заодно проверяем, что микс музыки
        // (луп, громкость, затухание) переживает новый путь экспорта.
        func exportMP4(_ asset: AVMutableComposition, mix: AVAudioMix?) async -> URL? {
            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("montazhka-selftest-music-out-\(UUID().uuidString).mp4")
            do {
                let settings = try await Transcoder.settings(
                    for: .medium,
                    input: ExportInput(
                        composition: asset,
                        audioMix: mix))
                try await Transcoder.export(
                    input: ExportInput(composition: asset, audioMix: mix),
                    settings: settings, to: out
                ) { _ in }
                return out
            } catch {
                return nil
            }
        }

        let (plainComposition, _) = await CompositionBuilder.build(clips: [clip])
        guard let withMusic = await exportMP4(composition, mix: audioMix),
            let withoutMusic = await exportMP4(plainComposition, mix: nil)
        else {
            check(false, "экспорт с музыкой завершился")
            return
        }
        defer {
            try? FileManager.default.removeItem(at: withMusic)
            try? FileManager.default.removeItem(at: withoutMusic)
        }
        check(true, "экспорт с музыкой завершился")

        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-music-cache-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }
        let waveStore = WaveformStore(cacheDir: cacheDir)
        guard let musicPeaks = await waveStore.ensure(path: withMusic.path),
            let plainPeaks = await waveStore.ensure(path: withoutMusic.path)
        else {
            check(false, "извлечение волны готовых файлов")
            return
        }
        func rms(_ peaks: [Float], _ from: Double, _ to: Double) -> Double {
            let a = max(0, Int(from * 100)), b = min(peaks.count, Int(to * 100))
            guard b > a else { return 0 }
            return Double(peaks[a..<b].reduce(0, +)) / Double(b - a)
        }
        // Окно тишины 3.5–5.5: без музыки почти ноль, с музыкой — слышный фон
        let silenceWithMusic = rms(musicPeaks, 3.5, 5.5)
        let silencePlain = rms(plainPeaks, 3.5, 5.5)
        check(
            silenceWithMusic > max(silencePlain * 3, 0.01),
            "музыка слышна в паузах речи (фон \(String(format: "%.4f", silenceWithMusic)) против \(String(format: "%.4f", silencePlain)))"
        )
        // Затухание: последние полсекунды тише середины паузы
        let tail = rms(musicPeaks, 11.6, 11.95)
        check(
            tail < silenceWithMusic * 0.6,
            "в конце музыка затихает (хвост \(String(format: "%.4f", tail)))")

    }

    // MARK: - Эквалайзер музыки («не мешать голосу»)

    private static func testMusicEQ() async {
        print("Эквалайзер музыки (тоны 2500 Гц и 220 Гц):")
        let cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-eq-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: cacheDir) }

        // Тон в зоне речи (2500 Гц) должен приглушиться примерно на 5 дБ,
        // низкий тон (220 Гц) — почти не измениться.
        func renderedRMS(frequency: Double) async -> (original: Double, processed: Double)? {
            let src = cacheDir.appendingPathComponent("tone-\(Int(frequency)).mov")
            let out = cacheDir.appendingPathComponent("tone-\(Int(frequency))-eq.caf")
            do {
                try await TestVideoFactory.make(segments: [(4.0, 0.3)], toneFrequency: frequency, to: src)
                try await MusicEQ.render(sourcePath: src.path, to: out, isCancelled: { false })
            } catch {
                return nil
            }
            let waveStore = WaveformStore(cacheDir: cacheDir)
            guard let origPeaks = await waveStore.ensure(path: src.path),
                let eqPeaks = await waveStore.ensure(path: out.path)
            else { return nil }
            func rms(_ peaks: [Float]) -> Double {
                let inner = peaks.dropFirst(50).dropLast(50)
                guard !inner.isEmpty else { return 0 }
                return Double(inner.reduce(0, +)) / Double(inner.count)
            }
            return (rms(origPeaks), rms(eqPeaks))
        }

        guard let speech = await renderedRMS(frequency: 2500) else {
            check(false, "обработка тона 2500 Гц")
            return
        }
        check(
            speech.processed < speech.original * 0.75,
            "зона речи приглушена (было \(String(format: "%.3f", speech.original)), стало \(String(format: "%.3f", speech.processed)))"
        )

        guard let low = await renderedRMS(frequency: 220) else {
            check(false, "обработка тона 220 Гц")
            return
        }
        check(
            low.processed > low.original * 0.55,
            "низкий тон почти не тронут (было \(String(format: "%.3f", low.original)), стало \(String(format: "%.3f", low.processed)))"
        )

        // Кэш-хранилище: второй запрос отдаёт готовый файл
        let store = MusicEQStore(cacheDir: cacheDir)
        let src = cacheDir.appendingPathComponent("tone-2500.mov")
        if let first = try? await store.ensure(source: src.path) {
            let second = try? await store.ensure(source: src.path)
            check(second == first, "повторная обработка музыки берётся из кэша")
        } else {
            check(false, "обработка через кэш-хранилище музыки")
        }

    }
}
