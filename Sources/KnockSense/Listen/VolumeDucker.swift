import Foundation

/// Temporarily lowers the system volume and puts it back afterwards. Several reasons can hold the
/// volume down at once ("someone is talking", "your name was heard"); it is restored when the last
/// one lets go, and only if the user hasn't changed the volume in the meantime.
@MainActor
final class VolumeDucker {
    private var saved: GuardSystem.VolumeState?
    private var duckedLevel: Int?
    private var holders = Set<String>()
    private var releaseTasks: [String: Task<Void, Never>] = [:]

    func duck(_ reason: String, fraction: Double) {
        releaseTasks[reason]?.cancel()
        releaseTasks[reason] = nil
        holders.insert(reason)
        if saved == nil { saved = GuardSystem.currentVolume() }
        guard let saved, !saved.muted, saved.level > 0 else { return }
        let target = max(2, Int((Double(saved.level) * fraction).rounded()))
        if duckedLevel == nil || target < duckedLevel! {
            duckedLevel = target
            GuardSystem.setVolume(.init(level: target, muted: false))
        }
    }

    func release(_ reason: String, after seconds: Double) {
        guard holders.contains(reason) else { return }
        releaseTasks[reason]?.cancel()
        releaseTasks[reason] = Task { @MainActor [weak self] in
            if seconds > 0 { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
            guard !Task.isCancelled, let self else { return }
            self.holders.remove(reason)
            self.releaseTasks[reason] = nil
            guard self.holders.isEmpty else { return }
            if let saved = self.saved, let ducked = self.duckedLevel,
               let current = GuardSystem.currentVolume(), abs(current.level - ducked) <= 3, !current.muted {
                GuardSystem.setVolume(saved)
            }
            self.saved = nil
            self.duckedLevel = nil
        }
    }
}
