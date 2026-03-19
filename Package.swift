// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "BudgetTracking",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/CoreOffice/CoreXLSX.git", from: "0.14.0"),
        .package(url: "https://github.com/dehesa/CodableCSV.git", from: "0.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "BudgetTracking",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "CoreXLSX", package: "CoreXLSX"),
                .product(name: "CodableCSV", package: "CodableCSV"),
            ],
            path: "Sources/BudgetTracking"
        ),
        .testTarget(
            name: "BudgetTrackingTests",
            dependencies: ["BudgetTracking"],
            path: "Tests/BudgetTrackingTests"
        ),
    ]
)
