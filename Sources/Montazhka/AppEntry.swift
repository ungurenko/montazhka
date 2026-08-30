import Foundation

/// Единая точка входа для SwiftPM и тонкого Xcode-host приложения.
@MainActor
public func runMontazhka() async {
    let arguments = CommandLine.arguments
    if arguments.dropFirst().first == "agent" || arguments.dropFirst().first == "mcp" {
        let code = await AgentCommand.run(arguments: arguments)
        exit(code)
    } else if arguments.contains("--selftest") {
        SelfTest.run()
    } else if let index = arguments.firstIndex(of: "--gen-video"), index + 1 < arguments.count {
        SelfTest.generateDemoVideo(to: arguments[index + 1])
    } else {
        MontazhkaApp.main()
    }
}
