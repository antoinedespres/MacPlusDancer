//
//  ClaudeHookInstaller.swift
//  MacPlusDancer
//

import Foundation

/// Installs (and removes) the Claude Code hooks that report session activity
/// to ``ClaudeSessionMonitor``, by merging entries into the user-level
/// `~/.claude/settings.json`.
enum ClaudeHookInstaller {
    struct Failure: LocalizedError {
        let errorDescription: String?

        init(_ message: String) {
            errorDescription = message
        }
    }

    private struct Binding {
        let event: String
        let matcher: String?
        let arguments: [String]

        init(_ event: String, matcher: String? = nil, _ state: String,
             _ reason: String = "", _ phase: String = "") {
            self.event = event
            self.matcher = matcher
            var args = [state, reason, phase]
            while args.count > 1, args.last == "" { args.removeLast() }
            self.arguments = args
        }
    }

    /// Tools that stop and wait for an answer. Unlike a permission prompt these
    /// bracket cleanly: `PreToolUse` opens the wait, `PostToolUse` ends it.
    private static let blockingTools = "AskUserQuestion|ExitPlanMode"

    private static let bindings: [Binding] = [
        Binding("SessionStart", "idle"),
        Binding("UserPromptSubmit", "working", "", "turn"),
        // Pressing Esc fires nothing, so streaming has to prove it is alive.
        Binding("MessageDisplay", "working", "", "turn"),
        Binding("PreToolUse", matcher: "^(?!(\(blockingTools))$)", "working", "", "tool"),
        Binding("PreToolUse", matcher: blockingTools, "waiting", "question", "turn"),
        // Not "turn": sibling tools in the same batch may still be running.
        Binding("PostToolUse", "working", "", "tool"),
        Binding("PostToolUseFailure", "working", "", "tool"),
        Binding("PostToolBatch", "working", "", "turn"),
        Binding("PermissionRequest", "waiting", "permission", "turn"),
        Binding("Notification", matcher: "permission_prompt", "waiting", "permission", "turn"),
        // A session parked at an empty prompt has stopped, it is not asking
        // anything: treating it as "needs you" would mute every other session.
        Binding("Notification", matcher: "idle_prompt", "idle"),
        Binding("Notification", matcher: "elicitation_.*|quota_.*", "waiting", "question", "turn"),
        Binding("Elicitation", "waiting", "question", "turn"),
        Binding("Stop", "idle"),
        Binding("StopFailure", "idle"),
        Binding("SessionEnd", "end"),
    ]

    static var claudeDirectory: URL {
        ClaudeSessionMonitor.homeDirectory.appendingPathComponent(".claude", isDirectory: true)
    }

    static var supportDirectory: URL {
        claudeDirectory.appendingPathComponent("macplusdancer", isDirectory: true)
    }

    static var hookScriptURL: URL {
        supportDirectory.appendingPathComponent("hook.sh")
    }

    static var settingsURL: URL {
        claudeDirectory.appendingPathComponent("settings.json")
    }

    private static var backupURL: URL {
        claudeDirectory.appendingPathComponent("settings.json.macplusdancer-backup")
    }

    static var isInstalled: Bool {
        guard FileManager.default.isExecutableFile(atPath: hookScriptURL.path) else { return false }
        guard let settings = try? readSettings(),
              let hooks = settings["hooks"] as? [String: Any]
        else { return false }
        return bindings.contains { event in
            let entries = hooks[event.event] as? [[String: Any]] ?? []
            return entries.contains(where: isOurs)
        }
    }

    /// Whether what is on disk is what this build of the app would write. A
    /// newer app has to notice hooks left by an older one, which are still
    /// "installed" but no longer report everything the monitor expects.
    static var isUpToDate: Bool {
        guard isInstalled,
              let script = try? String(contentsOf: hookScriptURL, encoding: .utf8),
              script == hookScript,
              let settings = try? readSettings()
        else { return false }
        let current = settings["hooks"] as? [String: Any] ?? [:]
        return NSDictionary(dictionary: desiredHooks(from: current))
            .isEqual(to: NSDictionary(dictionary: current))
    }

