import Foundation

// Точка входа. Служебные режимы:
//   --selftest            прогнать проверки движка и выйти
//   --gen-video <путь>    сгенерировать 12-сек тестовое видео и выйти
//   --open-latest         открыть сразу последний проект (для отладки)
let arguments = CommandLine.arguments

if arguments.contains("--selftest") {
    SelfTest.run()
} else if let index = arguments.firstIndex(of: "--gen-video"), index + 1 < arguments.count {
    SelfTest.generateDemoVideo(to: arguments[index + 1])
} else {
    MontazhkaApp.main()
}
