import AppKit
import CoreImage.CIFilterBuiltins
import SwiftUI

@MainActor
final class CompanionWindowController {
    static let shared = CompanionWindowController()
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 430, height: 600),
                styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Connect iPhone"
            window.isReleasedWhenClosed = false
            let hostingView = NSHostingView(rootView: CompanionConnectionView(publisher: .shared))
            hostingView.sizingOptions = [.preferredContentSize]
            window.contentView = hostingView
            window.setContentSize(hostingView.fittingSize)
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

struct CompanionConnectionView: View {
    @Bindable var publisher: CompanionPublisher
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "iphone.and.arrow.forward")
                    .font(.system(size: 28)).foregroundStyle(.blue).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your usage, on iPhone").font(.title3.bold())
                    Text("Use the same Apple Account on both devices.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("Computer name").font(.callout.weight(.medium))
                TextField("Computer name", text: $publisher.sourceName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 6) {
                Toggle(
                    "iCloud sync",
                    isOn: Binding(
                        get: { publisher.enabled }, set: { publisher.setEnabled($0) })
                )
                .toggleStyle(.switch).disabled(publisher.isBusy)
                HStack(spacing: 6) {
                    if publisher.isBusy { ProgressView().controlSize(.mini) }
                    Text(syncStatus).font(.caption).foregroundStyle(.secondary)
                }
                if let message = publisher.message {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(.primary.opacity(0.035), in: .rect(cornerRadius: 10))

            if publisher.enabled {
                VStack(spacing: 10) {
                    Text("Scan with Usage Meter on iPhone")
                        .font(.callout.weight(.semibold))
                    if let image = qrImage {
                        Image(nsImage: image).interpolation(.none).resizable()
                            .frame(width: 156, height: 156).padding(12).background(.white)
                            .clipShape(.rect(cornerRadius: 8))
                            .accessibilityLabel(
                                "Scan this code in Usage Meter on iPhone to select this Mac")
                    }
                    Text("Tap Connect Mac in the iPhone app.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Copy connection link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(
                            publisher.connectionURL.absoluteString, forType: .string)
                    }
                }.frame(maxWidth: .infinity)
            } else {
                Text("Enable sync to connect your iPhone and share usage summaries.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            Text(
                "Only summaries sync. Credentials and session logs stay on this Mac. Fresh readings require this Mac to be awake."
            )
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Menu("Manage data…") {
                    Button("Delete this Mac’s cloud data…", role: .destructive) {
                        confirmDelete = true
                    }
                }.fixedSize().disabled(publisher.isBusy || !publisher.configured)
            }
        }
        .padding(24)
        .frame(width: 430)
        .fixedSize(horizontal: false, vertical: true)
        .confirmationDialog("Delete this Mac's cloud snapshot?", isPresented: $confirmDelete) {
            Button("Delete cloud data", role: .destructive) {
                Task { await publisher.deleteCloudData() }
            }
        } message: {
            Text(
                "Sync will stop. Data already cached on your phone can be removed from the phone's settings."
            )
        }
    }

    private var syncStatus: String {
        if publisher.isBusy { return "Syncing usage…" }
        guard publisher.enabled else { return "Sync is off" }
        if let date = publisher.lastUploaded {
            return "Updated \(date.formatted(.relative(presentation: .numeric)))"
        }
        return "Waiting for the first upload"
    }

    private var qrImage: NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(publisher.connectionURL.absoluteString.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage,
            let image = CIContext().createCGImage(
                output.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
                from: output.extent.applying(CGAffineTransform(scaleX: 6, y: 6)))
        else { return nil }
        return NSImage(cgImage: image, size: .zero)
    }
}
