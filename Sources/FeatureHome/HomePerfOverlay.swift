#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// A compact, non-interactive HUD that surfaces live Home performance while you
/// browse — so smoothness can be validated by eye on real (older) hardware. Reads
/// a running ``HomePerfSampler``; shown only when the Settings toggle is on.
///
/// Purely decorative: never focusable, never hit-testable, so it can't interfere
/// with the hero's focus/paging.
struct HomePerfOverlay: View {
    let sampler: HomePerfSampler

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row("FPS", String(format: "%.0f", sampler.fps), color: fpsColor)
            row(
                "Hitch",
                String(format: "%.1f/s  (%d)", sampler.hitchesPerSecond, sampler.hitchesTotal),
                color: hitchColor
            )
            row("Worst", String(format: "%.0f ms", sampler.worstFrameMs), color: worstColor)
            row("Thermal", thermalLabel, color: thermalColor)
            row("Mem", String(format: "%.0f MB", sampler.memoryMB), color: .white)
            if let curate = sampler.curateMs {
                row("Curate", String(format: "%.0f ms", curate), color: .white)
            }
            if let artwork = sampler.artworkMs {
                row("Artwork", String(format: "%.0f ms", artwork), color: .white)
            }
            Text(sampler.deviceModel)
                .font(.system(size: 15, weight: .regular, design: .monospaced))
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 1)
        )
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func row(_ label: String, _ value: String, color: Color) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .frame(width: 78, alignment: .leading)
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
        }
    }

    private var fpsColor: Color {
        switch sampler.fps {
        case ..<30: return .red
        case 30..<55: return .yellow
        default: return .green
        }
    }

    private var hitchColor: Color {
        switch sampler.hitchesPerSecond {
        case ..<0.5: return .green
        case 0.5..<3: return .yellow
        default: return .red
        }
    }

    private var worstColor: Color {
        switch sampler.worstFrameMs {
        case ..<20: return .green
        case 20..<40: return .yellow
        default: return .red
        }
    }

    private var thermalLabel: String {
        switch sampler.thermal {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }

    private var thermalColor: Color {
        switch sampler.thermal {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious, .critical: return .red
        @unknown default: return .white
        }
    }
}
#endif
