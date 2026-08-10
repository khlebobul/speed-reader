import AppKit

/// Detects browser URLs via AppleScript.
enum BrowserURLReader {

    struct ErrorMessage: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    struct Browser {
        let name: String
        let bundleID: String
    }

    struct TabInfo: Identifiable {
        public let id = UUID()
        public let title: String
        public let url: String
    }

    private static let browsers: [Browser] = [
        Browser(name: "Safari", bundleID: "com.apple.Safari"),
        Browser(name: "Google Chrome", bundleID: "com.google.Chrome"),
        Browser(name: "Arc", bundleID: "company.thebrowser.Browser"),
        Browser(name: "Brave Browser", bundleID: "com.brave.Browser"),
        Browser(name: "Microsoft Edge", bundleID: "com.microsoft.edgemac"),
        Browser(name: "Opera", bundleID: "com.operasoftware.Opera"),
        Browser(name: "Vivaldi", bundleID: "com.vivaldi.Vivaldi"),
    ]

    static func isSupported(bundleID: String) -> Bool {
        browsers.contains(where: { $0.bundleID == bundleID })
    }

    // MARK: - Single-tab detection (active tab)

    static func detect(app: NSRunningApplication? = nil) -> Result<(url: String, browserName: String), ErrorMessage> {
        let targetApp = app ?? NSWorkspace.shared.frontmostApplication
        guard let targetApp else {
            return .failure(ErrorMessage(message: "No frontmost application found"))
        }

        let appName = targetApp.localizedName ?? "unknown"
        let bundleID = targetApp.bundleIdentifier ?? "nil"

        guard let browser = browsers.first(where: { $0.bundleID == bundleID }) else {
            return .failure(ErrorMessage(message: "Frontmost app is not a supported browser: \(appName) (\(bundleID))\n\nSupported browsers: Safari, Chrome, Arc, Brave, Edge, Opera, Vivaldi"))
        }

        let script: String
        if browser.bundleID == "com.apple.Safari" {
            script = """
            tell application "\(browser.name)"
                if exists front document then
                    return URL of front document
                end if
            end tell
            """
        } else {
            script = """
            tell application "\(browser.name)"
                if exists active tab of front window then
                    return URL of active tab of front window
                end if
            end tell
            """
        }

        let (output, osaErr, nsErr) = runScript(script)
        if let output, !output.isEmpty {
            return .success((output, browser.name))
        }

        let nsErrorDesc = nsErr?.description ?? ""
        return .failure(ErrorMessage(message: """
            Could not get URL from \(browser.name).
            osascript: \(osaErr)
            NSAppleScript: \(nsErrorDesc)

            Open System Settings → Privacy & Security → Automation
            and ensure "Speed Reader" has permission to control "\(browser.name)".
            """))
    }

    // MARK: - Multi-tab detection (all open tabs)

    static func detectAllTabs(app: NSRunningApplication? = nil) -> Result<(browserName: String, tabs: [TabInfo]), ErrorMessage> {
        let targetApp: NSRunningApplication
        if let app {
            targetApp = app
        } else if let found = NSWorkspace.shared.runningApplications.first(where: {
            guard let id = $0.bundleIdentifier else { return false }
            return isSupported(bundleID: id)
        }) {
            targetApp = found
        } else {
            return .failure(ErrorMessage(message: "No supported browser is running"))
        }

        let bundleID = targetApp.bundleIdentifier ?? ""
        guard let browser = browsers.first(where: { $0.bundleID == bundleID }) else {
            return .failure(ErrorMessage(message: "Not a supported browser"))
        }

        let script: String
        if browser.bundleID == "com.apple.Safari" {
            script = """
            tell application "\(browser.name)"
                set output to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        if exists t then
                            set output to output & (name of t) & "|||" & (URL of t) & "\n"
                        end if
                    end repeat
                end repeat
                return output
            end tell
            """
        } else {
            script = """
            tell application "\(browser.name)"
                set output to ""
                repeat with w in windows
                    repeat with t in tabs of w
                        set output to output & (title of t) & "|||" & (URL of t) & "\n"
                    end repeat
                end repeat
                return output
            end tell
            """
        }

        let (rawOutput, osaErr, nsErr) = runScript(script)
        guard let rawOutput, !rawOutput.isEmpty else {
            let nsErrorDesc = nsErr?.description ?? ""
            return .failure(ErrorMessage(message: """
                Could not get browser tabs from \(browser.name).
                osascript: \(osaErr)
                NSAppleScript: \(nsErrorDesc)

                Open System Settings → Privacy & Security → Automation
                and ensure "Speed Reader" has permission to control "\(browser.name)".
                """))
        }

        let tabs: [TabInfo] = rawOutput
            .components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .compactMap { line in
                let parts = line.components(separatedBy: "|||")
                guard parts.count == 2 else { return nil }
                let title = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let url = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                guard !url.isEmpty else { return nil }
                return TabInfo(title: title.isEmpty ? url : title, url: url)
            }

        return .success((browser.name, tabs))
    }

    // MARK: - AppleScript runner

    private static func runScript(_ script: String) -> (output: String?, osascriptStderr: String, nsAppleScriptError: NSDictionary?) {
        let pipe = Pipe()
        let errorPipe = Pipe()
        let process = Process()
        process.launchPath = "/usr/bin/osascript"
        process.arguments = ["-e", script]
        process.standardOutput = pipe
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let output = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                   !output.isEmpty {
                    return (output, "", nil)
                }
            }

            let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let errMsg = String(data: errData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            var appleScriptError: NSDictionary?
            let appleScriptResult = NSAppleScript(source: script)?
                .executeAndReturnError(&appleScriptError)

            if let output = appleScriptResult?.stringValue?
                .trimmingCharacters(in: .whitespacesAndNewlines),
               !output.isEmpty {
                return (output, "", nil)
            }

            return (nil, errMsg, appleScriptError)
        } catch {
            return (nil, "Failed to run osascript: \(error.localizedDescription)", nil)
        }
    }
}
