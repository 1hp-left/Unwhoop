import SwiftUI

// MARK: - Shared UI
//
// Native performance dashboard, styled after the requested WHOOP reference.

enum AppTheme {
    static let background = Color(red: 0.055, green: 0.071, blue: 0.09)
    static let surface = Color(red: 0.10, green: 0.122, blue: 0.15)
    static let inset = Color(red: 0.14, green: 0.16, blue: 0.19)
    static let muted = Color(red: 0.66, green: 0.70, blue: 0.75)
    static let sleep = Color(red: 0.69, green: 0.63, blue: 0.94)
    static let recovery = Color(red: 0.55, green: 0.83, blue: 0.26)
    static let strain = Color(red: 0.25, green: 0.64, blue: 0.96)
}

struct MetricDial: View {
    let title: String
    let value: Double?
    let maximum: Double
    let color: Color
    let percent: Bool

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                Circle().trim(from: 0, to: 0.84)
                    .stroke(AppTheme.inset, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                if let value {
                    Circle().trim(from: 0, to: 0.84 * max(0, min(value / maximum, 1)))
                        .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                }
            }
            .rotationEffect(.degrees(118.8))
            .overlay {
                VStack(spacing: 0) {
                    Text(value.map { percent ? String(format: "%.0f", $0) : String(format: "%.1f", $0) } ?? "—")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(value == nil ? AppTheme.muted : color)
                        .minimumScaleFactor(0.7)
                    if percent && value != nil {
                        Text("%").font(.caption2.bold()).foregroundStyle(color)
                    }
                }
            }
            .frame(width: 88, height: 88)
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold)).tracking(1)
                .foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value.map { percent ? "\(Int($0)) percent" : String(format: "%.1f", $0) } ?? "No score available")
    }
}

struct DashboardHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.title3.bold())
            Text(subtitle).font(.caption).foregroundStyle(AppTheme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

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
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
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
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
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
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
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
