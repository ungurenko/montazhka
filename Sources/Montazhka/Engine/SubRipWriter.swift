import Foundation

/// Субтитры файлом SubRip (.srt) рядом с видео: их понимают YouTube, плееры
/// и монтажные программы. Текст фразы тот же, что рисуют запечённые субтитры.
enum SubRipWriter {
    static func text(cues: [ShortsSubtitleCue], maxLineCharacters: Int = 42) -> String {
        var blocks: [String] = []
        for cue in cues {
            let lines = wrapped(cue.text, maxLineCharacters: maxLineCharacters)
            guard !lines.isEmpty else { continue }
            blocks.append(
                "\(blocks.count + 1)\n\(timestamp(cue.start)) --> \(timestamp(cue.end))\n"
                    + lines.joined(separator: "\n") + "\n")
        }
        return blocks.joined(separator: "\n")
    }

    /// Та же папка и то же имя, что у видео, расширение `.srt` — так плееры
    /// находят субтитры сами.
    static func url(forVideo videoURL: URL) -> URL {
        videoURL.deletingPathExtension().appendingPathExtension("srt")
    }

    /// `ЧЧ:ММ:СС,ммм` с округлением до ближайшей миллисекунды.
    private static func timestamp(_ seconds: Double) -> String {
        let total = Int((max(0, seconds) * 1000).rounded())
        return String(
            format: "%02ld:%02ld:%02ld,%03ld",
            total / 3_600_000, total / 60_000 % 60, total / 1000 % 60, total % 1000)
    }

    /// Длинная фраза делится по словам на две строки примерно поровну. Больше
    /// двух строк не бывает: если ровно не влезает, первая строка берёт сколько
    /// помещается, вторая — остаток.
    private static func wrapped(_ text: String, maxLineCharacters: Int) -> [String] {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let line = words.joined(separator: " ")
        guard line.count > maxLineCharacters, words.count > 1 else { return line.isEmpty ? [] : [line] }
        let splits = (1..<words.count).map { index in
            (first: words[..<index].joined(separator: " "), second: words[index...].joined(separator: " "))
        }
        let best =
            splits
            .filter { $0.first.count <= maxLineCharacters }
            .min { max($0.first.count, $0.second.count) < max($1.first.count, $1.second.count) }
            ?? splits[0]
        return [best.first, best.second]
    }
}
