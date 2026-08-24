import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
    private var terminationInProgress = false
    private var terminationApproved = false
    
    override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }
    
    override func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in NSApp.windows {
                if !window.isVisible {
                    window.setIsVisible(true)
                }
                window.makeKeyAndOrderFront(self)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
        return true
    }
    
    override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
      return true
    }

    override func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if terminationApproved {
            return .terminateNow
        }
        if terminationInProgress {
            return .terminateLater
        }

        terminationInProgress = true
        AppLifecycleChannel.requestTermination { [weak self] safeToTerminate in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.terminationInProgress = false
                self.terminationApproved = safeToTerminate
                sender.reply(toApplicationShouldTerminate: safeToTerminate)
            }
        }
        return .terminateLater
    }
    
}
