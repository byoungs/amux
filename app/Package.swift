// swift-tools-version: 5.9
// libvterm commit: 934bc2f ci: bump actions/checkout from 5 to 6 (#13)
// source: https://github.com/neovim/libvterm
import PackageDescription

let package = Package(
    name: "AmuxApp",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CVterm",
            path: "Sources/CVterm",
            sources: [
                "src/vterm.c",
                "src/parser.c",
                "src/state.c",
                "src/screen.c",
                "src/pen.c",
                "src/encoding.c",
                "src/keyboard.c",
                "src/mouse.c",
                "src/unicode.c",
            ],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                // Suppress libvterm's DEBUG_LOG spam (Unknown DEC mode 2026, etc.)
                // Swift debug builds define DEBUG, which enables fprintf to stderr
                // for every unrecognized terminal mode. We don't need these.
                .unsafeFlags(["-UDEBUG"]),
            ]
        ),
        .executableTarget(
            name: "amux-app",
            dependencies: ["CVterm"],
            path: "Sources/AmuxTerm",
            resources: [.copy("amux.icns")]
        ),
    ]
)
