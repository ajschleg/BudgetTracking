import SwiftUI
import UniformTypeIdentifiers

struct ImportView: View {
    @Binding var selectedMonth: String
    @Bindable var aiViewModel: InsightsViewModel
    @State private var viewModel = ImportViewModel()
    @State private var isTargeted = false
    @State private var showDeleteConfirmation = false
    @State private var fileToDelete: ImportedFile?
    @State private var bankSources: [BankSource] = BankSource.loadSaved()
    @State private var showAddSource = false
    @State private var newSourceName = ""
    @State private var newSourceURL = ""

    var body: some View {
        VStack(spacing: 0) {
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

            if aiViewModel.isAPIKeyConfigured {
                AIChatBar(
                    viewModel: aiViewModel,
                    actions: [
                        AIChatAction(label: "Help with Import", icon: "sparkles") {
                            await aiViewModel.askAI(page: .importStatements)
                        }
                    ],
                    page: .importStatements
                )
            }
        }
        .navigationTitle("Import Statements")
        .onAppear { viewModel.loadImportedFiles(month: selectedMonth) }
        .onReceive(NotificationCenter.default.publisher(for: .lanSyncDidComplete)) { _ in
            viewModel.loadImportedFiles(month: selectedMonth)
        }
        .onChange(of: selectedMonth) { _, newMonth in
            viewModel.loadImportedFiles(month: newMonth)
            // Only reset when no import is actively in progress.
            // This prevents auto-detection month changes from destroying
            // the preview, while still resetting on manual month changes.
            switch viewModel.state {
            case .idle, .done, .error:
                viewModel.reset()
            default:
                break
            }
        }
        .onChange(of: viewModel.detectedMonth) { _, detected in
            if let detected, detected != selectedMonth {
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
            commonSourcesSection
                .padding(.horizontal)

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

    // MARK: - Common Sources

    private var commonSourcesSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(bankSources) { source in
                    HStack {
                        Link(destination: URL(string: source.url) ?? URL(string: "https://google.com")!) {
                            HStack(spacing: 8) {
                                Image(systemName: "building.columns.fill")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                Text(source.name)
                                    .font(.callout)
                                Image(systemName: "arrow.up.right.square")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if !source.isDefault {
                            Button {
                                withAnimation {
                                    bankSources.removeAll { $0.id == source.id }
                                    BankSource.save(bankSources)
                                }
                            } label: {
                                Image(systemName: "minus.circle")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                withAnimation {
                                    bankSources.removeAll { $0.id == source.id }
                                    BankSource.save(bankSources)
                                }
                            } label: {
                                Image(systemName: "eye.slash")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Hide this source")
                        }
                    }
                }

                Divider()

                if showAddSource {
                    HStack(spacing: 8) {
                        TextField("Bank name", text: $newSourceName)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                        TextField("URL (e.g. chase.com)", text: $newSourceURL)
                            .textFieldStyle(.roundedBorder)
                        Button("Add") {
                            let url = newSourceURL.hasPrefix("http") ? newSourceURL : "https://\(newSourceURL)"
                            let source = BankSource(name: newSourceName, url: url, isDefault: false)
                            withAnimation {
                                bankSources.append(source)
                                BankSource.save(bankSources)
                                newSourceName = ""
                                newSourceURL = ""
                                showAddSource = false
                            }
                        }
                        .disabled(newSourceName.isEmpty || newSourceURL.isEmpty)
                        .buttonStyle(.bordered)
                        .controlSize(.small)

                        Button("Cancel") {
                            showAddSource = false
                            newSourceName = ""
                            newSourceURL = ""
                        }
                        .controlSize(.small)
                    }
                } else {
                    Button {
                        showAddSource = true
                    } label: {
                        Label("Add Source", systemImage: "plus.circle")
                            .font(.callout)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        } label: {
            Label("Common Sources — Download Statements", systemImage: "link")
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
