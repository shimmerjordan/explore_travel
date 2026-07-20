import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Optional release signing. If `android/key.properties` exists (created
// locally or by the CI workflow from secrets) we load the upload
// keystore details from it and produce a properly-signed APK. Without
// the file we silently fall back to debug-signing so the dev loop
// (`flutter run --release`) keeps working.
val keystorePropertiesFile = rootProject.file("key.properties")
val keystoreProperties = Properties()
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}
val hasUploadKey = keystoreProperties.getProperty("storeFile") != null

// Committed, stable release key (android/keystore/explore-release.jks). Its
// whole point is that EVERY build — local and every CI run — signs release
// APKs with the SAME signature, so users can upgrade in place ("覆盖安装")
// without the "软件包冲突 / 应用未安装" error. Previously release builds with
// no key.properties fell back to the *debug* key, which CI regenerates each
// run → every CI APK had a different signature → no in-place upgrade.
//
// This is a sideload signing key (password is public, in-repo) — fine for
// distributing APKs directly. For Play Store, set the ANDROID_KEYSTORE_*
// secrets / android/key.properties instead; that path still takes precedence.
val stableKeystoreFile = rootProject.file("keystore/explore-release.jks")
val hasStableKey = stableKeystoreFile.exists()

android {
    namespace = "com.explorejournal.explore_journal"
    // flutter_webrtc needs compileSdk >= 36. Take the max so IDE migrators
    // that reset this to flutter.compileSdkVersion still produce ≥36.
    compileSdk = maxOf(36, flutter.compileSdkVersion)
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.explorejournal.explore_journal"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // record_android needs ≥ 23，flutter_tts needs ≥ 24 (Android 7.0)。
        // Use maxOf so any IDE / Flutter migrator that resets
        // `flutter.minSdkVersion` to 21 will still produce 24 here.
        // DO NOT change to a plain assignment.
        minSdk = maxOf(24, flutter.minSdkVersion)
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (hasUploadKey) {
            create("upload") {
                storeFile = file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
        if (hasStableKey) {
            create("stable") {
                storeFile = stableKeystoreFile
                storePassword = "explorejournal"
                keyAlias = "explore"
                keyPassword = "explorejournal"
            }
        }
    }

    buildTypes {
        release {
            // Signing precedence for in-place-upgradeable APKs:
            //   1. android/key.properties  — your own Play Store upload key
            //   2. committed stable key    — same signature everywhere, so
            //      覆盖安装 works out of the box
            //   3. debug key               — last resort (per-machine, NOT
            //      upgrade-compatible across builds; only on a checkout that
            //      somehow lacks the committed keystore)
            signingConfig = when {
                hasUploadKey -> signingConfigs.getByName("upload")
                hasStableKey -> signingConfigs.getByName("stable")
                else -> signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Embedded frpc, built by `gomobile bind` into app/libs/frpmobile.aar
    // (see docs/frp_embed.md / CI). Included only when present so a bare
    // checkout without the gomobile build still compiles — FrpBridge reaches
    // it via reflection and degrades to "unsupported" when it's missing.
    val frpAar = file("libs/frpmobile.aar")
    if (frpAar.exists()) {
        implementation(files(frpAar))
    }
}
