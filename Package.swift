// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ComfyWorkbenchCore",
    platforms: [.iOS(.v15), .macOS(.v12)],
    products: [.library(name: "ComfyWorkbenchCore", targets: ["ComfyWorkbenchCore"]),
               .library(name: "ComfyWorkbenchNetworking", targets: ["ComfyWorkbenchNetworking"])],
    targets: [
        .target(name: "ComfyWorkbenchCore", path: "ComfyWorkbench/Core"),
        .target(name: "ComfyWorkbenchNetworking", path: "ComfyWorkbench/Networking"),
        .testTarget(name: "ComfyWorkbenchCoreTests", dependencies: ["ComfyWorkbenchCore", "ComfyWorkbenchNetworking"], path: "Tests")
    ]
)
