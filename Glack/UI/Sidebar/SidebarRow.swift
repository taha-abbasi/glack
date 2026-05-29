import SwiftUI

struct SidebarRow: View {
    let space: SpaceRecord

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(name)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
    }

    private var icon: String {
        switch space.type {
        case .directMessage: return "person.crop.circle"
        case .groupChat:     return "person.2"
        case .space, .unknown: return "number"
        }
    }

    private var name: String {
        if let dn = space.displayName, !dn.isEmpty { return dn }
        switch space.type {
        case .directMessage: return "Direct Message"
        case .groupChat:     return "Group Chat"
        default:             return space.id
        }
    }
}
