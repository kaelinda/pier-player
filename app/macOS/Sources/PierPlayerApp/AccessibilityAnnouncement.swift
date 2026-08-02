import AppKit

@MainActor
enum AccessibilityAnnouncement {
    static func post(_ message: String, priority: NSAccessibilityPriorityLevel = .high) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: message,
                .priority: priority.rawValue,
            ]
        )
    }
}
