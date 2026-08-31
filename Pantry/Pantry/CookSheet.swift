import SwiftUI
import PantryCore

/// What cooking this would take off the ledger, shown before it happens.
///
/// ADR 003 is explicit that the recipe amount is a default and never a silent
/// decrement: one tap accepts it, and typing a real number is easy. Countables
/// are exact and are not offered for editing — you did not use 2.4 noodle
/// packs — while measurables are, because 400 g of rice out of a bag is a
/// guess until somebody weighs it.
struct CookSheet: View {
    let store: PantryStore
    let plan: CookPlan

    @Environment(\.dismiss) private var dismiss

    /// Edited amounts, by lot. Absent means "the recipe's number is fine".
    @State private var amounts: [Int64: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                if !plan.problems.isEmpty {
                    Section {
                        ForEach(plan.problems, id: \.self) { problem in
                            Label(problem, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                        }
                    } header: {
                        Text("Can't cook this yet")
                    } footer: {
                        Text("Nothing will be written. Recording a cook that "
                             + "didn't happen would put the ledger further from "
                             + "the kitchen, not closer.")
                    }
                }

                Section {
                    ForEach(plan.draws, id: \.lotId) { draw in
                        DrawRow(
                            draw: draw,
                            text: binding(for: draw)
                        )
                    }
                } header: {
                    Text("Comes off the shelf")
                } footer: {
                    Text("Amounts are the recipe's. Change one if you used "
                         + "more or less — a number you typed is recorded as "
                         + "measured rather than worked out.")
                }
            }
            .navigationTitle(plan.recipeName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cook it") {
                        store.cook(edited)
                        dismiss()
                    }
                    .disabled(!plan.isSatisfiable)
                }
            }
        }
    }

    private func binding(for draw: Draw) -> Binding<String> {
        Binding(
            get: { amounts[draw.lotId] ?? Self.format(draw.amount) },
            set: { amounts[draw.lotId] = $0 }
        )
    }

    /// The plan as amended by whatever was typed. An unparseable or empty
    /// field falls back to the recipe's own number rather than to zero.
    private var edited: CookPlan {
        plan.draws.reduce(plan) { result, draw in
            guard let text = amounts[draw.lotId],
                  let value = Double(text.trimmingCharacters(in: .whitespaces)),
                  value > 0
            else { return result }
            return result.amending(lotId: draw.lotId, to: value)
        }
    }

    static func format(_ amount: Double) -> String {
        amount.formatted(.number.precision(.fractionLength(0...2)))
    }
}

private struct DrawRow: View {
    let draw: Draw
    @Binding var text: String

    /// Counting is exact. Offering to edit "2 packs" invites a fraction of a
    /// pack, which is not a thing that can happen.
    private var isCountable: Bool { draw.unit == "count" }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(draw.productName)
                Text(draw.precision)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if isCountable {
                Text("\(CookSheet.format(draw.amount)) \(draw.unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                TextField("Amount", text: $text)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .frame(maxWidth: 90)
                Text(draw.unit)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
