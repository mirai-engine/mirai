package workspace

// The platforms the tools the engine downloads are published for.
Target :: enum u8 {Unsupported,Windows_X64,Macos_Arm64,Linux_X64,Linux_Arm64}

when ODIN_OS==.Windows && ODIN_ARCH==.amd64 {
    TARGET :: Target.Windows_X64
} else when ODIN_OS==.Darwin && ODIN_ARCH==.arm64 {
    TARGET :: Target.Macos_Arm64
} else when ODIN_OS==.Linux && ODIN_ARCH==.amd64 {
    TARGET :: Target.Linux_X64
} else when ODIN_OS==.Linux && ODIN_ARCH==.arm64 {
    TARGET :: Target.Linux_Arm64
} else {
    TARGET :: Target.Unsupported
}

// How packages name a platform: `triple` those built with Rust, `node` those
// of npm. "" where none is published under that name.
Target_Names :: struct {triple,node:string}
TARGET_NAMES :: [Target]Target_Names{
    .Unsupported={},
    .Windows_X64={"x86_64-pc-windows-msvc","win32-x64"},
    .Macos_Arm64={"aarch64-apple-darwin","darwin-arm64"},
    .Linux_X64={"x86_64-unknown-linux-musl","linux-x64"},
    .Linux_Arm64={"aarch64-unknown-linux-gnu",""},
}
// The names of the platform this binary runs on.
target_names :: proc "contextless" () -> Target_Names {
    names:=TARGET_NAMES
    return names[TARGET]
}
