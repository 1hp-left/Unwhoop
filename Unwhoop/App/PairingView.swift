import SwiftUI
import SwiftData
import Combine

// MARK: - PairingView
//
// Pairing: system Bluetooth permission → scan → select band → confirm.
// Failure states: band not found (checklist), Bluetooth off (deep link).
// On success: the one-time WHOOP-app warning, shown ONCE ever (PRD §7).

struct PairingView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Query private var settingsRows: [AppSettings]

    @State private var cancellables = Set<AnyCancellable>()
    @State private var discovered: [BandDevice] = []
    @State private var showWarning = false

    private var settings: AppSettings? { settingsRows.first }

    var body: some View {
        VStack(spacing: 20) {
            switch appState.pairingPhase {
            case .idle:
                PairingIdle(onStart: startScan)
            case .requestingPermission, .scanning:
                PairingScanning(devices: discovered, onSelect: connect)
            case .connecting(let device):
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Connecting to \(device.name)…")
                        .foregroundStyle(.secondary)
                }
            case .pairing:
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Pairing…")
                    Text("If your iPhone shows a Bluetooth pairing request, tap Pair to finish.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Cancel") {
                        appState.cancelPairing()
                    }
                    .buttonStyle(.bordered)
                }
            case .needsPairingMode:
                PairingNeedsPairingMode(onRetry: startScan)
            case .failed(let reason):
                PairingFailed(reason: reason, onRetry: startScan)
            }

            Spacer()
        }
        .padding()
        .navigationTitle("Pair your band")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            guard cancellables.isEmpty else { return }
            appState.cancelPairing()
            subscribe()
        }
        .onDisappear {
            cancellables.removeAll()
        }
        .alert("One important rule", isPresented: $showWarning) {
            Button("Got it", action: completePairing)
        } message: {
            Text("Never open the official WHOOP app against this band while using Unwhoop. A firmware push from WHOOP's app can permanently break third-party sync. Pick one app per band.")
        }
    }

    private func subscribe() {
        appState.sync.discoveredBands
            .receive(on: DispatchQueue.main)
            .sink { discovered = $0 }
            .store(in: &cancellables)

        appState.sync.connectionState
            .receive(on: DispatchQueue.main)
            .sink { state in
                switch state {
                case .connected:
                    guard appState.acceptPairingConnection() else { return }
                    if let settings, !settings.pairingWarningShown {
                        showWarning = true
                    } else {
                        completePairing()
                    }
                case .pairing:
                    appState.pairingPhase = .pairing
                case .needsPairingMode:
                    appState.pairingPhase = .needsPairingMode
                case .invalidInstallation:
                    appState.pairingPhase = .failed("This installation is missing its Bluetooth permission text. Install the latest Unwhoop IPA over this app to keep your data.")
                case .outOfRange:
                    appState.pairingPhase = .failed("Could not connect to the band. Keep it nearby and try again.")
                case .disconnected:
                    if appState.pairingDevice != nil && !appState.pairingHandshakeComplete {
                        appState.pairingPhase = .failed("The band disconnected before pairing finished. Put it in pairing mode and try again.")
                    }
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func startScan() {
        guard appState.sync.connectionState.value != .invalidInstallation else {
            appState.pairingPhase = .failed("This installation is missing its Bluetooth permission text. Install the latest Unwhoop IPA over this app to keep your data.")
            return
        }
        appState.cancelPairing()
        appState.pairingPhase = .requestingPermission
        appState.sync.startScan()
        appState.pairingPhase = .scanning
    }

    private func connect(to device: BandDevice) {
        appState.beginPairing(to: device)
    }

    private func completePairing() {
        guard let settings else {
            appState.pairingPhase = .failed("App settings are not ready. Try pairing again.")
            return
        }
        do {
            try appState.completePairing(settings: settings, context: modelContext)
            dismiss()
        } catch {
            appState.pairingPhase = .failed("Could not save pairing. Try again. \(error.localizedDescription)")
        }
    }
}

// MARK: - Subviews

private struct PairingIdle: View {
    let onStart: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bluetooth")
                .font(.system(size: 56))
                .foregroundStyle(.secondary)
            Text("Put your strap in pairing mode first — tap it (or slide it on the charger) until the light flashes blue. Then keep it nearby and charged, and make sure it's NOT connected to the WHOOP app.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Start scanning", action: onStart)
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 60)
    }
}

private struct PairingScanning: View {
    let devices: [BandDevice]
    let onSelect: (BandDevice) -> Void

    var body: some View {
        VStack(spacing: 16) {
            ProgressView("Scanning for WHOOP 5.0…")
            if devices.isEmpty {
                Text("Nothing found yet. Checklist: band charged? nearby? not paired to the WHOOP app?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                List(devices) { device in
                    Button {
                        onSelect(device)
                    } label: {
                        HStack {
                            Image(systemName: "applewatch")
                            Text(device.name)
                            Spacer()
                            Text("\(device.rssi) dBm")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.plain)
            }
            Spacer()
        }
    }
}

private struct PairingFailed: View {
    let reason: String
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text("Pairing failed")
                .font(.headline)
            Text(reason)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Open Settings (check Bluetooth)", destination: url)
            }
            Button("Try again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 60)
    }
}

private struct PairingNeedsPairingMode: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundStyle(.yellow)
            Text("Strap needs pairing mode")
                .font(.headline)
            Text("Your WHOOP refused pairing. Put the strap in pairing mode — tap it (or slide it on the charger) until the light flashes blue — then try again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: onRetry)
                .buttonStyle(.borderedProminent)
        }
        .padding(.top, 60)
    }
}
