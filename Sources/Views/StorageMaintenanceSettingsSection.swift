import SwiftUI

struct StorageMaintenanceSettingsSection: View {
    @EnvironmentObject var runnerManager: RunnerManager

    private func binding(_ key: WritableKeyPath<StorageMaintenanceSettings, Int>) -> Binding<Int> {
        Binding(
            get: { runnerManager.currentSettings.storageMaintenance[keyPath: key] },
            set: { value in
                var settings = runnerManager.currentSettings
                settings.storageMaintenance[keyPath: key] = value
                runnerManager.updateSettings(settings)
            }
        )
    }

    var body: some View {
        Group {
            Stepper("Minimum Docker free space: \(runnerManager.currentSettings.storageMaintenance.minimumGuestFreeDiskSpaceGB) GB",
                    value: binding(\.minimumGuestFreeDiskSpaceGB), in: 1...500)
            Stepper("Package cache budget: \(runnerManager.currentSettings.storageMaintenance.maxCacheSizeGB) GB",
                    value: binding(\.maxCacheSizeGB), in: 1...500)
            Stepper("Private Docker cache budget: \(runnerManager.currentSettings.storageMaintenance.maxDockerDataSizeGB) GB",
                    value: binding(\.maxDockerDataSizeGB), in: 1...500)
            Stepper("Action cache budget: \(runnerManager.currentSettings.storageMaintenance.maxActionCacheSizeGB) GB",
                    value: binding(\.maxActionCacheSizeGB), in: 1...500)
            Stepper("Cache retention: \(runnerManager.currentSettings.storageMaintenance.cacheMaxAgeDays) days",
                    value: binding(\.cacheMaxAgeDays), in: 1...365)
            Toggle("Trim Supported Local VM Disks", isOn: Binding(
                get: { runnerManager.currentSettings.storageMaintenance.dailyVMTrimEnabled },
                set: { value in
                    var settings = runnerManager.currentSettings
                    settings.storageMaintenance.dailyVMTrimEnabled = value
                    runnerManager.updateSettings(settings)
                }
            ))
            Stepper("VM TRIM interval: \(runnerManager.currentSettings.storageMaintenance.vmTrimIntervalMinutes) minutes",
                    value: binding(\.vmTrimIntervalMinutes), in: StorageMaintenanceSettings.trimIntervalRange)
                .disabled(!runnerManager.currentSettings.storageMaintenance.dailyVMTrimEnabled)
        }
    }
}
