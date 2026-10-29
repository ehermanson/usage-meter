import CompanionKit
import SwiftUI
import VisionKit

struct ConnectionSheet: View {
    let store: CompanionStore
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var scanning = false
    @State private var connecting = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(
                        "Open Connect iPhone in the Mac menu-bar app and enable iCloud sync. Both devices need the same Apple Account."
                    )
                    if DataScannerViewController.isSupported
                        && DataScannerViewController.isAvailable
                    {
                        Button("Scan Mac's QR code", systemImage: "qrcode.viewfinder") {
                            scanning = true
                        }
                    }
                    TextField("Connection link", text: $link)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .keyboardType(.URL)
                    PasteButton(payloadType: String.self) { values in link = values.first ?? "" }
                    Button("Connect") { connect(link) }
                        .disabled(connecting || link.isEmpty)
                    if connecting { ProgressView() }
                } footer: {
                    Text(
                        "The code selects your Mac. Your Apple Account controls access to its private iCloud data."
                    )
                }
                if let message = store.message { Section { Text(message) } }
                Section {
                    Button("Discover Macs instead", systemImage: "desktopcomputer") {
                        Task {
                            await store.refresh(discoverSources: true)
                        }
                    }
                }
                if !store.sources.isEmpty {
                    Section("Available Macs") {
                        ForEach(store.sources) { source in
                            Button(source.sourceName, systemImage: "desktopcomputer") {
                                connect(CompanionLink.url(sourceID: source.sourceID).absoluteString)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Connect Mac")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .sheet(isPresented: $scanning) {
                NavigationStack {
                    QRScanner(
                        onScan: { value in
                            scanning = false; connect(value)
                        },
                        onFailure: {
                            scanning = false
                            store.message =
                                "Camera scanning isn't available. Allow camera access in Settings, or paste the Mac's connection link."
                        }
                    )
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("Scan connection code")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { scanning = false }
                        }
                    }
                }
            }
        }
    }

    private func connect(_ value: String) {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            store.message = CompanionError.invalidLink.localizedDescription
            return
        }
        connecting = true
        Task {
            await store.connect(url)
            connecting = false
            if store.message == nil { dismiss() }
        }
    }
}

struct QRScanner: UIViewControllerRepresentable {
    let onScan: (String) -> Void
    let onFailure: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onScan: onScan, onFailure: onFailure) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced, recognizesMultipleItems: false, isGuidanceEnabled: true,
            isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        if !controller.isScanning {
            do { try controller.startScanning() } catch {
                Task { @MainActor in context.coordinator.fail() }
            }
        }
    }

    static func dismantleUIViewController(
        _ controller: DataScannerViewController, coordinator: Coordinator
    ) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        private let onScan: (String) -> Void
        private let onFailure: () -> Void
        private var scanned = false
        init(onScan: @escaping (String) -> Void, onFailure: @escaping () -> Void) {
            self.onScan = onScan
            self.onFailure = onFailure
        }

        func fail() {
            guard !scanned else { return }
            scanned = true
            onFailure()
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable
        ) {
            fail()
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard !scanned else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let value = barcode.payloadStringValue {
                    scanned = true
                    dataScanner.stopScanning()
                    onScan(value)
                    break
                }
            }
        }
    }
}
