import SwiftUI
import PantryCore

/// The three questions this app answers, one per tab: what is in here, what
/// can I cook, and how do I put something in.
///
/// A plain `TabView` rather than anything custom. The Liquid Glass treatment
/// comes later and iOS 26 applies most of it to the standard bar for free —
/// hand-rolling the bar now would be work to be undone.
struct ContentView: View {
    @State private var store = PantryStore()

    var body: some View {
        TabView {
            Tab("Pantry", systemImage: "basket") {
                PantryTab(store: store)
            }
            Tab("Cook", systemImage: "fork.knife") {
                CookTab(store: store)
            }
            Tab("Add", systemImage: "viewfinder") {
                AddTab(store: store)
            }
        }
        .task { store.start() }
    }
}

// MARK: - Shared pieces

/// A headline card: a quiet label, one large answer, and the qualification
/// that keeps the answer honest.
///
/// The third line is not decoration. Modelling rule 4 says an aggregate states
/// what it left out, so the card that reports a number is the card that has to
/// carry the exclusions.
struct SummaryCard<Detail: View>: View {
    let label: String
    let headline: String
    let tint: Color
    @ViewBuilder var detail: Detail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.caption2.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(tint)
            Text(headline)
                .font(.title2.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            detail
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(tint.opacity(0.10), in: .rect(cornerRadius: 16))
    }
}

/// How much of a lot is left, as a bar.
///
/// Renders nothing at all when the fraction is unknown. A bar defaulting to
/// empty or full would state a quantity nobody has ever measured, which is the
/// exact failure rule 3 exists to prevent.
struct RemainingBar: View {
    let fraction: Double?

    var body: some View {
        if let fraction {
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(tint)
                        .frame(width: geometry.size.width * min(fraction, 1))
                }
            }
            .frame(height: 5)
        }
    }

    /// Colour tracks how little is left, not how much — the warning is the
    /// point of the bar.
    private var tint: Color {
        switch fraction ?? 1 {
        case ..<0.15: .red
        case ..<0.35: .orange
        default:      .green
        }
    }
}

/// A quantity, or an honest refusal to state one.
struct QuantityText: View {
    let item: InventoryItem

    var body: some View {
        if let balance = item.balance {
            Text("\(balance.formatted(.number.precision(.fractionLength(0...1)))) \(item.baseUnit ?? "")")
                .monospacedDigit()
        } else {
            Text("unknown")
                .foregroundStyle(.secondary)
                .italic()
        }
    }
}
