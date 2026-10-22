import Foundation

struct EPGEvent: Codable {
    let id: UUID
    let serviceSlug: String
    let startTime: Date
    let durationSecs: Int
    let title: String?
    let description: String?
    let language: String?

    var stopTime: Date { startTime.addingTimeInterval(TimeInterval(durationSecs)) }
    var isCurrentlyAiring: Bool {
        let now = Date.now
        return startTime <= now && stopTime > now
    }
}
