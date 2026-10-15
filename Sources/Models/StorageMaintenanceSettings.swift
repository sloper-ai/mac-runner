import Foundation

/// Limits apply between jobs, not while a job writes its caches. Sizes use decimal GB,
/// like minimumFreeDiskSpaceGB. A cache over budget is cold-reset, not partly evicted.
struct StorageMaintenanceSettings: Codable, Sendable, Equatable {
    var minimumGuestFreeDiskSpaceGB: Int = 10
    var cacheMaxAgeDays: Int = 7
    var maxCacheSizeGB: Int = 10
    var maxDockerDataSizeGB: Int = 15
    /// The action archive cache's budget (`ActionArchiveCache`), kept whether or
    /// not automatic maintenance is on: Mac Runner fills that cache itself.
    var maxActionCacheSizeGB: Int = 1
    /// Turns VM TRIM on or off. The name and the `daily-vm-trim` key predate `vmTrimIntervalMinutes`.
    var dailyVMTrimEnabled: Bool = true
    /// Minutes between VM TRIMs. Jobs free tens of GB inside the VM, which the Mac gets back only through TRIM.
    var vmTrimIntervalMinutes: Int = 10

    static let `default` = StorageMaintenanceSettings()
    static let sizeRange = 1...100_000
    static let ageRange = 1...365
    static let trimIntervalRange = 1...1440

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        minimumGuestFreeDiskSpaceGB = Self.size(try values.decodeIfPresent(Int.self, forKey: .minimumGuestFreeDiskSpaceGB) ?? 10)
        cacheMaxAgeDays = min(max(try values.decodeIfPresent(Int.self, forKey: .cacheMaxAgeDays) ?? 7, 1), 365)
        maxCacheSizeGB = Self.size(try values.decodeIfPresent(Int.self, forKey: .maxCacheSizeGB) ?? 10)
        maxDockerDataSizeGB = Self.size(try values.decodeIfPresent(Int.self, forKey: .maxDockerDataSizeGB) ?? 15)
        maxActionCacheSizeGB = Self.size(try values.decodeIfPresent(Int.self, forKey: .maxActionCacheSizeGB) ?? 1)
        dailyVMTrimEnabled = try values.decodeIfPresent(Bool.self, forKey: .dailyVMTrimEnabled) ?? true
        vmTrimIntervalMinutes = min(max(try values.decodeIfPresent(Int.self, forKey: .vmTrimIntervalMinutes) ?? 10,
                                        Self.trimIntervalRange.lowerBound), Self.trimIntervalRange.upperBound)
    }

    static func size(_ value: Int) -> Int { min(max(value, 1), sizeRange.upperBound) }
    static func bytes(_ gb: Int) -> Int64 { Int64(size(gb)) * 1_000_000_000 }
}

struct StorageMaintenanceError: LocalizedError, Equatable {
    let message: String
    var errorDescription: String? { message }
}

/// Unknown capacity is a failed check, not permission to register a runner.
enum StorageAdmission {
    static func check(bytes: Int64?, minimumGB: Int, filesystem: String) throws {
        guard let bytes, bytes >= 0 else {
            throw StorageMaintenanceError(message: "Cannot measure free space on \(filesystem).")
        }
        guard bytes >= StorageMaintenanceSettings.bytes(minimumGB) else {
            let free = String(format: "%.1f", Double(bytes) / 1_000_000_000)
            throw StorageMaintenanceError(message: "\(filesystem) has \(free) GB free; requires \(minimumGB) GB.")
        }
    }
}
