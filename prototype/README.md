# Lifecycle prototype

This is an isolated technical prototype, not the product UI.

Scope: a native Windows tray owns a sing-box child process; a Flutter UI may exit and reconnect without stopping the core. No system proxy settings or TUN are enabled by this prototype.

Android platform tools / ADB must not be installed. Android runtime checks are deferred.

The tray control pipe must be restricted to the current user. Core configuration uses only a local mixed inbound and direct outbound, so no subscription or credentials are needed.

Validation must distinguish source review, successful compilation, and actual runtime results. TUN elevation and Android VPN remain unverified until explicitly authorized runtime checks.
