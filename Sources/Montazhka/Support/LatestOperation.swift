/// Владеет одной заменяемой асинхронной операцией и не позволяет устаревшему
/// результату изменить состояние владельца.
@MainActor
final class LatestOperation {
    struct Token: Equatable {
        fileprivate let value: Int
    }

    private var task: Task<Void, Never>?
    private var generation = 0

    func start(_ work: @escaping @MainActor (Token) async -> Void) {
        task?.cancel()
        generation += 1
        let token = Token(value: generation)
        task = Task { [weak self] in
            await work(token)
            guard let self, isCurrent(token) else { return }
            task = nil
        }
    }

    func isCurrent(_ token: Token) -> Bool {
        token.value == generation && !Task.isCancelled
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }
}
