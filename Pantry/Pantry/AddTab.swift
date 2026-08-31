import SwiftUI
import PantryCore

/// Putting something in.
///
/// The mockup opens on a barcode viewfinder, and spec §2 does make v1
/// barcode-first. The scanner is not written, so this leads with the path that
/// does work rather than showing a dead camera — and says plainly that the
/// scanner is coming, instead of implying a capability the app lacks.
struct AddTab: View {
    let store: PantryStore

    @State private var showingCapture = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        showingCapture = true
                    } label: {
                        Label("Enter by hand", systemImage: "square.and.pencil")
                    }

                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Scan a barcode")
                            Text("Not built yet — the schema is ready for it")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "barcode.viewfinder")
                    }
                    .foregroundStyle(.secondary)
                }

                if store.isEmpty {
                    Section {
                        Button("Import starter inventory") {
                            store.importStarterInventory()
                        }
                    } footer: {
                        Text("The eleven hand-collected items the whole schema "
                             + "was designed against.")
                    }
                }

                if !store.stock.isEmpty {
                    Section("Recently added") {
                        ForEach(store.stock.prefix(5)) { item in
                            LabeledContent {
                                QuantityText(item: item).font(.subheadline)
                            } label: {
                                Text(item.name)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add")
            .sheet(isPresented: $showingCapture) {
                CaptureSheet(store: store)
            }
        }
    }
}

/// Manual capture.
///
/// Only a name is required. ADR 002 is explicit that capture is never blocked:
/// identity matters most and quantity can always be improved later, so an item
/// with nothing but a name still lands, flagged for review, rather than being
/// refused at the door.
struct CaptureSheet: View {
    let store: PantryStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var brand = ""
    @State private var quantity = ""
    @State private var baseUnit = "g"
    @State private var shelfLifeClass = "ambient_stable"
    @State private var precision = "estimated"
    @State private var hasDate = false
    @State private var expiresOn = Date()
    @State private var expiryKind = "best_before"

    private let units = ["g", "ml", "count"]
    private let classes = [
        ("ambient_stable", "Doesn't really expire"),
        ("stable_until_opened", "Keeps until opened"),
        ("perishable", "Perishable"),
    ]
    private let precisions = [
        ("measured", "Weighed it"),
        ("derived", "Worked it out"),
        ("estimated", "Eyeballed it"),
    ]
    private let kinds = [
        ("use_by", "Use by (safety)"),
        ("best_before", "Best before (quality)"),
        ("sell_by", "Sell by (the shop's)"),
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                    TextField("Brand (optional)", text: $brand)
                } footer: {
                    Text("Only the name is required. Anything you don't know "
                         + "can be filled in later — capture is never blocked.")
                }

                Section("How much") {
                    HStack {
                        TextField("Quantity", text: $quantity)
                            .keyboardType(.decimalPad)
                        Picker("Unit", selection: $baseUnit) {
                            ForEach(units, id: \.self) { Text($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 160)
                    }
                    Picker("How do you know?", selection: $precision) {
                        ForEach(precisions, id: \.0) { Text($0.1).tag($0.0) }
                    }
                }

                Section {
                    Picker("Keeps", selection: $shelfLifeClass) {
                        ForEach(classes, id: \.0) { Text($0.1).tag($0.0) }
                    }
                } footer: {
                    Text("This decides whether a missing date is a gap worth "
                         + "chasing or simply not applicable.")
                }

                Section {
                    Toggle("Has a date on the label", isOn: $hasDate)
                    if hasDate {
                        DatePicker("Date", selection: $expiresOn, displayedComponents: .date)
                        Picker("Kind of date", selection: $expiryKind) {
                            ForEach(kinds, id: \.0) { Text($0.1).tag($0.0) }
                        }
                    }
                } footer: {
                    Text("Which kind matters: a use-by is about safety, a "
                         + "best-before only about quality.")
                }
            }
            .navigationTitle("Enter by hand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        store.capture(request)
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private var request: CaptureRequest {
        let trimmedName = name.trimmingCharacters(in: .whitespaces)
        let amount = Double(quantity.trimmingCharacters(in: .whitespaces))

        return CaptureRequest(
            // The raw layer keeps what was typed, unedited, whatever the
            // normalised row ends up saying (ADR 008).
            verbatim: [trimmedName, brand, quantity]
                .filter { !$0.isEmpty }
                .joined(separator: " "),
            name: trimmedName,
            brand: brand.isEmpty ? nil : brand,
            baseUnit: amount == nil ? nil : baseUnit,
            shelfLifeClass: shelfLifeClass,
            quantity: amount,
            // Precision travels with the amount. Without a quantity there is
            // nothing for it to describe.
            precision: amount == nil ? nil : precision,
            expiresOn: hasDate ? Self.iso.string(from: expiresOn) : nil,
            expiryKind: hasDate ? expiryKind : nil,
            expiryPrecision: hasDate ? "day" : nil,
            deviceId: "ios"
        )
    }

    private static let iso: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}
