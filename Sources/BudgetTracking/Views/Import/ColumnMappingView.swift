import SwiftUI

struct ColumnMappingView: View {
    let columns: [String]
    let sampleRows: [ParsedRow]
    @Binding var dateColumnIndex: Int?
    @Binding var descriptionColumnIndex: Int?
    @Binding var amountColumnIndex: Int?
    @Binding var selectedDateFormat: String
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Text("Map Columns")
                .font(.title2)
                .fontWeight(.semibold)

            Text("We couldn't auto-detect all columns. Please assign them manually.")
                .foregroundStyle(.secondary)

            // Column assignments
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Date Column:")
                        .frame(width: 140, alignment: .trailing)
                    Picker("", selection: $dateColumnIndex) {
                        Text("Select...").tag(nil as Int?)
                        ForEach(0..<columns.count, id: \.self) { i in
                            Text(columns[i]).tag(i as Int?)
                        }
                    }
                    .frame(maxWidth: 200)
                }

                HStack {
                    Text("Date Format:")
                        .frame(width: 140, alignment: .trailing)
                    Picker("", selection: $selectedDateFormat) {
                        ForEach(DateHelpers.commonDateFormats, id: \.self) { fmt in
                            Text(fmt).tag(fmt)
                        }
                    }
                    .frame(maxWidth: 200)
                }

                HStack {
                    Text("Description Column:")
                        .frame(width: 140, alignment: .trailing)
                    Picker("", selection: $descriptionColumnIndex) {
                        Text("Select...").tag(nil as Int?)
                        ForEach(0..<columns.count, id: \.self) { i in
                            Text(columns[i]).tag(i as Int?)
                        }
                    }
                    .frame(maxWidth: 200)
                }

                HStack {
                    Text("Amount Column:")
                        .frame(width: 140, alignment: .trailing)
                    Picker("", selection: $amountColumnIndex) {
                        Text("Select...").tag(nil as Int?)
                        ForEach(0..<columns.count, id: \.self) { i in
                            Text(columns[i]).tag(i as Int?)
                        }
                    }
                    .frame(maxWidth: 200)
                }
            }
            .padding()
            .background(Color(nsColor: .controlBackgroundColor))
            .cornerRadius(8)

            // Sample data preview
            if !sampleRows.isEmpty {
                Text("Sample Data")
                    .font(.headline)

                ScrollView(.horizontal) {
                    VStack(alignment: .leading, spacing: 2) {
                        // Header row
                        HStack(spacing: 0) {
                            ForEach(columns, id: \.self) { col in
                                Text(col)
                                    .font(.caption)
                                    .fontWeight(.bold)
                                    .frame(width: 120, alignment: .leading)
                                    .padding(.horizontal, 4)
                            }
                        }
                        .padding(.vertical, 4)

                        ForEach(Array(sampleRows.prefix(5).enumerated()), id: \.offset) { _, row in
                            HStack(spacing: 0) {
                                ForEach(columns, id: \.self) { col in
                                    Text(row.rawColumns[col] ?? "")
                                        .font(.caption)
                                        .frame(width: 120, alignment: .leading)
                                        .padding(.horizontal, 4)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                }
                .background(Color(nsColor: .controlBackgroundColor))
                .cornerRadius(8)
            }

            // Actions
            HStack {
                Button("Cancel") { onCancel() }
                    .buttonStyle(.bordered)
                Spacer()
                Button("Import") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .disabled(dateColumnIndex == nil || descriptionColumnIndex == nil || amountColumnIndex == nil)
            }
        }
        .padding()
    }
}
