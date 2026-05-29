import SwiftUI

struct MessageRow: View {
    let message: MessageRecord

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            avatar
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(message.senderName ?? "Unknown")
                        .font(.system(size: 13, weight: .semibold))
                    Text(timeString)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Text(message.text ?? "")
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if message.attachmentCount > 0 {
                    Label("\(message.attachmentCount) attachment\(message.attachmentCount == 1 ? "" : "s")", systemImage: "paperclip")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var avatar: some View {
        Circle()
            .fill(Color.accentColor.opacity(0.18))
            .frame(width: 28, height: 28)
            .overlay(
                Text(initials)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.primary)
            )
    }

    private var initials: String {
        let parts = (message.senderName ?? "?").split(separator: " ")
        let first = parts.first?.first.map(String.init) ?? "?"
        let last = parts.dropFirst().first?.first.map(String.init) ?? ""
        return (first + last).uppercased()
    }

    private var timeString: String {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f.string(from: message.createdAt)
    }
}
