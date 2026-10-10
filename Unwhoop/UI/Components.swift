import SwiftUI

// MARK: - Shared UI
//
// Design rules (PRD §6), enforced here:
// - Dark-first; SF Symbols; system colors.
// - Color is semantic, not decorative: green/yellow/red ONLY for recovery
//   bands. Everything else is monochrome + one accent.
// - One primary number per screen.

extension Color {
    /// The ONLY sanctioned use of green/yellow/red in the app.
    static func recoveryBand(_ band: RecoveryBand) -> Color {
        switch band {
        case .recovered: .green
        case .payAttention: .yellow
        case .rest: .red
        }
    }
}

// MARK: - Stale banner

/// Shown whenever the last successful sync is older than 12h (PRD §5.1).
/// Never display a score computed from stale data without this banner.
struct StaleBanner: View {
    let lastSync: Date?

    private var isStale: Bool {
        guard let lastSync else { return true }
        return Date().timeIntervalSince(lastSync) > 12 * 3600
    }

    private var relative: String {
        guard let lastSync else { return "never" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: lastSync, relativeTo: Date())
    }

    var body: some View {
        if isStale {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Last sync \(relative) — scores may be stale.")
                    .font(.subheadline)
                Spacer()
            }
            .padding()
            .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        }
    }
}

// MARK: - Low confidence badge

struct LowConfidenceBadge: View {
    let reason: String?
    @State private var showReason = false

    var body: some View {
        Button {
            showReason = true
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.circle.fill")
                Text("Low confidence")
                    .font(.caption.bold())
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: Capsule())
        }
        .buttonStyle(.plain)
        .alert("Low confidence", isPresented: $showReason) {
            Button("OK", role: .cancel) {}
        } message: {
            // PRD §9: the reason is one tap away.
            Text(reason ?? "This night failed a data-quality gate, so the score is shown greyed.")
        }
    }
}

// MARK: - Delta arrow (deliberately NOT green/red)

/// Delta vs baseline. Arrows are monochrome — color is reserved for recovery
/// bands, so direction alone carries the meaning here.
struct DeltaArrow: View {
    /// Positive = above baseline, negative = below, nil = no baseline yet.
    let delta: Double?
    let unit: String

    var body: some View {
        if let delta {
            HStack(spacing: 2) {
                Image(systemName: delta > 0.05 ? "arrow.up" : delta < -0.05 ? "arrow.down" : "minus")
                    .font(.caption2.bold())
                Text(String(format: "%+.1f%@", delta, unit))
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Vital tile

struct VitalTile: View {
    let icon: String
    let title: String
    let value: String
    let delta: Double?
    let deltaUnit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption)
            }
            .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
                .monospacedDigit()
            DeltaArrow(delta: delta, unit: deltaUnit)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Sleep stage bar

/// Compact stacked bar: wake / light / deep / REM proportions.
/// Monochrome ramp — no semantic color here.
struct StageBar: View {
    let light: Double
    let deep: Double
    let rem: Double
    let wake: Double

    private var total: Double { max(light + deep + rem + wake, 1) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                segment(width: geo.size.width * wake / total, color: .gray.opacity(0.25), label: "Awake")
                segment(width: geo.size.width * light / total, color: .gray.opacity(0.5), label: "Light")
                segment(width: geo.size.width * deep / total, color: .gray.opacity(0.8), label: "Deep")
                segment(width: geo.size.width * rem / total, color: .gray, label: "REM")
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sleep stages: \(Int(light)) light, \(Int(deep)) deep, \(Int(rem)) REM, \(Int(wake)) awake minutes")
    }

    private func segment(width: CGFloat, color: Color, label: String) -> some View {
        color
            .frame(width: max(width - 2, 0))
            .accessibilityLabel(label)
    }
}

// MARK: - Card container

struct Card<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Formatting

enum Format {
    static func hoursMinutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return "\(total / 60)h \(String(format: "%02d", total % 60))m"
    }

    static func percent(_ value: Double) -> String {
        "\(Int(value.rounded()))%"
    }
}
