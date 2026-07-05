import Foundation
import AVFoundation

/// Самопроверка движка: математика ленты, извлечение волны, поиск пауз, склейка, экспорт.
/// Запуск: `.build/debug/Montazhka --selftest`
enum SelfTest {
    private static var failures = 0

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
        setvbuf(stdout, nil, _IONBF, 0) // вывод без буферизации — виден сразу
        // Сторожевой таймер: молчаливое зависание — тоже провал
        Task.detached {
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            print("\nТАЙМАУТ: самопроверка не уложилась в 120 сек")
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

    private static func runAll() async {
        testTimelineMath()
        await testAudioPipeline()
    }

    /// Генерирует то же 12-секундное тестовое видео в указанный файл (для ручной проверки интерфейса).
    static func generateDemoVideo(to path: String) -> Never {
        setvbuf(stdout, nil, _IONBF, 0)
        Task.detached {
            do {
                let segments: [(duration: Double, loud: Bool)] = [
                    (3.0, true), (2.0, false), (3.0, true), (1.5, false), (2.5, true)
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

    // MARK: - Математика ленты

    private static func testTimelineMath() {
        print("Математика ленты:")
        func clip(_ start: Double, _ end: Double) -> Clip {
            Clip(sourcePath: "/tmp/fake.mov", start: start, end: end)
        }

        // Вырезка из середины делит клип на два
        var result = TimelineOps.removingRange(clips: [clip(0, 10)], start: 3, end: 5)
        check(result.count == 2
              && approx(result[0].end, 3, 0.001)
              && approx(result[1].start, 5, 0.001),
              "вырезка из середины делит клип на два")

        // Вырезка через границу двух клипов
        result = TimelineOps.removingRange(clips: [clip(0, 4), clip(0, 6)], start: 3, end: 6)
        let total = result.reduce(0) { $0 + $1.duration }
        check(result.count == 2 && approx(total, 7, 0.001),
              "вырезка через границу клипов сохраняет остаток (7 сек)")

        // Вырезка целого клипа
        result = TimelineOps.removingRange(clips: [clip(0, 4), clip(0, 6)], start: 0, end: 4)
        check(result.count == 1 && approx(result[0].duration, 6, 0.001),
              "вырезка целого клипа убирает его совсем")

        // Разрез
        if let split = TimelineOps.splitting(clips: [clip(2, 12)], at: 0, offset: 4) {
            check(split.count == 2
                  && approx(split[0].duration, 4, 0.001)
                  && approx(split[1].duration, 6, 0.001)
                  && approx(split[1].start, 6, 0.001),
                  "разрез даёт два куска без потери длительности")
        } else {
            check(false, "разрез даёт два куска без потери длительности")
        }
        check(TimelineOps.splitting(clips: [clip(0, 10)], at: 0, offset: 0.01) == nil,
              "разрез у самого края отклоняется")
    }

    // MARK: - Звук, склейка, экспорт

    private static func testAudioPipeline() async {
        print("Звук и экспорт (на сгенерированном видео 12 сек):")
        // Речь 0–3, тишина 3–5, речь 5–8, тишина 8–9.5, речь 9.5–12
        let segments: [(duration: Double, loud: Bool)] = [
            (3.0, true), (2.0, false), (3.0, true), (1.5, false), (2.5, true)
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
        var found = SilenceDetector.findPauses(clips: [clip],
                                               peaksFor: { store.peaks(for: $0) },
                                               settings: settings)
        check(found.count == 2, "найдены обе паузы (найдено: \(found.count))")
        if found.count == 2 {
            check(approx(found[0].start, 3.15, 0.3) && approx(found[0].end, 4.85, 0.3),
                  "первая пауза на своём месте (~3.2–4.8)")
            check(approx(found[1].start, 8.15, 0.3) && approx(found[1].end, 9.35, 0.3),
                  "вторая пауза на своём месте (~8.2–9.3)")
        }

        // Фильтр по минимальной длине
        settings.minPauseDuration = 1.8
        found = SilenceDetector.findPauses(clips: [clip],
                                           peaksFor: { store.peaks(for: $0) },
                                           settings: settings)
        check(found.count == 1, "минимальная длина 1.8 сек отсекает короткую паузу")

        // Вырезаем паузы и склеиваем: 12 − 2 − 1.5 = 8.5 сек
        var clips = [clip]
        clips = TimelineOps.removingRange(clips: clips, start: 8, end: 9.5)
        clips = TimelineOps.removingRange(clips: clips, start: 3, end: 5)
        check(clips.count == 3, "после вырезки двух пауз осталось 3 куска")

        let composition = await CompositionBuilder.build(clips: clips)
        let duration = (try? await composition.load(.duration).seconds) ?? 0
        check(approx(duration, 8.5, 0.2), "длительность склейки 8.5 сек (получено \(String(format: "%.2f", duration)))")

        // Экспорт
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("montazhka-selftest-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: out) }
        guard let session = AVAssetExportSession(asset: composition,
                                                 presetName: AVAssetExportPreset1280x720) else {
            check(false, "создание сессии экспорта")
            return
        }
        session.outputURL = out
        session.outputFileType = .mp4
        await session.export()
        check(session.status == .completed,
              "экспорт завершился (статус: \(session.status.rawValue), ошибка: \(session.error?.localizedDescription ?? "нет"))")

        let exported = AVURLAsset(url: out)
        let exportedDuration = (try? await exported.load(.duration).seconds) ?? 0
        check(approx(exportedDuration, 8.5, 0.3),
              "длительность готового MP4 8.5 сек (получено \(String(format: "%.2f", exportedDuration)))")
        let videoTracks = (try? await exported.loadTracks(withMediaType: .video)) ?? []
        let audioTracks = (try? await exported.loadTracks(withMediaType: .audio)) ?? []
        check(!videoTracks.isEmpty && !audioTracks.isEmpty, "в готовом файле есть и видео, и звук")
    }
}
