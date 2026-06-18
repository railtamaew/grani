# AmneziaWG binaries

Place amneziawg-go binaries here for desktop GraniWG with obfuscation:

- `macos/arm64/amneziawg-go` — macOS Apple Silicon
- `macos/amd64/amneziawg-go` — macOS Intel
- `windows/tunnel.dll` — Windows GRANIwg/AmneziaWG service DLL loaded by
  the Flutter Windows runner

For Windows development without bundling, set `GRANI_AWG_TUNNEL_DLL` to the
full path of a compatible `tunnel.dll`.

macOS binaries build from: https://github.com/amnezia-vpn/amneziawg-go

Windows `tunnel.dll` builds from: https://github.com/amnezia-vpn/amneziawg-windows

Legacy Windows testing can still use `GRANI_AWG_QUICK` with `awg-quick.exe`,
but the production path is `tunnel.dll` through the Windows Service Control
Manager.
