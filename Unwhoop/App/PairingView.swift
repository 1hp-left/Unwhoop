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
                        appState.sync.disconnect()
                        appState.pairingPhase = .idle
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
        .onAppear(perform: subscribe)
        .alert("One important rule", isPresented: $showWarning) {
            Button("Got it") { dismiss() }
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
                    // Pairing succeeded: record, warn once, done.
                    if let settings, !settings.pairingWarningShown {
                        settings.pairingWarningShown = true
                        showWarning = true
                    } else {
                        dismiss()
                    }
                case .pairing:
                    appState.pairingPhase = .pairing
                case .needsPairingMode:
                    appState.pairingPhase = .needsPairingMode
                default:
                    break
                }
            }
            .store(in: &cancellables)
    }

    private func startScan() {
        appState.pairingPhase = .requestingPermission
        appState.sync.startScan()
        appState.pairingPhase = .scanning
    }

    private func connect(to device: BandDevice) {
        appState.pairingPhase = .connecting(device)
        appState.sync.connect(to: device)
        // TODO(fork): on real connect success, persist settings.pairedDeviceUUID.
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
