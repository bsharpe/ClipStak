import AppKit

private let appDelegate = ClipStakApp()

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
application.delegate = appDelegate
application.run()
