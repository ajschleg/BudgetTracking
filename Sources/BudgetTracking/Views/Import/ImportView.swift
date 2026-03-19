import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Binding var selectedMonth: String
    @State private var viewModel = ImportViewModel()
    @State private var isTargeted = false
    @State private var showDeleteConfirmation = false
    @State private var fileToDelete: ImportedFile?

    var body: some View {
        HSplitView {
            // Left: Import area
            VStack(spacing: 16) {
                MonthSelectorView(selectedMonth: $selectedMonth)
                    .padding(.top, 8)

                importContent
            }
            .frame(minWidth: 400)

            // Right: Imported files list
            importedFilesList
                .frame(minWidth: 250, idealWidth: 300)
        }
        .navigationTitle("Import Statements")
        .onAppear { viewModel.loadImportedFiles(month: selectedMonth) }
        .onChange(of: selectedMonth) { _, newMonth in
            viewModel.loadImportedFiles(month: newMonth)
            viewModel.reset()
        }
        .onChange(of: viewModel.detectedMonth) { _, detected in
            // Only auto-switch month for single-month files
            if let detected, detected != selectedMonth,
               viewModel.importedMonthBreakdown.isEmpty {
                selectedMonth = detected
                viewModel.loadImportedFiles(month: detected)
            }
        }
        .alert("Duplicate File Detected", isPresented: $viewModel.showDuplicateAlert) {
            Button("Import Anyway") {
                viewModel.handleDuplicateAction(.importAnyway, month: selectedMonth)
            }
            Button("Replace Existing") {
                viewModel.handleDuplicateAction(.replace, month: selectedMonth)
            }
            Button("Cancel", role: .cancel) {
                viewModel.handleDuplicateAction(.cancel, month: selectedMonth)
            }
        } message: {
            if let dup = viewModel.duplicateFile {
                Text("A file named \"\(dup.fileName)\" was already imported on \(DateHelpers.shortDate(dup.importedAt)). What would you like to do?")
            }
        }
        .alert("Delete Statement?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                if let file = fileToDelete {
                    viewModel.deleteImportedFile(file, month: selectedMonth)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let file = fileToDelete {
                if file.isMultiMonth {
                    Text("This will remove \"\(file.fileName)\" and all \(file.transactionCount) transactions across all months from your budget.")
                } else {
                    Text("This will remove \"\(file.fileName)\" and its \(file.transactionCount) transactions from your budget.")
                }
            }
        }
    }

    @ViewBuilder
    private var importContent: some View {
        switch viewModel.state {
        case .idle:
            dropZone
                .padding()

        case .parsing:
            ProgressView("Parsing file...")
                .padding()

        case .preview(let rows, let fileName, let fileSize):
            ParsePreviewView(
                rows: rows,
                fileName: fileName,
                positiveIsSpending: $viewModel.positiveIsSpending,
                onConfirm: {
                    viewModel.confirmImport(
                        rows: rows, fileName: fileName,
                        fileSize: fileSize, month: selectedMonth
                    )
                },
                onCancel: { viewModel.reset() }
            )

        case .columnMapping(let rows, let columns, let fileName, let fileSize):
            ColumnMappingView(
                columns: columns,
                sampleRows: rows,
                dateColumnIndex: $viewModel.dateColumnIndex,
                descriptionColumnIndex: $viewModel.descriptionColumnIndex,
                amountColumnIndex: $viewModel.amountColumnIndex,
                selectedDateFormat: $viewModel.selectedDateFormat,
                onConfirm: {
                    // Re-map rows with user-selected columns
                    let mappedRows = rows.map { row -> ParsedRow in
                        let keys = Array(row.rawColumns.keys.sorted())
                        var mapped = row
                        if let di = viewModel.dateColumnIndex, di < keys.count {
                            mapped.date = DateHelpers.parseDate(
                                row.rawColumns[keys[di]] ?? "",
                                format: viewModel.selectedDateFormat
                            )
                        }
                        if let dsi = viewModel.descriptionColumnIndex, dsi < keys.count {
                            mapped.description = row.rawColumns[keys[dsi]]
                        }
                        if let ai = viewModel.amountColumnIndex, ai < keys.count {
                            mapped.amount = ColumnMapper.parseAmount(row.rawColumns[keys[ai]] ?? "")
                        }
                        return mapped
                    }
                    viewModel.confirmImport(
                        rows: mappedRows, fileName: fileName,
                        fileSize: fileSize, month: selectedMonth
                    )
                },
                onCancel: { viewModel.reset() }
            )

        case .importing:
            ProgressView("Importing transactions...")
                .padding()

        case .done(let count):
            VStack(spacing: 16) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.green)
                Text("Successfully imported \(count) transactions!")
                    .font(.headline)

                if !viewModel.importedMonthBreakdown.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transactions by month:")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        ForEach(viewModel.importedMonthBreakdown, id: \.month) { entry in
                            HStack {
                                Text(DateHelpers.displayMonth(entry.month))
                                    .font(.subheadline)
                                Spacer()
                                Text("\(entry.count) transactions")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding()
                    .background(Color(nsColor: .controlBackgroundColor))
                    .cornerRadius(8)
                    .frame(maxWidth: 300)
                }

                Button("Import Another") { viewModel.reset() }
                    .buttonStyle(.bordered)
            }
            .padding()

        case .error(let message):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.orange)
                Text(message)
                    .foregroundStyle(.secondary)
                Button("Try Again") { viewModel.reset() }
                    .buttonStyle(.bordered)
            }
            .padding()
        }
    }

    private var dropZone: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .foregroundStyle(isTargeted ? .blue : .secondary)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(isTargeted ? Color.blue.opacity(0.05) : Color.clear)
                )

            VStack(spacing: 12) {
                Image(systemName: "arrow.down.doc.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(isTargeted ? .blue : .secondary)

                Text("Drop bank statements here")
                    .font(.title3)
                    .fontWeight(.medium)

                Text("Supports CSV, TSV, PDF, OFX, QFX, QIF, XLSX")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 200)
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            handleDrop(providers: providers)
            return true
        }
    }

    private var importedFilesList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Imported Files")
                .font(.headline)
                .padding(.horizontal)
                .padding(.top, 12)

            Text(DateHelpers.displayMonth(selectedMonth))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if viewModel.importedFiles.isEmpty {
                VStack {
                    Spacer()
                    Text("No files imported\nfor this month")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List {
                    ForEach(viewModel.importedFiles) { file in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(file.fileName)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                    .lineLimit(1)
                                if file.isMultiMonth {
                                    Text("Multi-month")
                                        .font(.caption2)
                                        .padding(.horizontal, 5)
                                        .padding(.vertical, 1)
                                        .background(Color.blue.opacity(0.15))
                                        .foregroundStyle(.blue)
                                        .cornerRadius(4)
                                }
                            }

                            HStack {
                                Text("\(file.transactionCount) transactions")
                                Spacer()
                                Text(DateHelpers.shortDate(file.importedAt))
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                        .contextMenu {
                            Button(role: .destructive) {
                                fileToDelete = file
                                showDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
            }
        }
    }

    private func handleDrop(providers: [NSItemProvider]) {
        for provider in providers {
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                guard let data = item as? Data,
                      let url = URL(dataRepresentation: data, relativeTo: nil)
                else { return }

                DispatchQueue.main.async {
                    viewModel.processFile(url: url, month: selectedMonth)
                }
            }
        }
    }
}
