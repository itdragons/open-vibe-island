import Foundation

public struct ClaudeStatusLineInstallationStatus: Equatable, Sendable {
    public var claudeDirectory: URL
    public var settingsURL: URL
    public var scriptDirectoryURL: URL
    public var scriptURL: URL
    public var cacheURL: URL
    public var statusLineCommand: String?
    public var hasStatusLine: Bool
    public var managedStatusLineConfigured: Bool
    public var managedStatusLineInstalled: Bool
    public var managedStatusLineNeedsRepair: Bool
    public var hasConflictingStatusLine: Bool
    /// `true` when the managed script is installed in wrapper mode, preserving
    /// the user's existing `statusLine.command` under `_openIslandOriginalStatusLine`.
    public var managedStatusLineIsWrapper: Bool
    /// `true` when the saved original command or the delegate script points back at
    /// one of Open Island's own status-line scripts. Running that wrapper would spawn
    /// itself forever (issue #671); `install()` repairs it by dropping the bad delegate.
    public var managedStatusLineIsPoisoned: Bool

    public init(
        claudeDirectory: URL,
        settingsURL: URL,
        scriptDirectoryURL: URL,
        scriptURL: URL,
        cacheURL: URL,
        statusLineCommand: String?,
        hasStatusLine: Bool,
        managedStatusLineConfigured: Bool,
        managedStatusLineInstalled: Bool,
        managedStatusLineNeedsRepair: Bool,
        hasConflictingStatusLine: Bool,
        managedStatusLineIsWrapper: Bool = false,
        managedStatusLineIsPoisoned: Bool = false
    ) {
        self.claudeDirectory = claudeDirectory
        self.settingsURL = settingsURL
        self.scriptDirectoryURL = scriptDirectoryURL
        self.scriptURL = scriptURL
        self.cacheURL = cacheURL
        self.statusLineCommand = statusLineCommand
        self.hasStatusLine = hasStatusLine
        self.managedStatusLineConfigured = managedStatusLineConfigured
        self.managedStatusLineInstalled = managedStatusLineInstalled
        self.managedStatusLineNeedsRepair = managedStatusLineNeedsRepair
        self.hasConflictingStatusLine = hasConflictingStatusLine
        self.managedStatusLineIsWrapper = managedStatusLineIsWrapper
        self.managedStatusLineIsPoisoned = managedStatusLineIsPoisoned
    }
}

public enum ClaudeStatusLineInstallationError: LocalizedError, Sendable {
    case existingStatusLineConflict(command: String?)
    case invalidSettingsRoot
    case wrappableCommandMissing
    case wrapperWouldRecurse(command: String)

    public var errorDescription: String? {
        switch self {
        case let .existingStatusLineConflict(command):
            if let command, !command.isEmpty {
                return "Claude Code already has a custom status line: \(command)"
            }
            return "Claude Code already has a custom status line."
        case .invalidSettingsRoot:
            return "Claude Code settings.json must contain a top-level object."
        case .wrappableCommandMissing:
            return "No existing statusLine command was found to wrap."
        case let .wrapperWouldRecurse(command):
            return "Refusing to wrap Open Island's own status line script (\(command)); the wrapper would call itself forever."
        }
    }
}

public let openIslandOriginalStatusLineKey = "_openIslandOriginalStatusLine"

public final class ClaudeStatusLineInstallationManager: @unchecked Sendable {
    public static let managedScriptName = "open-island-statusline"
    public static let wrappedDelegateScriptName = "open-island-statusline-delegate"
    public static let legacyManagedScriptName = "vibe-island-statusline"
    public static let managedCacheURL = ClaudeUsageLoader.defaultCacheURL
    /// Every script Open Island (or its Vibe Island predecessor) may have installed as a
    /// status-line command. A `statusLine.command` that runs any of these is ours, however
    /// the path was spelled.
    public static let managedScriptNames: Set<String> = [
        managedScriptName,
        wrappedDelegateScriptName,
        legacyManagedScriptName,
    ]

    public let claudeDirectory: URL
    public let scriptDirectoryURL: URL
    public let legacyScriptDirectoryURL: URL
    private let fileManager: FileManager

