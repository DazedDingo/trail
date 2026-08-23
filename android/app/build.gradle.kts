plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dazeddingo.trail"
    // 37, not `flutter.compileSdkVersion` (36 on Flutter 3.47.1):
    // flutter_secure_storage 11 sets `compileSdk = 37` and publishes AAR
    // metadata demanding the same of anything that depends on it, so a 36
    // app fails `checkAarMetadata` outright. AGP 9.1.0 only *recommends*
    // 36 (a warning, suppressed below); targetSdk stays on Flutter's
    // value, so no runtime behaviour changes.
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    defaultConfig {
        applicationId = "com.dazeddingo.trail"
        // API 24 explicitly. Flutter 3.41+'s MinSdkVersionMigration used to
        // rewrite the old `23` in the working copy on every build (including
        // CI), so the shipped APKs were already effectively 24 — the
        // committed 23 was nominal and only ever caused diff noise.
        // flutter_secure_storage 11 (release B of the 9 → 10 → 11 migration)
        // makes 24 a hard floor anyway.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Pinned debug keystore (android/app/debug.keystore, committed).
        // Every build — local and CI — signs against this exact keystore so
        // APKs produced at any time install as upgrades without an uninstall.
        // Before this, AGP silently generated a fresh `~/.android/debug.keystore`
        // on each CI run and every release had a different SHA, forcing users
        // to uninstall before installing the new APK.
        getByName("debug") {
            storeFile = file("debug.keystore")
            storePassword = "android"
            keyAlias = "androiddebugkey"
            keyPassword = "android"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
        }
    }
}

dependencies {
    // flutter_local_notifications uses java.time APIs — core library
    // desugaring lets them work below API 26.
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.2")

    // androidx.work is no longer exported transitively by workmanager 0.9.x
    // (was an `api` dep in 0.5.x, now `implementation`). BootReceiver.kt
    // references WorkManager / OneTimeWorkRequestBuilder / ExistingWorkPolicy
    // directly, so we need to declare it ourselves. Version pinned to match
    // workmanager_android-0.9.0+2's transitive dep to avoid double-classpath
    // surprises.
    implementation("androidx.work:work-runtime-ktx:2.10.2")

    // MapLibre Native Android — declared directly so MapLibreLogTrap.kt
    // can reference `org.maplibre.android.log.{Logger,LoggerDefinition}`.
    // maplibre_gl 0.26.0 already pulls this in as a transitive dep, but
    // its `implementation` scope hides the classes from the app module's
    // classpath. We add it as compileOnly here — the actual runtime
    // resolution still goes through maplibre_gl + the resolutionStrategy
    // override above (13.0.3-pre0).
    compileOnly("org.maplibre.gl:android-sdk-opengl:13.0.+")

    // zip4j writes the standard AES-256 encrypted zips that 7-Zip,
    // macOS Archive Utility (with the StuffIt-friendly variant) and
    // Linux `7z x` open out of the box. EncryptedZipPlugin wraps the
    // exported GPX/CSV files in one of these so the recipient never
    // needs Trail-specific tooling — the previous TRLENC01 format
    // required a Python decrypt script and was friction.
    implementation("net.lingala.zip4j:zip4j:2.11.5")
}

// Pin the maplibre-native Android SDK to the latest pre-release on top
// of `maplibre_gl 0.26.0`'s default `13.0.+` resolution. The +38 build
// confirmed local-file MBTiles/PMTiles fails to render under stable
// 13.0.2; trying 13.0.3-pre0 before falling through to the localhost
// HTTP-server workaround (cheaper if the upstream pre-release happens
// to fix it).
configurations.all {
    resolutionStrategy.eachDependency {
        if (requested.group == "org.maplibre.gl" &&
            requested.name == "android-sdk-opengl") {
            useVersion("13.0.3-pre0")
            because("Trying upstream pre-release before HTTP-server workaround")
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