    /// Our entries applied over whatever else the user has configured.
    private static func desiredHooks(from hooks: [String: Any]) -> [String: Any] {
        var result = strippedOfOurs(hooks)
        for binding in bindings {
            var entry: [String: Any] = [
                "hooks": [[
                    "type": "command",
                    "command": hookScriptURL.path,
                    "args": binding.arguments,
                    "timeout": 5,
                ]],
            ]
            if let matcher = binding.matcher {
                entry["matcher"] = matcher
            }
            var entries = result[binding.event] as? [[String: Any]] ?? []
            entries.append(entry)
            result[binding.event] = entries
        }
        return result
    }

    private static func strippedOfOurs(_ hooks: [String: Any]) -> [String: Any] {
        var result = hooks
        for (event, value) in hooks {
            guard let entries = value as? [[String: Any]] else { continue }
            let kept = entries.filter { !isOurs($0) }
            result[event] = kept.isEmpty ? nil : kept
        }
        return result
    }

    static func install() throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
        try hookScript.write(to: hookScriptURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hookScriptURL.path)

        try updateHooks(desiredHooks(from:))
    }

    static func uninstall() throws {
        try updateHooks(strippedOfOurs)
        try? FileManager.default.removeItem(at: supportDirectory)
    }

    // MARK: - settings.json

    /// Strips every entry this app owns, hands the rest to `transform`, and
    /// writes the file back. Everything outside `hooks` is preserved verbatim.
    private static func updateHooks(_ transform: ([String: Any]) -> [String: Any]) throws {
        var settings = try readSettings()
        let hooks = transform(settings["hooks"] as? [String: Any] ?? [:])

        if hooks.isEmpty {
            settings["hooks"] = nil
        } else {
            settings["hooks"] = hooks
        }
        try writeSettings(settings)
    }

    private static func isOurs(_ entry: [String: Any]) -> Bool {
        let commands = entry["hooks"] as? [[String: Any]] ?? []
        return !commands.isEmpty && commands.allSatisfy { $0["command"] as? String == hookScriptURL.path }
    }

    private static func readSettings() throws -> [String: Any] {
        guard FileManager.default.fileExists(atPath: settingsURL.path) else { return [:] }
        let data = try Data(contentsOf: settingsURL)
        guard !data.isEmpty else { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure("\(settingsURL.path) is not a JSON object.")
        }
        return settings
    }

    private static func writeSettings(_ settings: [String: Any]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: settingsURL.path),
           !fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.copyItem(at: settingsURL, to: backupURL)
        }

        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        try (data + Data("\n".utf8)).write(to: settingsURL, options: .atomic)
    }

    // MARK: - Hook script

    private static let hookScript = #"""
    #!/bin/sh
    # Installed by MacPlusDancer. Records the state of the calling Claude Code
    # session so the dancer can follow it. Removing the matching entries from
    # ~/.claude/settings.json is enough to disable it.
    #
    # Usage: hook.sh <working|waiting|idle|end> [reason] [phase]  (payload on stdin)
    set -u

    state="${1:-working}"
    reason="${2:-}"
    phase="${3:-}"
    dir="$HOME/.claude/macplusdancer/sessions"

    session=$(cat \
      | grep -oE '"session_id"[[:space:]]*:[[:space:]]*"[^"]+"' \
      | head -n 1 \
      | sed -E 's/.*"([^"]+)"$/\1/')

    [ -n "$session" ] || exit 0

    # Session ids are UUIDs. Refuse anything that could escape the directory.
    case "$session" in
      *[!A-Za-z0-9_-]*) exit 0 ;;
    esac

    if [ "$state" = "end" ]; then
      rm -f "$dir/$session.json"
      exit 0
    fi

    mkdir -p "$dir" || exit 0

    # $PPID is the claude process itself: hooks are run in exec form, so no
    # shell sits in between. The app uses it to drop files left by a session
    # that was killed before SessionEnd could fire.
    tmp="$dir/.$session.$$"
    printf '{"session_id":"%s","state":"%s","reason":"%s","phase":"%s","pid":%s,"updated_at":%s}\n' \
      "$session" "$state" "$reason" "$phase" "$PPID" "$(date +%s)" > "$tmp" || exit 0

    # Rename so the app sees one atomic write to the directory.
    mv -f "$tmp" "$dir/$session.json"
    exit 0

    """#
}
