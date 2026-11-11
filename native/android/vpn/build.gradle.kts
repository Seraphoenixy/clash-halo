// The :vpn library module. Declared in apps/flutter/android/settings.gradle.kts
// with its projectDir here, so the service and its manifest (the :vpn process
// boundary) are compiled into the APK. It deliberately has no dependency on
// Flutter — the VPN process must never initialize a FlutterEngine (方案 §5).
plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "com.clashhalo.vpn"
    // Keep in sync with flutter.compileSdkVersion used by :app (36 in the
    // pinned Flutter 3.47.9); the flutter extension is not available to this
    // plain library module.
    compileSdk = 36

    defaultConfig {
        // Decision (2026-11-08, user): minSdk 29 — Android 10. This matches
        // findConnectionOwner's API 29 requirement and the test device
        // (HarmonyOS 2.0, API 29); API 28 is outside the support range.
        minSdk = 29
        // R8 strips go.Seq$Ref (JNI-only calls) without these rules; see
        // consumer-rules.pro for the failure signature.
        consumerProguardFiles("consumer-rules.pro")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Built from the locked sing-box v1.14.4 source with the official
    // build_libbox flags (arm64, androidapi 24) — see docs/验证记录.md. AGP 9
    // forbids local .aar file deps in library modules, so the AAR is unpacked:
    // libs/libbox.jar (bindings, compile time) + src/main/jniLibs/libbox.so
    // (native runtime). Both are gitignored; re-unpack when the pinned core
    // version changes (aar classes.jar → libs/libbox.jar, jni/<abi>/*.so →
    // src/main/jniLibs/<abi>/).
    implementation(files("libs/libbox.jar"))
}
