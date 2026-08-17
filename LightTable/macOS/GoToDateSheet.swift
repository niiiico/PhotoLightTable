#if os(macOS)
import SwiftUI

/// Asks for a day, so a photograph from years back is a date away rather than a
/// minute of scrolling.
struct GoToDateSheet: View {
    @Binding var date: Date
    /// What the grid actually covers. The picker is held inside it so a date
    /// with nothing behind it cannot be asked for in the first place.
    let bounds: ClosedRange<Date>?
    let onGo: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Go to Date")
                .font(.headline)

            picker
                .datePickerStyle(.graphical)
                .labelsHidden()

            if let bounds {
                Text("This view runs from \(bounds.lowerBound.formatted(.dateTime.day().month(.abbreviated).year())) to \(bounds.upperBound.formatted(.dateTime.day().month(.abbreviated).year())).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            // Nothing on the chosen day is the ordinary case rather than a
            // failure — most days have no photographs on them — so say where
            // it will land instead of refusing to go.
            Text("Lands on the nearest day with photographs.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Go", action: onGo)
                    .keyboardShortcut(.defaultAction)
                    .disabled(bounds == nil)
            }
        }
        .padding(20)
        .frame(width: 320)
    }

    @ViewBuilder
    private var picker: some View {
        if let bounds {
            DatePicker("Date", selection: $date, in: bounds, displayedComponents: .date)
        } else {
            DatePicker("Date", selection: $date, displayedComponents: .date)
        }
    }
}
#endif
