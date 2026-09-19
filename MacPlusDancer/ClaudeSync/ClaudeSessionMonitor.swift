//
//  ClaudeSessionMonitor.swift
//  MacPlusDancer
//

import Darwin
import Foundation
import Observation

enum ClaudeSessionState: String {
    /// Claude is producing a response or running a tool.
    case working
    /// Claude is blocked on the user.
    case waiting
    /// Claude finished its turn and nobody is waiting on anybody.
    case idle
}

/// Why a session is blocked, which decides whether the block can be trusted to
/// end on its own. See ``ClaudeSessionMonitor/permissionGrace``.
enum ClaudeWaitReason: String {
    /// A permission prompt is on screen. Nothing tells us when it is answered.
    case permission
    /// A question, elicitation or quota block is on screen. Cleared exactly,
    /// by the `PostToolUse` of the tool that asked it, or by the next prompt.
    case question
}

/// What a working session is in the middle of, which sets how long it may
/// stay silent before the silence means it was interrupted.
enum ClaudeSessionPhase: String {
    /// Thinking or streaming a reply, which emits `MessageDisplay` steadily.
    case turn
    /// A tool is in flight and may legitimately run for minutes in silence.
    case tool
}

struct ClaudeSession: Identifiable, Hashable {
    let id: String
    let state: ClaudeSessionState
    let reason: ClaudeWaitReason?
    let phase: ClaudeSessionPhase
    let pid: pid_t
    let updatedAt: Date
    /// Set when the transcript grew after the last hook fired, which only
    /// happens when something went unreported: the turn was interrupted.
    let interrupted: Bool
}

/// Watches the state files written by the hook script that
/// ``ClaudeHookInstaller`` installs, and boils every live Claude Code session
/// down to a single answer: should the dancer be dancing?
@Observable
final class ClaudeSessionMonitor {
    enum Activity: Equatable {
        case noSessions
        case idle
        case working
        case needsAttention
    }

    /// Claude Code fires no hook when a permission prompt is answered, so a
    /// prompt still standing after this long is assumed to have been approved
    /// and to be running the tool it was asking about. Anything else the user
    /// has to answer is bracketed by real events and never decays.
    static let permissionGrace: TimeInterval = 20

