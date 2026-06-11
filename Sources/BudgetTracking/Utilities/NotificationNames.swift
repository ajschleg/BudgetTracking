import Foundation

extension Notification.Name {
    /// Posted whenever local data changes. Server sync services observe it
    /// to schedule a debounced push; views observe it to reload. (Lived in
    /// SyncEngine.swift until the CloudKit/LAN engines were retired.)
    static let localDataDidChange = Notification.Name("localDataDidChange")
}
