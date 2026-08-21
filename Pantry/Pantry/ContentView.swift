import SwiftUI
import PantryCore

struct ContentView: View {
    @State private var store = PantryStore()

    var body: some View {
        NavigationStack {
            Group {
                if let message = store.errorMessage {
                    ProblemView(message: message)
                } else if store.isEmpty {
                    EmptyPantryView { store.importStarterInventory() }
                } else {
                    PantryList(store: store)
                }
            }
            .navigationTitle("Pantry")
        }
        .task { store.start() }
    }
}

// MARK: - The list

private struct PantryList: View {
    let store: PantryStore

    var body: some View {
        List {
            if let soon = store.expiringSoon {
                Section {
                    if soon.items.isEmpty {
                        Text("Nothing expiring in the next 3 days.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(soon.items, id: \.lotId) { item in
                            ExpiryRow(item: item)
                        }
                    }
                } header: {
                    Text("Act soon")
                } footer: {
                    // Modelling rule 4: an answer states what it could not
                    // assess. A total that quietly skips rows is worse than
                    // one that refuses, because nobody questions it.
                    Text("\(soon.lotsTotal) lots · \(soon.notApplicable) not applicable · "
                         + "\(soon.excludedUnknown) could not be assessed")
                }
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
                    // The bell on a row promises a notification. This reports
                    // what iOS confirmed it holds — not what was planned — so
                    // a refused permission cannot look like a working reminder.
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

            Section("Everything") {
                ForEach(store.items, id: \.lotId) { item in
                    ExpiryRow(item: item)
                }
            }
        }
    }
}

private struct ExpiryRow: View {
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
                // Never a bare date. A date the app worked out and a date a
                // human read off a label look identical unless you say which
                // it is, and that ambiguity is what ADR 001 exists to prevent.
                Text(item.effectiveDate.isEmpty ? "—" : item.displayDate)
                    .monospacedDigit()
                if item.shouldPush {
                    Label("alerts", systemImage: "bell.fill")
                        .font(.caption2)
                        .labelStyle(.titleAndIcon)
                        .foregroundStyle(.orange)
                }
            }
            .font(.subheadline)
        }
        .padding(.vertical, 2)
    }

    /// Where the date came from, in words rather than a column name.
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

private struct EmptyPantryView: View {
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

private struct ProblemView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Could not open the pantry", systemImage: "exclamationmark.triangle")
        } description: {
            Text(message).font(.footnote).monospaced()
        }
    }
}

#Preview {
    ContentView()
}