    /// The real home directory. `NSHomeDirectory()` would do, but this keeps
    /// working if the app is ever put back in a sandbox container.
    static var homeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir))
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static var stateDirectory: URL {
        homeDirectory.appendingPathComponent(".claude/macplusdancer/sessions", isDirectory: true)
    }

    private(set) var sessions: [ClaudeSession] = []
    private(set) var isWatching = false

    private var directorySource: DispatchSourceFileSystemObject?
    private var refreshTimer: Timer?

    /// Pressing Esc fires no hook whatsoever, so an interrupted turn is only
    /// visible as silence. While Claude is thinking or streaming it emits
    /// `MessageDisplay` roughly every second, so this much quiet means the
    /// turn is over. Overshooting only pauses the dancer until the next beat.
    private let interruptTimeout: TimeInterval = 15
    /// A tool in flight emits nothing at all and a build may legitimately run
    /// for minutes, so silence is only suspicious after much longer.
    private let toolTimeout: TimeInterval = 10 * 60
    /// A normally finishing tool writes its result to the transcript a moment
    /// before `PostToolUse` fires, so ignore that much overlap.
    private static let transcriptGrace: TimeInterval = 3
    /// Backstop for deleting the file of a session that is genuinely gone.
    private let absoluteTimeout: TimeInterval = 24 * 60 * 60

    /// What a session counts as right now. Two states are read through a
    /// clock rather than taken at face value: a permission prompt nobody told
    /// us was answered, and a turn nobody told us was interrupted.
    func effectiveState(of session: ClaudeSession, at now: Date = Date()) -> ClaudeSessionState {
        let age = now.timeIntervalSince(session.updatedAt)
        switch session.state {
        case .waiting:
            guard session.reason == .permission else { return .waiting }
            return age > Self.permissionGrace ? .working : .waiting
        case .working:
            if session.interrupted { return .idle }
            let limit = session.phase == .tool ? toolTimeout : interruptTimeout
            return age > limit ? .idle : .working
        case .idle:
            return .idle
        }
    }

    var activity: Activity {
        let now = Date()
        let states = sessions.map { effectiveState(of: $0, at: now) }
        if states.isEmpty { return .noSessions }
        if states.contains(.waiting) { return .needsAttention }
        if states.contains(.working) { return .working }
        return .idle
    }

    var shouldDance: Bool { activity == .working }

    var statusDescription: String {
        let now = Date()
        let states = sessions.map { effectiveState(of: $0, at: now) }
        func phrase(_ count: Int, _ tail: String) -> String {
            "\(count) \(count == 1 ? "session" : "sessions") \(tail)"
        }
        switch activity {
        case .noSessions:
            return "No Claude sessions"
        case .needsAttention:
            let count = states.filter { $0 == .waiting }.count
            return "\(count) \(count == 1 ? "session needs" : "sessions need") you"
        case .working:
            return phrase(states.filter { $0 == .working }.count, "working")
        case .idle:
            return phrase(states.count, "idle")
        }
    }

    func start() {
        guard !isWatching else { return }
        isWatching = true

        try? FileManager.default.createDirectory(at: Self.stateDirectory, withIntermediateDirectories: true)
        startWatchingDirectory()

        // Also drives the permission grace period, which expires on a clock
        // rather than on an event.
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            self?.reload()
        }
        RunLoop.main.add(timer, forMode: .common)
        refreshTimer = timer

        reload()
    }

    func stop() {
        guard isWatching else { return }
        isWatching = false

        directorySource?.cancel()
        directorySource = nil
        refreshTimer?.invalidate()
        refreshTimer = nil
        sessions = []
    }

    deinit {
        directorySource?.cancel()
        refreshTimer?.invalidate()
    }

    // MARK: - Watching

    /// The hook script renames its temp file into place, so every state change
    /// shows up as a write to the directory itself, not just to a file in it.
    private func startWatchingDirectory() {
        let descriptor = open(Self.stateDirectory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            self?.reload()
        }
        source.setCancelHandler {
            close(descriptor)
        }
        source.resume()
        directorySource = source
    }

    private func reload() {
        let directory = Self.stateDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []

        let now = Date()
        var found: [ClaudeSession] = []

        for file in files where file.pathExtension == "json" {
            guard let session = Self.readSession(at: file) else { continue }

            let age = now.timeIntervalSince(session.updatedAt)
            if age > absoluteTimeout || !Self.isProcessAlive(session.pid) {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            found.append(session)
        }

        found.sort { $0.id < $1.id }
        if found != sessions {
            sessions = found
        }
    }

    private static func readSession(at url: URL) -> ClaudeSession? {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["session_id"] as? String,
              let rawState = object["state"] as? String,
              let state = ClaudeSessionState(rawValue: rawState),
              let updatedAt = object["updated_at"] as? TimeInterval
        else { return nil }

        let pid = (object["pid"] as? Int).map { pid_t($0) } ?? 0
        let updated = Date(timeIntervalSince1970: updatedAt)
        return ClaudeSession(
            id: id,
            state: state,
            reason: (object["reason"] as? String).flatMap(ClaudeWaitReason.init(rawValue:)),
            phase: (object["phase"] as? String).flatMap(ClaudeSessionPhase.init(rawValue:)) ?? .turn,
            pid: pid,
            updatedAt: updated,
            interrupted: wasInterrupted(transcript: object["transcript"] as? String, since: updated)
        )
    }

    /// Claude Code writes an interrupt into the transcript but fires no hook
    /// for it, and leaves the transcript untouched for as long as a tool runs.
    /// So a transcript newer than the last hook means the turn ended unseen.
    private static func wasInterrupted(transcript: String?, since: Date) -> Bool {
        guard let transcript, !transcript.isEmpty,
              let attributes = try? FileManager.default.attributesOfItem(atPath: transcript),
              let modified = attributes[.modificationDate] as? Date
        else { return false }
        return modified.timeIntervalSince(since) > transcriptGrace
    }

    /// `ESRCH` is the only answer that proves the process is gone; `EPERM`
    /// means it exists but belongs to somebody else, so treat it as alive.
    private static func isProcessAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return true }
        if kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }
}
