import AppKit

let application = NSApplication.shared

#if DEBUG
if let flag = CommandLine.arguments.firstIndex(of: "--update-selftest"), CommandLine.arguments.count > flag + 1,
   let feed = URL(string: CommandLine.arguments[flag + 1]) {
    Task { @MainActor in await UpdateSelfTest.run(feed: feed) }
    application.setActivationPolicy(.prohibited)
    application.run()
}

if let flag = CommandLine.arguments.firstIndex(of: "--scroll-probe"), CommandLine.arguments.count > flag + 2 {
    let seconds = Double(CommandLine.arguments[flag + 1]) ?? 6
    let output = URL(fileURLWithPath: CommandLine.arguments[flag + 2])
    Task { @MainActor in
        await PreviewSmart.scrollProbe(rect: CGRect(x: 200, y: 180, width: 880, height: 640), seconds: seconds, output: output)
        exit(0)
    }
    application.setActivationPolicy(.prohibited)
    application.run()
}

if CommandLine.arguments.contains("--live-check") {
    Task { @MainActor in
        await PreviewRenderer.liveCheck()
        exit(0)
    }
    application.setActivationPolicy(.prohibited)
    application.run()
}

if let flag = CommandLine.arguments.firstIndex(of: "--render-preview"), CommandLine.arguments.count > flag + 1 {
    let directory = URL(fileURLWithPath: CommandLine.arguments[flag + 1], isDirectory: true)
    Task { @MainActor in
        await PreviewRenderer.run(into: directory)
        exit(0)
    }
    application.setActivationPolicy(.prohibited)
    application.run()
}
#endif

let appDelegate = MainActor.assumeIsolated { AppDelegate() }
application.delegate = appDelegate
application.setActivationPolicy(.accessory)
application.run()
