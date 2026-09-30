/// Счётчик поколений асинхронной работы: результат устаревшего поколения отбрасывается.
struct Generation {
    private var value = 0

    var current: Int { value }

    mutating func advance() -> Int {
        value += 1
        return value
    }

    func isCurrent(_ generation: Int) -> Bool { generation == value }
}
