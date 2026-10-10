import SwiftUI
import SwiftData

// MARK: - OnboardingView
//
// Launch 1 (no band paired): one screen — what the app is + the medical
// disclaimer (must accept to continue) + "Pair your WHOOP 5.0" button.

struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @Query private var settingsRows: [AppSettings]
    @State private var disclaimerAccepted = false
    @State private var showPairing = false

    private var settings: AppSettings? { settingsRows.first }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Unwhoop")
                        .font(.largeTitle.bold())
                    Text("Your WHOOP 5.0, without the membership.")
                        .font(.title3)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 12) {
                        OnboardingRow(icon: "heart.fill", text: "Recovery, sleep, and strain scores computed on your phone from the band's raw data.")
                        OnboardingRow(icon: "lock.fill", text: "No account. No cloud. No network calls at all — your data never leaves this phone.")
                        OnboardingRow(icon: "moon.fill", text: "Overnight sync happens automatically. Wake up to a recovery score.")
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))

                    // Medical disclaimer — must accept to continue (PRD §10).
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Health disclaimer")
                            .font(.headline)
                        Text("Not a medical device. Scores are estimates from published methods, not clinical measurements.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Toggle("I understand", isOn: $disclaimerAccepted)
                            .tint(.accentColor)
                    }
                    .padding()
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))

                    Button {
                        settings?.disclaimerAccepted = true
                        showPairing = true
                    } label: {
                        Label("Pair your WHOOP 5.0", systemImage: "bluetooth")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!disclaimerAccepted)
                    .padding(.top, 8)
                }
                .padding()
            }
            .navigationDestination(isPresented: $showPairing) {
                PairingView()
            }
        }
    }
}

private struct OnboardingRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 24)
            Text(text)
                .font(.subheadline)
        }
    }
}
