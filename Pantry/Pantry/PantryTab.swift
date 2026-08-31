import SwiftUI
import PantryCore

/// What is in the kitchen — led by what is about to go bad.
///
/// The mockup opens on quantity ("running out first"). This opens on expiry
/// instead, because that is the question the app was built to answer and the
/// one the reminders are wired to. Quantity gets the section below it, which
/// is the same shape with the two swapped.
struct PantryTab: View {
    let store: PantryStore

    var body: some View {
        NavigationStack {
            Group {
                if let message = store.errorMessage {
                    ProblemView(message: message)
                } else if store.isEmpty {
                    EmptyPantryView { store.importStarterInventory() }
                } else {
                    list
                }
            }
            .navigationTitle("Pantry")
        }
    }

    private var list: some View {
        List {
            if let soon = store.expiringSoon {
                Section {
                    SummaryCard(
                        label: "Act soon",
                        headline: soon.items.isEmpty
                            ? "Nothing expiring in the next 3 days"
                            : "\(soon.items.count) item\(soon.items.count == 1 ? "" : "s") to use up",
                        tint: soon.items.isEmpty ? .green : .orange
                    ) {
                        // Rule 4: the count states what it could not assess.
                        Text("\(soon.lotsTotal) lots · \(soon.notApplicable) don't expire · "
                             + "\(soon.excludedUnknown) couldn't be assessed")
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)

                    ForEach(soon.items, id: \.lotId) { ExpiryRow(item: $0) }
                }

                if let next = store.alerts.first {
                    Section {
                        LabeledContent {
                            Text(next.fireAt, format: .dateTime.day().month().year())
                                .monospacedDigit()
                        } label: {
                            Text(next.item)
                            Text("\(next.leadDays) day(s) before it needs using")
                        }
                    } header: {
                        Text("Next reminder")
                    } footer: {
                        // Reports what iOS confirms it holds, not what was
                        // planned — the two differ when permission is refused.
                        if store.notificationsRefused {
                            Text("Notifications are off, so nothing will be sent. "
                                 + "Turn them on in Settings to be reminded.")
                        } else {
                            Text(store.scheduledCount == 1
                                 ? "1 reminder scheduled."
                                 : "\(store.scheduledCount) reminders scheduled.")
                        }
                    }
                }
            }

            if !store.runningLow.isEmpty {
                Section {
                    ForEach(store.runningLow) { StockRow(item: $0) }
                } header: {
                    Text("Running low")
                } footer: {
                    Text("Lots whose quantity has never been recorded are not "
                         + "ranked here — they appear under Needs attention.")
                }
            }

            if !store.needsAttention.isEmpty {
                Section {
                    ForEach(store.needsAttention) { item in
                        LabeledContent {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.orange)
                        } label: {
                            Text(item.name)
                            Text(item.attentionReason ?? "")
                        }
                    }
                } header: {
                    Text("Needs attention")
                } footer: {
                    // ADR 001's distinction, made visible: these are questions
                    // to resolve, not alerts. Nothing here will interrupt you.
                    Text("Questions the app can't answer. None of these send a "
                         + "notification — there's nothing to act on yet.")
                }
            }

            Section("Everything") {
                ForEach(store.stock) { StockRow(item: $0) }
            }
        }
    }
}

// MARK: - Rows

/// One lot, with how much is left and when it goes.
struct StockRow: View {
    let item: InventoryItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.name)
                Spacer(minLength: 12)
                QuantityText(item: item)
                    .font(.subheadline)
            }
            RemainingBar(fraction: item.remainingFraction)
            if let date = item.effectiveDate {
                Text(date).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

/// One dated lot. Never a bare date — a date the app worked out and one a
/// human read off a label look identical unless you say which it is, and that
/// ambiguity is what ADR 001 exists to prevent.
struct ExpiryRow: View {
    let item: ExpiryItem

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.item)
                Text(provenance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.effectiveDate.isEmpty ? "—" : item.displayDate)
                    .monospacedDigit()
                if item.shouldPush {
                    Label("alerts", systemImage: "bell.fill")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    private var provenance: String {
        switch item.source {
        case "label":          return "from the label" + (item.kind.map { " · \($0.replacingOccurrences(of: "_", with: " "))" } ?? "")
        case "not_applicable": return "does not expire"
        case "unknown":        return "no date, and none can be worked out"
        default:               return "worked out from " + item.source
                                        .replacingOccurrences(of: "derived_", with: "")
        }
    }
}

// MARK: - The other two states

struct EmptyPantryView: View {
    let importStarter: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Nothing captured yet", systemImage: "basket")
        } description: {
            Text("Import the hand-collected inventory to see the app working "
                 + "against real data.")
        } actions: {
            Button("Import starter inventory", action: importStarter)
                .buttonStyle(.borderedProminent)
        }
    }
}

struct ProblemView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("The pantry could not be opened", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message)
        }
    }
}
