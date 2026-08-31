import SwiftUI
import PantryCore

/// What can be cooked tonight without a store run.
///
/// The four-state answer from ADR 004 survives to the screen intact. That is
/// the whole point of the tab: a false "no" from an approximate bridge quietly
/// kills the feature, because you cook something else and the food rots anyway.
struct CookTab: View {
    let store: PantryStore

    /// The plan being confirmed, if any. Held rather than recomputed on every
    /// body pass — planning reads the database.
    @State private var planning: CookPlan?

    var body: some View {
        NavigationStack {
            Group {
                if store.recipes.isEmpty {
                    ContentUnavailableView(
                        "No recipes yet",
                        systemImage: "fork.knife",
                        description: Text("Recipes are hand-entered and stored on this "
                                          + "device. Import the starter inventory to see "
                                          + "the matcher working.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Cook tonight")
            .sheet(item: $planning) { plan in
                CookSheet(store: store, plan: plan)
            }
        }
    }

    private var list: some View {
        List {
            Section {
                SummaryCard(
                    label: "Without a store run",
                    headline: "\(cookable) of \(store.recipes.count) recipes",
                    tint: cookable > 0 ? .green : .orange
                ) {
                    // Rule 4 again: never just the good number.
                    Text(unresolved == 0
                         ? "Every ingredient could be assessed"
                         : "\(unresolved) ingredient\(unresolved == 1 ? "" : "s") could not be assessed")
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
            }

            ForEach(store.recipes, id: \.recipe) { match in
                Section {
                    Button {
                        planning = store.plan(forRecipe: match.recipe)
                    } label: {
                        RecipeCard(match: match)
                    }
                    .buttonStyle(.plain)
                    // A recipe the matcher cannot vouch for is not offered for
                    // cooking. Writing a cook off an unknown quantity would put
                    // a confident number into the ledger on no evidence.
                    .disabled(match.verdict == .cannotTell)
                }
            }
        }
    }

    private var cookable: Int {
        store.recipes.filter { $0.verdict == .yes }.count
    }

    private var unresolved: Int {
        store.recipes.reduce(0) { $0 + $1.excluded }
    }
}

// MARK: - One recipe

struct RecipeCard: View {
    let match: RecipeMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(match.recipe)
                    .font(.headline)
                Spacer(minLength: 8)
                VerdictPill(verdict: match.verdict)
            }

            Text(match.decidedBy)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text(tally)
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(match.ingredients, id: \.ingredient) { check in
                IngredientLine(check: check)
            }
        }
        .padding(.vertical, 4)
    }

    /// Confirmed out of total, and separately what could not be assessed —
    /// never folded together, because "not enough" and "cannot tell" are
    /// different answers and one of them is a question.
    private var tally: String {
        let confirmed = match.ingredients.filter { $0.status == .have }.count
        let base = "\(confirmed) of \(match.ingredients.count) confirmed"
        return match.excluded == 0 ? base : base + " · \(match.excluded) uncertain"
    }
}

/// The four-state verdict, with `cannotTell` visibly not a "no".
///
/// A refusal to answer is closer to a question than to a rejection, so it is
/// given the neutral, questioning treatment rather than the red one. Making it
/// look like failure is how a four-state answer quietly becomes three.
struct VerdictPill: View {
    let verdict: Verdict

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.16), in: .capsule)
            .foregroundStyle(tint)
    }

    private var text: String {
        switch verdict {
        case .yes:        "Yes"
        case .probably:   "Probably"
        case .no:         "Not enough"
        case .cannotTell: "Can't tell"
        }
    }

    private var symbol: String {
        switch verdict {
        case .yes:        "checkmark.circle.fill"
        case .probably:   "checkmark.circle"
        case .no:         "xmark.circle"
        case .cannotTell: "questionmark.circle"
        }
    }

    private var tint: Color {
        switch verdict {
        case .yes:        .green
        case .probably:   .orange
        case .no:         .secondary
        case .cannotTell: .purple
        }
    }
}

/// One ingredient's comparison, showing its working.
struct IngredientLine: View {
    let check: IngredientCheck

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 14)

            Text(check.ingredient)
                .font(.caption)

            Spacer(minLength: 8)

            Text(comparison)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// "have unknown" rather than "have 0". The distinction is the project.
    private var comparison: String {
        let need = check.needQty.formatted(.number.precision(.fractionLength(0...1)))
        guard let haveQty = check.haveQty else {
            return "need \(need) \(check.needUnit) · have unknown"
        }
        let have = haveQty.formatted(.number.precision(.fractionLength(0...1)))
        return "need \(need) \(check.needUnit) · have \(have)"
    }

    private var symbol: String {
        switch check.status {
        case .have:          "checkmark"
        case .probably:      "checkmark"
        case .short:         "xmark"
        case .probablyShort: "exclamationmark"
        case .cannotTell:    "questionmark"
        }
    }

    private var tint: Color {
        switch check.status {
        case .have:                     .green
        case .probably, .probablyShort: .orange
        case .short:                    .secondary
        case .cannotTell:               .purple
        }
    }
}
