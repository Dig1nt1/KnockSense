import Foundation

/// Sends push notifications to the user's phone through ntfy (https://ntfy.sh): a free, open-source
/// push service. The user installs the ntfy app and subscribes to their secret topic name.
enum PhoneAlert {
    /// Returns nil on success, or an error message.
    static func send(topic: String, title: String, message: String, photo: Data? = nil,
                     priority: String = "urgent", tags: String = "rotating_light") async -> String? {
        let name = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }),
              let url = URL(string: "https://ntfy.sh/\(name)") else {
            return "Set up a phone alert topic first."
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        // Header values must be plain ASCII.
        request.setValue(title, forHTTPHeaderField: "Title")
        request.setValue(priority, forHTTPHeaderField: "Priority")
        request.setValue(tags, forHTTPHeaderField: "Tags")
        if let photo {
            request.httpMethod = "PUT"
            request.setValue(message, forHTTPHeaderField: "Message")
            request.setValue("knocksense-guard.jpg", forHTTPHeaderField: "Filename")
            request.httpBody = photo
        } else {
            request.httpMethod = "POST"
            request.httpBody = Data(message.utf8)
        }
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(code) ? nil : "The alert service answered with an error (\(code))."
        } catch {
            return error.localizedDescription
        }
    }
}
