import SwiftUI

struct SidebarView: View {
    @Bindable var observer: SpacesObserver
    @Binding var selection: String?

    var body: some View {
        List(selection: $selection) {
            let groups = grouped(observer.spaces)

            Section("Direct Messages") {
                if groups.dms.isEmpty {
                    Text("No DMs").foregroundStyle(.secondary).font(.footnote)
                } else {
                    ForEach(groups.dms) { space in
                        SidebarRow(space: space).tag(space.id as String?)
                    }
                }
            }

            Section("Spaces") {
                if groups.spaces.isEmpty {
                    Text("No spaces").foregroundStyle(.secondary).font(.footnote)
                } else {
                    ForEach(groups.spaces) { space in
                        SidebarRow(space: space).tag(space.id as String?)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    private struct Grouped {
        var dms: [SpaceRecord]
        var spaces: [SpaceRecord]
    }

    private func grouped(_ all: [SpaceRecord]) -> Grouped {
        var dms: [SpaceRecord] = []
        var spaces: [SpaceRecord] = []
        for s in all {
            switch s.type {
            case .directMessage, .groupChat: dms.append(s)
            case .space, .unknown:           spaces.append(s)
            }
        }
        return Grouped(dms: dms, spaces: spaces)
    }
}
