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
        // record_android needs ≥ 23 (Android 6.0). Use maxOf so any IDE
        // / Flutter migrator that resets `flutter.minSdkVersion` to 21 will
        // still produce 23 here. DO NOT change to a plain assignment.
        minSdk = maxOf(23, flutter.minSdkVersion)
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
    }

    buildTypes {
        release {
            // Picks up the upload keystore when CI / the dev provided
            // one via `android/key.properties`; falls back to the
            // debug keys so `flutter run --release` still works on a
            // bare checkout.
            signingConfig = if (hasUploadKey) {
                signingConfigs.getByName("upload")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

flutter {
    source = "../.."
}
