plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.bbsynthetics.akn_chat"
    // Pinned in Phase 4: flutter_local_notifications 22.x requires compileSdk
    // 36, and pinning it means a future Flutter bump cannot silently move it
    // underneath us in either direction.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        // Required by flutter_local_notifications: its scheduling code uses
        // java.time APIs that do not exist below API 26, and desugaring is what
        // back-ports them to our minSdk of 24.
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        // Must match google-services.json and firebase_options.dart
        // (1:525747821627:android:bda2762080925f1895d01e). Changing it makes
        // Firebase fail at RUNTIME with a config error rather than at build
        // time, which is a miserable thing to debug.
        applicationId = "com.bbsynthetics.akn_chat"

        // Firebase Android BoM 34 (FlutterFire BoM 4.17.1) requires minSdk 23.
        // Flutter 3.44 already defaults to 24, comfortably above it; pinned
        // explicitly so a future Flutter bump cannot silently move it.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // minSdk 24 gets native multidex, so this costs nothing and removes a
        // whole class of "method limit exceeded" surprises as Phase 4 and 5
        // add the media and bot dependencies.
        multiDexEnabled = true
    }

    buildTypes {
        release {
            // TODO(owner): a real signing config before the first Play upload.
            // Signing with the debug keys for now, so `flutter run --release`
            // and `flutter install` work on the four staff phones.
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = false
            isShrinkResources = false
        }
    }

    packaging {
        resources {
            excludes += "/META-INF/{AL2.0,LGPL2.1}"
        }
    }
}

dependencies {
    // Pairs with isCoreLibraryDesugaringEnabled above.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.5")
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
