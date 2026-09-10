import Foundation

struct ClaudeTaskNotification: Equatable {
    let taskID: String?
    let toolUseID: String?
    let status: String
}

enum ClaudeTaskNotificationParser {
    private static let terminalStatuses: Set<String> = [
        "completed",
        "failed",
        "cancelled",
        "canceled",
    ]

    static func terminalNotifications(in transcriptObject: [String: Any]) -> [ClaudeTaskNotification] {
        notificationTexts(in: transcriptObject).flatMap(terminalNotifications(in:))
    }

    private static func notificationTexts(in transcriptObject: [String: Any]) -> [String] {
        var texts: [String] = []

        if transcriptObject["type"] as? String == "queue-operation",
           let content = transcriptObject["content"] as? String {
            texts.append(content)
        }

        let origin = transcriptObject["origin"] as? [String: Any]
        guard origin?["kind"] as? String == "task-notification" else {
            return texts
        }

        guard let message = transcriptObject["message"] as? [String: Any] else {
            return texts
        }

        if let content = message["content"] as? String {
            texts.append(content)
        } else if let blocks = message["content"] as? [[String: Any]] {
            texts.append(contentsOf: blocks.compactMap { block in
                guard block["type"] as? String == "text" else { return nil }
                return block["text"] as? String
            })
        }

        return texts
    }

    private static func terminalNotifications(in text: String) -> [ClaudeTaskNotification] {
        let openingTag = "<task-notification>"
        let closingTag = "</task-notification>"
        var notifications: [ClaudeTaskNotification] = []
        var searchStart = text.startIndex

        while let openingRange = text.range(
            of: openingTag,
            range: searchStart..<text.endIndex
        ), let closingRange = text.range(
            of: closingTag,
            range: openingRange.upperBound..<text.endIndex
        ) {
            let body = text[openingRange.upperBound..<closingRange.lowerBound]
            searchStart = closingRange.upperBound

            guard let status = tagValue("status", in: body)?.lowercased(),
                  terminalStatuses.contains(status) else {
                continue
            }

            let taskID = tagValue("task-id", in: body)
            let toolUseID = tagValue("tool-use-id", in: body)
            guard taskID != nil || toolUseID != nil else { continue }

            notifications.append(
                ClaudeTaskNotification(
                    taskID: taskID,
                    toolUseID: toolUseID,
                    status: status
                )
            )
        }

        return notifications
    }

    private static func tagValue(_ tag: String, in body: Substring) -> String? {
        let openingTag = "<\(tag)>"
        let closingTag = "</\(tag)>"
        guard let openingRange = body.range(of: openingTag),
              let closingRange = body.range(
                  of: closingTag,
                  range: openingRange.upperBound..<body.endIndex
              ) else {
            return nil
        }

        let value = body[openingRange.upperBound..<closingRange.lowerBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
