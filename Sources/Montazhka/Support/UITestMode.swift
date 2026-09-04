import Foundation

/// Признак прогона под UI-тестами. Проверяем и флаг запуска, и переменную
/// окружения: по одному аргументу обычный запуск можно принять за тестовый,
/// а под тестами приложение работает на отдельных данных и настройках.
enum UITestMode {
    static var isActive: Bool {
        CommandLine.arguments.contains("--ui-testing")
            && ProcessInfo.processInfo.environment["MONTAZHKA_UI_TEST_MODE"] == "1"
    }
}
