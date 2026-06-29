// swift-tools-version:5.9
import PackageDescription

// MRIcroCore — the platform-neutral imaging core + unified Metal renderer of
// MRIcroGL, packaged for reuse in other apps WITHOUT the AppKit/UIKit UI.
//
// The package reuses the existing sources in MRIcroX/ in place (no copies, no
// reorganization), so the Xcode app targets (MRIcro/MRIcroPro/MRIcroPad) keep
// building unchanged. The consumable surface is the `nii_img` control seam plus
// NIIMetalRenderer / NIIMetalText (see MRIcroX/include/MRIcroCore.h).
//
// Because the legacy sources rely on a precompiled prefix header (Cocoa/UIKit
// umbrella) and gnu++20, those are injected via unsafe flags; that means this
// package is consumable as a LOCAL PATH or BRANCH dependency (not a versioned
// release-tag dependency, which forbids unsafe flags).
let package = Package(
    name: "MRIcroCore",
    platforms: [
        .macOS(.v11),
        .iOS(.v14),
    ],
    products: [
        .library(name: "MRIcroCore", targets: ["MRIcroCore"]),
    ],
    targets: [
        .target(
            name: "MRIcroCore",
            path: "MRIcroX",
            exclude: [
                // Prefix header (injected via -include, not a source) + project cruft.
                "MRIcro-Prefix.pch", "MRIcro-Info.plist", "CMakeLists.txt", "ucm.cmake",
                "MainWindow.xib", "PrefWindow.xib",
                // Bundled data / localization not needed by the rendering core.
                "atlas", "standard", "Base.lproj", "en.lproj",
                // Single-file zlib clone: #include'd into nii_dicom_batch.cpp, not compiled separately.
                "miniz.c",
                // Duplicate/stub units (the .mm variant is the one the apps compile).
                "nii_ostu_ml.cpp", "nii_colorbar.m",
                // AppKit/UIKit UI layer — intentionally excluded from the package.
                "MRIcroAppDelegate.m", "MySplitViewController.m", "dcm2niiWindow.m",
                "nii_GLView.mm", "nii_WindowController.m", "nii_timelineView.m",
            ],
            resources: [
                .copy("00ShinyWhite.jpg"), // matcap for advanced (gradient-lit) rendering
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("."),
                .define("NII_SWIFTPM"),
                .unsafeFlags(["-include", "MRIcro-Prefix.pch"]),
            ],
            cxxSettings: [
                .headerSearchPath("."),
                .define("NII_SWIFTPM"),
                .unsafeFlags(["-include", "MRIcro-Prefix.pch"]),
            ],
            linkerSettings: [
                .linkedLibrary("z"),
                .linkedFramework("Foundation"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("ImageIO"),
                .linkedFramework("Metal"),
                .linkedFramework("MetalKit"),
                .linkedFramework("Accelerate"),
                .linkedFramework("AppKit", .when(platforms: [.macOS])),
                .linkedFramework("UIKit", .when(platforms: [.iOS])),
            ]
        ),
    ],
    cxxLanguageStandard: .gnucxx20
)
