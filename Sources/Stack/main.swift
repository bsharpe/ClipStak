import AppKit

private let appDelegate = StackApp()

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = appDelegate
application.run()
