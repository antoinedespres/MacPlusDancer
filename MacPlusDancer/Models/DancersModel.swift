//
//  DancersModel.swift
//  MacPlusDancer
//
//  Created by Sam Gold on 2024-10-18.
//

import Foundation
import Observation

/// A model that manages the list of dancers and the selected dancer state.
@Observable
class DancersModel {
    private static let claudeSyncKey = "followsClaudeCodeSessions"

    var dancers: [Dancer] = []
    var selectedDancer: Dancer?
    var isDancing: Bool = true

    let claudeMonitor = ClaudeSessionMonitor()
    private(set) var claudeSyncEnabled: Bool = false
    private(set) var claudeSyncError: String?

    var toggleDancerButtonLabel: String {
        isDancing ? "Stop Dancing" : "Start Dancing"
    }

    /// Whether the dancer should be on screen right now. Seth may not be
    /// stopped by hand, but Claude Code outranks him.
    var shouldDance: Bool {
        if claudeSyncEnabled { return claudeMonitor.shouldDance }
        if selectedDancer?.name == "Seth" { return true }
        return isDancing
    }

    var isThereALittleDancerOnScreenAtThisVeryMoment: Bool {
        selectedDancer != nil && shouldDance
    }

    var claudeSyncStatus: String {
        if let claudeSyncError { return claudeSyncError }
        return claudeMonitor.statusDescription
    }

    var groupedDancers: [String: [Dancer]] {
        Dictionary(grouping: dancers, by: { $0.group ?? "Unknown" })
    }

    init() {
        loadDancers()

        if UserDefaults.standard.bool(forKey: Self.claudeSyncKey) {
            setClaudeSyncEnabled(true)
        }
    }

    func loadDancers() {
        guard let url = Bundle.main.url(forResource: "Metadata", withExtension: "json") else {
            print("Metadata.json not found in bundle")
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoder = JSONDecoder()
            let dancersData = try decoder.decode(DancersData.self, from: data)
            dancers = dancersData.dancers.sorted { $0.name < $1.name }
            selectedDancer = dancers.first
        } catch {
            print("Failed to load or parse Metadata.json: \(error)")
        }
    }

    /// Installs or removes the Claude Code hooks and starts or stops watching
    /// for session activity. Leaves the setting off if either half fails.
    func setClaudeSyncEnabled(_ enabled: Bool) {
        claudeSyncError = nil
        do {
            if enabled {
                if !ClaudeHookInstaller.isUpToDate {
                    try ClaudeHookInstaller.install()
                }
                claudeMonitor.start()
            } else {
                claudeMonitor.stop()
                try ClaudeHookInstaller.uninstall()
            }
            claudeSyncEnabled = enabled
        } catch {
            claudeMonitor.stop()
            claudeSyncEnabled = false
            claudeSyncError = error.localizedDescription
        }
        UserDefaults.standard.set(claudeSyncEnabled, forKey: Self.claudeSyncKey)
    }
}
