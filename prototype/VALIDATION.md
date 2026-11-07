# Validation status

## Verified on this machine

- Go 1.27.3, Flutter 3.47.9 and Dart 3.13.7 are project-local; global PATH unchanged.
- Visual Studio Build Tools 2022 17.14 and Windows SDK installed with user authorization.
- Go build and go vet passed. Flutter analyze passed. Flutter Windows release build passed.
- Native Go tray backend started, served current-user-restricted named-pipe requests and exited on command.
- Two Flutter release UI processes (11340, 9172) each connected to the same backend (7196), then exited. Backend remained alive across both runs and was stopped after verification.
- Raw lifecycle result: runtime/lifecycle-result.json. Repeat using verify-lifecycle.ps1 after staging the release under bin/ui.
- Short idle tray-only sample: working set 11.92 MiB, private committed memory 45.91 MiB; CPU time delta 0 seconds over 10 seconds. This is not a full-app or core measurement.
- Official sing-box 1.14.4 Windows archive verified against GitHub release asset SHA-256: 99185d75d314a07dbba4a130c8ad986cbeb629a07927975636b341ca61f991df. Version query and configuration check passed.
- No Android SDK or ADB installed. No system proxy or TUN changes performed.

## Pending / blocked

- Starting the core and issuing an explicit proxy request was rejected by automatic approval review (policy block, no detailed reason). Actual traffic continuity is NOT verified.
- TUN elevation helper, crash recovery and bounded logs are not implemented in this minimal lifecycle slice.
- Android generated scaffold is not an implemented VPN client. Kotlin VPN process, official libbox build, IPC, engine exclusion, UI process exit and runtime validation remain pending.
- Tray process execution passed; visual tray/menu appearance has not been inspected.

## Prototype boundaries

The CLI controller is a temporary adapter from Flutter to the named pipe, not the final native bridge. It launches a short-lived Go process for each command. Core logging truncates on launch and is not production-ready. The test configuration only listens on 127.0.0.1:17893 with direct outbound.

Flutter UI uses a compile-time absolute HALO_BACKEND path for this isolated experiment. Production discovery and single-instance behavior remain to be designed. TUN and device VPN activation require separate user confirmation.
