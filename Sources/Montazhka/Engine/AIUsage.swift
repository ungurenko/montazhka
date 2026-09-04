import Foundation

/// Во что обошёлся один запуск анализа: сколько запросов ушло к модели, сколько
/// токенов она прочитала и написала и сколько это стоило.
///
/// OpenRouter отдаёт эти цифры в каждом ответе, поэтому стоимость здесь точная,
/// а не прикидка по прайсу. У CLI-агентов таких данных нет — там расход остаётся
/// пустым, и интерфейс о нём молчит.
struct AIUsage: Equatable, Sendable {
    var requests: Int
    var promptTokens: Int
    var completionTokens: Int
    /// Стоимость в долларах США: кредит OpenRouter равен доллару. `nil`, если
    /// провайдер цену не назвал.
    var cost: Double?

    static let empty = AIUsage(requests: 0, promptTokens: 0, completionTokens: 0, cost: nil)

    var totalTokens: Int { promptTokens + completionTokens }

    static func + (lhs: AIUsage, rhs: AIUsage) -> AIUsage {
        AIUsage(
            requests: lhs.requests + rhs.requests,
            promptTokens: lhs.promptTokens + rhs.promptTokens,
            completionTokens: lhs.completionTokens + rhs.completionTokens,
            cost: lhs.cost.map { $0 + (rhs.cost ?? 0) } ?? rhs.cost)
    }

    static func += (lhs: inout AIUsage, rhs: AIUsage) { lhs = lhs + rhs }

    /// Готовая строка для интерфейса: «$0,0042 · 14 200 токенов». `nil`, когда
    /// запросов не было — например, результат взяли из кэша.
    var summary: String? {
        guard requests > 0 else { return nil }
        let count = Self.tokensFormatter.string(from: NSNumber(value: totalTokens)) ?? "\(totalTokens)"
        let tokens = "\(count) \(Self.tokenWord(totalTokens))"
        guard let cost else { return tokens }
        return "\(Self.priceText(cost)) · \(tokens)"
    }

    private static func tokenWord(_ count: Int) -> String {
        switch count % 10 {
        case 1 where count % 100 != 11: return "токен"
        case 2, 3, 4: return (12...14).contains(count % 100) ? "токенов" : "токена"
        default: return "токенов"
        }
    }

    /// Мелкие суммы округлять до центов бессмысленно — анализ стоит доли цента.
    private static func priceText(_ cost: Double) -> String {
        let formatter = cost < 0.01 ? priceFormatter(digits: 4) : priceFormatter(digits: 2)
        let value = formatter.string(from: NSNumber(value: cost)) ?? String(format: "%.4f", cost)
        return "$\(value)"
    }

    private static func priceFormatter(digits: Int) -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "ru_RU")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        formatter.usesGroupingSeparator = false
        return formatter
    }

    private static let tokensFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.groupingSeparator = "\u{00a0}"
        formatter.groupingSize = 3
        formatter.usesGroupingSeparator = true
        return formatter
    }()
}
