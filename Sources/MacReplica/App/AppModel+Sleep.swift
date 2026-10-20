import MacReplicaCore

extension AppModel {
    /// The long operation running right now, if any. Screens that show work in progress (not results, not waiting
    /// for the user) count; so do the installer tool's download, copy and writing.
    var runningOperation: LongOperation? {
        switch screen {
        case .scanning: return .inventory
        case .savingBackup: return .backup
        case .verifying: return .verification
        case .restoring: return .restore
        case .installMedia:
            if installMedia.step == .working { return .installerWrite }
            if installMedia.copying { return .installerCopy }
            if installMedia.downloading { return .installerDownload }
            return nil
        default: return nil
        }
    }

    func updateSleepPrevention() {
        let operation = runningOperation
        sleepPrevention.update(operation, reason: operation.map { l.t("sleep.reason.\($0.rawValue)") } ?? "")
    }
}
