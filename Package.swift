// swift-tools-version:5.9
import PackageDescription

// AmbixDeals is the Foundation-only deals wire codec shared between Ambix Station and
// Ambix Daisho: Money, FirestoreValue, MirrorWrite/MirrorEmitting, Deal, DealDraft,
// DraftValidation, DealsSettings, and CostFloorPolicy. It has NO Firebase dependency and
// NO dependencies of any kind, so it compiles and unit-tests on any platform (incl. CI on
// Linux). It is extracted byte-identical from AmbixStationCore (see README for the
// extraction record and the lockstep rules that keep it that way).
let package = Package(
    name: "AmbixDeals",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "AmbixDeals", targets: ["AmbixDeals"]),
    ],
    targets: [
        .target(
            name: "AmbixDeals",
            path: "Sources/AmbixDeals"
        ),
        .testTarget(
            name: "AmbixDealsTests",
            dependencies: ["AmbixDeals"],
            path: "Tests/AmbixDealsTests"
        ),
    ]
)
