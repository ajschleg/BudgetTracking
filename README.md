# BudgetTracking

A macOS app for tracking monthly household budgets. Import bank statements, categorize transactions automatically, and monitor spending across customizable budget categories. Supports iCloud sync so multiple users can share the same budget.

## Requirements

- macOS 14.0+
- Xcode 16+
- Apple Developer account (for CloudKit sync and code signing)

## Installation

### 1. Clone the repository

```bash
git clone https://github.com/ajschleg/BudgetTracking.git
cd BudgetTracking
```

### 2. Open in Xcode

Open the Xcode project (not the Package.swift):

```bash
open BudgetTracking.xcodeproj
```

### 3. Configure signing

1. Select the **BudgetTracking** target
2. Go to **Signing & Capabilities**
3. Select your **Team** from the dropdown
4. Xcode will automatically manage provisioning profiles

### 4. Build and run

Press **⌘R** to build and run the app.

### Alternative: Command line (without CloudKit)

If you don't need iCloud sync, you can build and run via SwiftPM:

```bash
swift build
swift run BudgetTracking
```

Note: CloudKit sync requires the Xcode project with entitlements and code signing.

## Features

### Dashboard
- Overview of monthly spending vs. budget for each category
- Color-coded progress bars (green < 70%, yellow 70-90%, red > 90%)
- Click a category to expand and see individual transactions
- Month selector to navigate between months

### Import Statements
- Drag and drop bank statements to import transactions
- Supported formats: **CSV**, **TSV**, **OFX/QFX**, **QIF**, **PDF**, **XLSX**
- Auto-detects columns, date formats, and sign conventions
- Handles multi-month files (e.g., yearly Chase activity exports) — transactions are automatically sorted into the correct months
- Duplicate file detection with replace/import anyway options

### Transactions
- Searchable list of all transactions for a given month
- Filter by category
- Change a transaction's category — the app learns from your choice and auto-updates similar transactions

### Categories
- 9 default budget categories (Groceries, Dining Out, Gas, etc.)
- Double-click category name or budget amount to edit inline
- Add custom categories with color picker
- Archive categories you no longer need
- Manage categorization rules (keyword → category mappings)

### History
- Monthly summaries showing total spending vs. budget
- Click a month to see the full category breakdown

### iCloud Sync
- Automatic sync via CloudKit (CKSyncEngine)
- Share your budget with your spouse — both can view and edit the same data
- Conflict resolution: manual categorizations take priority; otherwise last-writer-wins
- Sync status indicator in the sidebar

## How It Works

### Auto-Categorization

When you import a statement, transactions are categorized in this order:

1. **Bank source category** — If the bank provides a category (e.g., Apple Card's "Groceries"), it's mapped to your app categories
2. **Keyword rules** — 70+ built-in rules match transaction descriptions to categories (e.g., "WHOLE FOODS" → Groceries)
3. **Learned rules** — When you manually re-categorize a transaction, the app creates a rule and bulk-updates all similar transactions in that month

### Data Storage

- Local SQLite database via [GRDB](https://github.com/groue/GRDB.swift) at `~/Library/Application Support/BudgetTracking/budget.sqlite`
- CloudKit sync to `iCloud.com.schlegel.BudgetTracking` container
- All deletes are soft deletes to support sync (records marked `isDeleted` rather than removed)

## Setting Up iCloud Sync

### For the primary user (owner)

1. Sign in to iCloud on your Mac
2. Open the app — sync starts automatically
3. Go to **Sync** in the sidebar
4. Click **Share Budget** to invite your spouse

### For the secondary user (participant)

1. Clone the repo and open in Xcode
2. Update the **Team** in Signing & Capabilities to your own Apple Developer team
3. Build and run
4. Accept the share invitation from the owner

## Project Structure

```
BudgetTracking/
├── Package.swift                    # SwiftPM dependencies
├── project.yml                      # xcodegen project config
├── BudgetTracking.entitlements      # CloudKit + Push entitlements
├── BudgetTracking.xcodeproj/        # Generated Xcode project
├── Sources/BudgetTracking/
│   ├── BudgetTrackingApp.swift      # App entry point
│   ├── ContentView.swift            # Sidebar navigation
│   ├── Database/
│   │   └── DatabaseManager.swift    # GRDB database layer
│   ├── Models/                      # Data models (GRDB + Codable)
│   ├── ViewModels/                  # @Observable view models
│   ├── Views/                       # SwiftUI views
│   ├── Parsing/                     # Statement parsers (CSV, PDF, OFX, etc.)
│   ├── Categorization/              # Auto-categorization engine
│   ├── Sync/                        # CloudKit sync layer
│   │   ├── SyncEngine.swift         # CKSyncEngineDelegate
│   │   ├── RecordConverter.swift    # Model ↔ CKRecord conversion
│   │   ├── ShareManager.swift       # CKShare management
│   │   ├── ConflictResolver.swift   # Sync conflict resolution
│   │   ├── SyncConstants.swift      # Container/zone identifiers
│   │   └── SyncStateStore.swift     # Persists sync engine state
│   └── Utilities/                   # Helpers (date, currency, color)
├── Tests/BudgetTrackingTests/       # Unit tests
└── TestFixtures/                    # Test data files
```

## Dependencies

- [GRDB](https://github.com/groue/GRDB.swift) — SQLite database toolkit
- [CoreXLSX](https://github.com/CoreOffice/CoreXLSX) — Excel file parsing
- [CodableCSV](https://github.com/dehesa/CodableCSV) — CSV parsing
- CloudKit (Apple framework) — iCloud sync

## Regenerating the Xcode Project

If you modify `project.yml`, regenerate the Xcode project:

```bash
brew install xcodegen  # if not installed
xcodegen generate
```
