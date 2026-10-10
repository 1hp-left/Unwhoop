import Foundation
import SwiftData

/// Singleton-ish record of band link state. The app keeps at most one row;
/// the sync pipeline upserts it.
@Model
final class SyncState {
    @Attribute(.unique) var id: UUID

    var deviceName: String?
    var deviceUUID: String?
    var lastSync: Date?
    var batteryPercent: Int?
    var connectionRaw: String // ConnectionState raw value

    init(
        deviceName: String? = nil,
        deviceUUID: String? = nil,
        lastSync: Date? = nil,
        batteryPercent: Int? = nil,
        connectionRaw: String = ConnectionState.disconnected.rawValue
    ) {
        self.id = UUID()
        self.deviceName = deviceName
        self.deviceUUID = deviceUUID
        self.lastSync = lastSync
        self.batteryPercent = batteryPercent
        self.connectionRaw = connectionRaw
    }
}
