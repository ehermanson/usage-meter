import SwiftUI

private enum ComputerIcon: String, CaseIterable, Identifiable {
    case desktop = "desktopcomputer"
    case laptop = "laptopcomputer"
    case mini = "macmini"
    case pro = "macpro.gen3"
    case server = "server.rack"

    var id: String { rawValue }
    var title: String {
        switch self {
        case .desktop: "Desktop"
        case .laptop: "MacBook"
        case .mini: "Mac mini"
        case .pro: "Mac Pro"
        case .server: "Server"
        }
    }
}

/// Preferences follow the source UUID, so renaming or switching Macs preserves each choice.
struct ComputerIconButton: View {
    let name: String
    @AppStorage private var symbol: String
    @State private var choosing = false

    init(sourceID: UUID, name: String) {
        self.name = name
        _symbol = AppStorage(
            wrappedValue: ComputerIcon.desktop.rawValue,
            "companion.computerIcon.\(sourceID.uuidString)")
    }

    private var selection: ComputerIcon { ComputerIcon(rawValue: symbol) ?? .desktop }

    var body: some View {
        Button {
            choosing = true
        } label: {
            Image(systemName: selection.rawValue).font(.title3)
                .foregroundStyle(.tint).frame(width: 46, height: 46)
                .background(Color.companionCard, in: .rect(cornerRadius: 15))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Change icon for \(name)")
        .accessibilityValue(selection.title)
        .sheet(isPresented: $choosing) {
            NavigationStack {
                List(ComputerIcon.allCases) { icon in
                    Button {
                        symbol = icon.rawValue
                        choosing = false
                    } label: {
                        HStack(spacing: 16) {
                            Image(systemName: icon.rawValue).font(.title2)
                                .frame(width: 40, height: 40)
                            Text(icon.title).foregroundStyle(.primary)
                            Spacer()
                            if icon == selection {
                                Image(systemName: "checkmark").fontWeight(.semibold)
                            }
                        }.padding(.vertical, 6)
                    }
                    .accessibilityAddTraits(icon == selection ? .isSelected : [])
                }
                .navigationTitle("Computer icon")
                .navigationBarTitleDisplayMode(.inline)
                .safeAreaInset(edge: .top) {
                    Text(name).font(.subheadline).foregroundStyle(.secondary)
                        .padding().frame(maxWidth: .infinity)
                }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { choosing = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }
}
