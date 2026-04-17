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
                .unsafeFlags(["-UDEBUG"]),
            ]
        ),
        // Shared library: tmux wrappers, layout engine, config, algorithms.
        // No AppKit dependency — usable from both the app and tests.
        .target(
            name: "AmuxLib",
            path: "Sources/AmuxLib"
        ),
        // Native macOS app (terminal emulator + keyboard dispatch)
        .executableTarget(
            name: "amux-app",
            dependencies: ["CVterm", "AmuxLib"],
            path: "Sources/AmuxTerm",
            resources: [.copy("amux.icns")]
        ),
        // CLI for tmux hooks (layout, update-title, alert-pane, bell-watch)
        .executableTarget(
            name: "amux-cli",
            dependencies: ["AmuxLib"],
            path: "Sources/AmuxCLI"
        ),
        // Integration tests — call AmuxLib functions directly against real tmux
        .executableTarget(
            name: "amux-integration-tests",
            dependencies: ["AmuxLib"],
            path: "Tests"
        ),
    ]
)
