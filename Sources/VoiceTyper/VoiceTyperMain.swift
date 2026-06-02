import AppKit

private var appDelegate: AppDelegate?

@main
struct VoiceTyperMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let delegate = AppDelegate()
        appDelegate = delegate
        app.delegate = delegate

        app.run()
    }
}
