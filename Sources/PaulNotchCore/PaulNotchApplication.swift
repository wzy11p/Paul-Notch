import AppKit

@MainActor
public enum PaulNotchApplication {
    private static let delegate = AppDelegate()

    public static func run() {
        let application = NSApplication.shared
        application.delegate = delegate
        application.run()
    }
}
