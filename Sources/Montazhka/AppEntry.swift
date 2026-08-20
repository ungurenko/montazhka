import Foundation

/// Единая точка входа для SwiftPM и тонкого Xcode-host приложения.
@MainActor
public func runMontazhka() {
    let arguments = CommandLine.arguments
    if arguments.contains("--selftest") {
        SelfTest.run()
    } else if let index = arguments.firstIndex(of: "--gen-video"), index + 1 < arguments.count {
        SelfTest.generateDemoVideo(to: arguments[index + 1])
    } else {
        MontazhkaApp.main()
    }
}
