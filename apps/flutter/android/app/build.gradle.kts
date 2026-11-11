plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.clashhalo.halo"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.clashhalo.halo"
        // Raised from flutter.minSdkVersion (24) to 29 by decision (2026-11-08):
        // Android 10. findConnectionOwner needs API 29, and the test device
        // (HarmonyOS 2.0) is API 29.
        minSdk = 29
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // libbox is built for arm64 only (the pinned mobile core). Shipping
        // Flutter's armeabi-v7a/x86_64 payloads would install on devices where
        // starting the VPN fails with UnsatisfiedLinkError. Restrict the APK
        // instead; an x86_64 emulator needs a libbox build for that ABI.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    // `ndk.abiFilters` only governs libraries built by the NDK; Flutter's
    // prebuilt libapp/libflutter and sqlite3 arrive as jniLibs. Exclude the
    // other ABIs at packaging so the APK cannot install on a device where
    // libbox is absent.
    packaging {
        jniLibs {
            excludes += setOf("lib/armeabi-v7a/**", "lib/x86_64/**")
        }
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

// Brings the :vpn service (native/android/vpn) and its manifest — the :vpn
// process boundary — into the APK.
dependencies {
    implementation(project(":vpn"))
}
