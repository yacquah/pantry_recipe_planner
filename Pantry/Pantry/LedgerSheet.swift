import SwiftUI
import PantryCore

/// The three ways food leaves a lot without a recipe.
///
/// One sheet rather than three, because they are the same gesture with
/// different meanings — which is exactly how ADR 003 models them underneath: a
/// single event with a reason code, not a table per verb.
enum LedgerAction: String, Identifiable, CaseIterable {
    case eat, waste, recount

    var id: String { rawValue }

    var title: String {
        switch self {
        case .eat:     "Ate some"
        case .waste:   "Threw it out"
        case .recount: "Recount"
        }
    }

    var symbol: String {
        switch self {
        case .eat:     "fork.knife"
        case .waste:   "trash"
        case .recount: "equal.square"
        }
    }

    /// What the number means, which differs in kind between them. Eating and
    /// binning state a change; a recount states a total.
    var prompt: String {
        switch self {
        case .eat:     "How much did you have?"
        case .waste:   "How much went in the bin?"
        case .recount: "How much is actually there?"
        }
    }
}

struct LedgerSheet: View {
    let store: PantryStore
    let item: InventoryItem
    let action: LedgerAction

    @Environment(\.dismiss) private var dismiss

    @State private var amount = ""
    @State private var precision = "estimated"
    @State private var wasteReason = "expired"

    /// The sub-reasons from ADR 003, in the words the table uses. Each routes
    /// to a different fix, which is why they are not one "wasted" bucket.
    private let reasons = [
        ("expired", "Passed its date"),
        ("spoiled", "Went bad early"),
        ("freezer_burn", "Freezer burn"),
        ("disliked", "Didn't want it"),
        ("accident", "Dropped or spilled"),
    ]

    /// Precision travels with every number (ADR 003), because a scale and an
    /// eyeball produce numbers of different quality and the ledger keeps that.
    private let precisions = [
        ("measured", "Weighed it"),
        ("derived", "Worked it out"),
        ("estimated", "Eyeballed it"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("On hand") { QuantityText(item: item) }
                } header: {
                    Text(item.name)
                }

                Section {
                    HStack {
                        TextField("Amount", text: $amount)
                            .keyboardType(.decimalPad)
                        Text(item.baseUnit ?? "")
                            .foregroundStyle(.secondary)
                    }
                    Picker("How do you know?", selection: $precision) {
                        ForEach(precisions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } header: {
                    Text(action.prompt)
                } footer: {
                    if action == .recount {
                        // The reason a recount is not just another subtraction.
                        Text("A recount replaces the running total rather than "
                             + "adjusting it. What you can see wins over what "
                             + "the app worked out.")
                    }
                }

                if action == .waste {
                    Section {
                        Picker("Why", selection: $wasteReason) {
                            ForEach(reasons, id: \.0) { Text($0.1).tag($0.0) }
                        }
                        .pickerStyle(.inline)
                        .labelsHidden()
                    } header: {
                        Text("What happened")
                    } footer: {
                        Text("Recorded from day one even though nothing shows it "
                             + "yet — the causes are what a waste report would "
                             + "eventually be built from.")
                    }
                }
            }
            .navigationTitle(action.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(quantity == nil)
                }
            }
        }
    }

    private var quantity: Double? {
        guard let value = Double(amount.trimmingCharacters(in: .whitespaces)) else { return nil }
        // A recount can legitimately observe zero; eating or binning nothing
        // is not an event worth recording.
        return action == .recount ? (value >= 0 ? value : nil) : (value > 0 ? value : nil)
    }

    private func save() {
        guard let quantity else { return }
        switch action {
        case .eat:
            store.eat(lot: item.lotId, quantity: quantity, precision: precision)
        case .waste:
            store.waste(lot: item.lotId, quantity: quantity,
                        reason: wasteReason, precision: precision)
        case .recount:
            store.recount(lot: item.lotId, observed: quantity, precision: precision)
        }
        dismiss()
    }
}