    public init(
        claudeDirectory: URL = ClaudeConfigDirectory.resolved(),
        scriptDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".open-island", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true),
        legacyScriptDirectoryURL: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".vibe-island", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.claudeDirectory = claudeDirectory
        self.scriptDirectoryURL = scriptDirectoryURL
        self.legacyScriptDirectoryURL = legacyScriptDirectoryURL
        self.fileManager = fileManager
    }

    public func status() throws -> ClaudeStatusLineInstallationStatus {
        let settingsURL = claudeDirectory.appendingPathComponent("settings.json")
        let scriptURL = scriptDirectoryURL.appendingPathComponent(Self.managedScriptName)
        let legacyScriptURL = legacyScriptDirectoryURL.appendingPathComponent(Self.legacyManagedScriptName)

        let delegateScriptURL = scriptDirectoryURL.appendingPathComponent(Self.wrappedDelegateScriptName)

        let settings = try loadSettings(at: settingsURL)
        let statusLine = settings["statusLine"] as? [String: Any]
        let command = statusLine?["command"] as? String
        // Match by normalized path or script name rather than the exact string we wrote:
        // a `$HOME/...` or `~/...` spelling of our own script must never be mistaken for
        // a user command, or install-as-wrapper wraps itself (issue #671).
        let managedScriptPath = managedScriptPath(referencedBy: command)
        let managedStatusLineConfigured = managedScriptPath != nil
        let managedStatusLineInstalled = managedScriptPath.map { fileManager.fileExists(atPath: $0) } ?? false
        let hasStatusLine = statusLine != nil
        let hasConflictingStatusLine = hasStatusLine && !managedStatusLineConfigured
        let savedOriginal = settings[openIslandOriginalStatusLineKey]
        let managedStatusLineIsWrapper = managedStatusLineConfigured && savedOriginal != nil
        let savedOriginalIsPoisoned = savedOriginal != nil
            && isManagedStatusLineCommand((savedOriginal as? [String: Any])?["command"] as? String)
        let managedStatusLineIsPoisoned = managedStatusLineConfigured
            && (savedOriginalIsPoisoned || delegateScriptRunsManagedScript(at: delegateScriptURL))
        let managedStatusLineNeedsRepair = managedStatusLineConfigured
            && (!managedStatusLineInstalled || managedStatusLineIsPoisoned)

        return ClaudeStatusLineInstallationStatus(
            claudeDirectory: claudeDirectory,
            settingsURL: settingsURL,
            scriptDirectoryURL: scriptDirectoryURL,
            scriptURL: scriptURL,
            cacheURL: Self.managedCacheURL,
            statusLineCommand: command,
            hasStatusLine: hasStatusLine,
            managedStatusLineConfigured: managedStatusLineConfigured,
            managedStatusLineInstalled: managedStatusLineInstalled,
            managedStatusLineNeedsRepair: managedStatusLineNeedsRepair,
            hasConflictingStatusLine: hasConflictingStatusLine,
            managedStatusLineIsWrapper: managedStatusLineIsWrapper,
            managedStatusLineIsPoisoned: managedStatusLineIsPoisoned
        )
    }

    /// Whether `command` executes one of Open Island's own status-line scripts.
    ///
    /// Tolerates the spellings a user, an older installer, or a shell may have written:
    /// `~/…`, `$HOME/…`, `${HOME}/…`, quoting, and an interpreter prefix such as
    /// `bash /path/open-island-statusline`.
    public func isManagedStatusLineCommand(_ command: String?) -> Bool {
        managedScriptPath(referencedBy: command) != nil
    }

    /// The path of the managed script that `command` runs, or `nil` when the command is
    /// not ours. A bare script name (resolved through `PATH`) maps to the current install
    /// location so the caller can still check whether the file exists.
    private func managedScriptPath(referencedBy command: String?) -> String? {
        guard let command, !command.isEmpty else { return nil }
        let managedPaths = Set(
            [
                scriptDirectoryURL.appendingPathComponent(Self.managedScriptName),
                scriptDirectoryURL.appendingPathComponent(Self.wrappedDelegateScriptName),
                legacyScriptDirectoryURL.appendingPathComponent(Self.legacyManagedScriptName),
            ].map { $0.standardizedFileURL.path }
        )
        for rawToken in command.split(whereSeparator: \.isWhitespace) {
            let token = rawToken.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            guard !token.isEmpty else { continue }
            let expanded = expandingHome(in: token)
            if Self.managedScriptNames.contains(expanded) {
                return scriptDirectoryURL.appendingPathComponent(expanded).path
            }
            guard expanded.contains("/") else { continue }
            let url = URL(fileURLWithPath: expanded).standardizedFileURL
            if managedPaths.contains(url.path) || Self.managedScriptNames.contains(url.lastPathComponent) {
                return url.path
            }
        }
        return nil
    }

    private func expandingHome(in token: String) -> String {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? fileManager.homeDirectoryForCurrentUser.path
        if token == "~" { return home }
        for prefix in ["~/", "${HOME}/", "$HOME/"] where token.hasPrefix(prefix) {
            return home + "/" + token.dropFirst(prefix.count)
        }
        return token
    }

    /// `true` when the delegate script on disk would run one of our managed scripts —
    /// the corrupted state from issue #671 where the delegate points back at the wrapper.
    private func delegateScriptRunsManagedScript(at delegateScriptURL: URL) -> Bool {
        guard let contents = try? String(contentsOf: delegateScriptURL, encoding: .utf8) else {
            return false
        }
        return contents.split(whereSeparator: \.isNewline).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return !trimmed.isEmpty && !trimmed.hasPrefix("#") && isManagedStatusLineCommand(trimmed)
        }
    }

    @discardableResult
    public func install() throws -> ClaudeStatusLineInstallationStatus {
        let currentStatus = try status()
        if currentStatus.hasConflictingStatusLine {
            throw ClaudeStatusLineInstallationError.existingStatusLineConflict(
                command: currentStatus.statusLineCommand
            )
        }

        try fileManager.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scriptDirectoryURL, withIntermediateDirectories: true)

        let settingsURL = currentStatus.settingsURL
        let scriptURL = currentStatus.scriptURL
        let delegateScriptURL = scriptDirectoryURL.appendingPathComponent(Self.wrappedDelegateScriptName)
        let existingSettings = try loadSettings(at: settingsURL)
        var mutatedSettings = existingSettings
        mutatedSettings["statusLine"] = managedStatusLine(for: scriptURL)

        // A saved original that runs our own script is the issue #671 corruption: the
        // user's real command is already lost, and re-wrapping it would spawn forever.
        // Drop it and fall back to the plain managed script. A healthy saved original is
        // kept and its wrapper rebuilt, so repairing never orphans the user's status line.
        var preservedOriginalCommand: String?
        if let savedOriginal = mutatedSettings[openIslandOriginalStatusLineKey] {
            let savedCommand = (savedOriginal as? [String: Any])?["command"] as? String
            if let savedCommand, !savedCommand.isEmpty, !isManagedStatusLineCommand(savedCommand) {
                preservedOriginalCommand = savedCommand
            } else {
                mutatedSettings.removeValue(forKey: openIslandOriginalStatusLineKey)
            }
        }

        let settingsData = try serializeSettings(mutatedSettings)
        if fileManager.fileExists(atPath: settingsURL.path) {
            try backupFile(at: settingsURL)
        }

        try settingsData.write(to: settingsURL, options: .atomic)
        if let preservedOriginalCommand {
            try writeWrapperScripts(
                scriptURL: scriptURL,
                delegateScriptURL: delegateScriptURL,
                cacheURL: currentStatus.cacheURL,
                originalCommand: preservedOriginalCommand
            )
        } else {
            let scriptContents = Self.managedScript(cacheURL: currentStatus.cacheURL)
            try scriptContents.write(to: scriptURL, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
            if fileManager.fileExists(atPath: delegateScriptURL.path) {
                try fileManager.removeItem(at: delegateScriptURL)
            }
        }
        let legacyScriptURL = legacyScriptDirectoryURL.appendingPathComponent(Self.legacyManagedScriptName)
        if fileManager.fileExists(atPath: legacyScriptURL.path) {
            try fileManager.removeItem(at: legacyScriptURL)
        }

        return try status()
    }

    /// Install in "wrap mode": keep the user's existing statusLine command working,
    /// but prepend our cache-writing shim. The original command is saved under
    /// `_openIslandOriginalStatusLine` so `uninstall()` can restore it verbatim.
    @discardableResult
    public func installAsWrapper() throws -> ClaudeStatusLineInstallationStatus {
        let currentStatus = try status()
        guard currentStatus.hasConflictingStatusLine,
              let originalCommand = currentStatus.statusLineCommand,
              !originalCommand.isEmpty
        else {
            throw ClaudeStatusLineInstallationError.wrappableCommandMissing
        }
        // `status()` already excludes our own scripts from "conflicting" commands; keep an
        // explicit guard here so the two can never drift apart and wrap the wrapper.
        guard !isManagedStatusLineCommand(originalCommand) else {
            throw ClaudeStatusLineInstallationError.wrapperWouldRecurse(command: originalCommand)
        }

        try fileManager.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: scriptDirectoryURL, withIntermediateDirectories: true)

        let settingsURL = currentStatus.settingsURL
        let scriptURL = currentStatus.scriptURL
        let delegateScriptURL = scriptDirectoryURL.appendingPathComponent(Self.wrappedDelegateScriptName)
        var mutatedSettings = try loadSettings(at: settingsURL)

        // Preserve the user's original statusLine dict so uninstall can restore it verbatim.
        if let originalStatusLine = mutatedSettings["statusLine"] {
            mutatedSettings[openIslandOriginalStatusLineKey] = originalStatusLine
        }
        mutatedSettings["statusLine"] = managedStatusLine(for: scriptURL)

        let settingsData = try serializeSettings(mutatedSettings)
        if fileManager.fileExists(atPath: settingsURL.path) {
            try backupFile(at: settingsURL)
        }

        try settingsData.write(to: settingsURL, options: .atomic)
        try writeWrapperScripts(
            scriptURL: scriptURL,
            delegateScriptURL: delegateScriptURL,
            cacheURL: currentStatus.cacheURL,
            originalCommand: originalCommand
        )

        return try status()
    }

    private func writeWrapperScripts(
        scriptURL: URL,
        delegateScriptURL: URL,
        cacheURL: URL,
        originalCommand: String
    ) throws {
        let wrapperContents = Self.wrappedScript(cacheURL: cacheURL, delegateScriptURL: delegateScriptURL)
        let delegateContents = Self.wrappedDelegateScript(originalCommand: originalCommand)
        try wrapperContents.write(to: scriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        try delegateContents.write(to: delegateScriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: delegateScriptURL.path)
    }

    @discardableResult
    public func uninstall() throws -> ClaudeStatusLineInstallationStatus {
        let currentStatus = try status()
        let settingsURL = currentStatus.settingsURL
        let scriptURL = currentStatus.scriptURL
        let delegateScriptURL = scriptDirectoryURL.appendingPathComponent(Self.wrappedDelegateScriptName)

        if currentStatus.managedStatusLineConfigured {
            var settings = try loadSettings(at: settingsURL)
            // Restore the user's original statusLine when we were running in wrapper mode.
            if let savedOriginal = settings[openIslandOriginalStatusLineKey] {
                let savedCommand = (savedOriginal as? [String: Any])?["command"] as? String
                if isManagedStatusLineCommand(savedCommand) {
                    // The backup points at our own script (issue #671); restoring it would
                    // leave Claude Code running a deleted wrapper. Clear the status line instead.
                    settings.removeValue(forKey: "statusLine")
                } else {
                    settings["statusLine"] = savedOriginal
                }
                settings.removeValue(forKey: openIslandOriginalStatusLineKey)
            } else {
                settings.removeValue(forKey: "statusLine")
            }
            if fileManager.fileExists(atPath: settingsURL.path) {
                try backupFile(at: settingsURL)
            }
            let settingsData = try serializeSettings(settings)
            try settingsData.write(to: settingsURL, options: .atomic)
        }

        if fileManager.fileExists(atPath: scriptURL.path) {
            try fileManager.removeItem(at: scriptURL)
        }
        if fileManager.fileExists(atPath: delegateScriptURL.path) {
            try fileManager.removeItem(at: delegateScriptURL)
        }
        let legacyScriptURL = legacyScriptDirectoryURL.appendingPathComponent(Self.legacyManagedScriptName)
        if fileManager.fileExists(atPath: legacyScriptURL.path) {
            try fileManager.removeItem(at: legacyScriptURL)
        }

        return try status()
    }

    private func loadSettings(at url: URL) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else {
            return [:]
        }

        let data = try Data(contentsOf: url)
        let object = try JSONSerialization.jsonObject(with: data)
        guard let settings = object as? [String: Any] else {
            throw ClaudeStatusLineInstallationError.invalidSettingsRoot
        }
        return settings
    }

    private func serializeSettings(_ settings: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
    }

    private func managedStatusLine(for scriptURL: URL) -> [String: Any] {
        [
            "type": "command",
            "command": scriptURL.path,
            "padding": 2,
        ]
    }

    private func backupFile(at url: URL) throws {
        guard fileManager.fileExists(atPath: url.path) else {
            return
        }

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timestamp = formatter.string(from: .now).replacingOccurrences(of: ":", with: "-")
        let backupURL = url.appendingPathExtension("backup.\(timestamp)")
        if fileManager.fileExists(atPath: backupURL.path) {
            try fileManager.removeItem(at: backupURL)
        }
        try fileManager.copyItem(at: url, to: backupURL)
    }

    /// The wrapper script executed as Claude Code's `statusLine.command` in wrap mode.
    /// It reads stdin once, writes `.rate_limits` to the cache (best-effort), then forwards
    /// the same stdin to the delegate script which runs the user's original command.
    /// The delegate's stdout is what Claude Code displays, so the user's custom statusLine
    /// is unchanged visually — we're just teeing the payload to the cache file.
    public static func wrappedScript(cacheURL: URL, delegateScriptURL: URL) -> String {
        #"""
        #!/bin/bash
        # Claude Code StatusLine Script (wrapper mode)
        # Auto-configured by Open Island.
        # The delegate script holds the user's original statusLine.command.
        # Keep the rate_limits cache line intact — it feeds the notch usage panel.
        # The re-entry guard stops a delegate that loops back here from forking forever.
        if [ -n "$OPEN_ISLAND_STATUSLINE_ACTIVE" ]; then exit 0; fi
        export OPEN_ISLAND_STATUSLINE_ACTIVE=1
        input=$(cat)
        _rl=$(printf '%s' "$input" | jq -c '.rate_limits // empty' 2>/dev/null)
        [ -n "$_rl" ] && printf '%s\n' "$_rl" > "\#(cacheURL.path)"
        printf '%s' "$input" | "\#(delegateScriptURL.path)"
        """#
    }

    /// The delegate script. Written verbatim — `originalCommand` is a shell command string
    /// from `settings.json`, so embedding it as a script body runs with identical semantics
    /// without the escaping problems of `bash -c "$ORIG"`.
    public static func wrappedDelegateScript(originalCommand: String) -> String {
        "#!/bin/bash\n# Original Claude Code statusLine.command preserved by Open Island.\n\(originalCommand)\n"
    }

    public static func managedScript(cacheURL: URL = managedCacheURL) -> String {
        #"""
        #!/bin/bash
        # Claude Code StatusLine Script
        # Auto-configured by Open Island
        # FOR AI ASSISTANTS EDITING THIS FILE:
        # This script receives JSON from Claude Code via stdin on
        # every assistant message. The user wants to customize their
        # status line display, so please ADD your code to this file.
        # Do NOT create a separate script or change statusLine.command.
        # IMPORTANT: Keep the rate_limits cache line below intact.
        # It feeds usage data (5h/7d quotas) to the Open Island
        # Notch panel. Removing it will degrade the usage display.
        input=$(cat)
        _rl=$(echo "$input" | jq -c '.rate_limits // empty' 2>/dev/null)
        [ -n "$_rl" ] && printf '%s\n' "$_rl" > "\#(cacheURL.path)"
        echo "$input" | jq -r '"[\(.model.display_name // "Claude")] \(.context_window.used_percentage // 0)% context"' 2>/dev/null
        """#
    }
}
