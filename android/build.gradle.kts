allprojects {
    repositories {
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
// Force JVM 17 across all Flutter plugins. Some plugins default their Java
// tasks to 1.8 while Kotlin compiles on 17, which breaks with
// "Inconsistent JVM-target compatibility". Aligning both sides here avoids
// per-plugin patching. Must run before `evaluationDependsOn(":app")`.
subprojects {
    afterEvaluate {
        extensions.findByName("android")?.let { ext ->
            val androidExt = ext as com.android.build.gradle.BaseExtension
            androidExt.compileOptions.sourceCompatibility = JavaVersion.VERSION_17
            androidExt.compileOptions.targetCompatibility = JavaVersion.VERSION_17
            // flutter_secure_storage 11 declares `compileSdk = 37`, which AGP
            // 9.1 turns into the platform hash "android-37". No such package
            // exists: Android 17 ships as `platforms;android-37.0` under the
            // new minor-versioned naming, so the build dies with "Failed to
            // find target with hash string 'android-37'". Re-point anything
            // asking for the major-only hash at the one the SDK publishes.
            if (androidExt.compileSdkVersion == "android-37") {
                androidExt.compileSdkVersion("android-37.0")
            }
        }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

// Make sure every Android library subproject really has a Kotlin plugin.
//
// We run AGP 9 with `android.builtInKotlin=false` (what Flutter's 3.47 template
// sets, so the plugins that still apply KGP themselves keep working). In that
// mode Flutter's Gradle plugin is supposed to apply `kotlin-android` to any
// plugin module that doesn't apply it itself — but it decides that by *regex
// scanning the build script text*, and several packages now guard their apply
// with `if (agpMajor < 9) { apply plugin: 'kotlin-android' }`. Flutter sees the
// (dead) line and skips them, so on AGP 9 they end up with no Kotlin plugin at
// all. Two different failure modes we actually hit:
//   - maplibre_gl 0.27.0: its top-level `kotlin { compilerOptions { … } }`
//     block dies with "Could not find method kotlin()".
//   - file_picker 11.0.2: configures fine but silently compiles none of
//     `src/main/kotlin`, so the app fails at GeneratedPluginRegistrant with
//     "cannot find symbol: class FilePickerPlugin".
// Applying KGP here — as soon as a subproject applies AGP, and therefore before
// the rest of its build script runs — fixes both. `pluginManager.apply` is
// idempotent, so modules that go on to apply it themselves are unaffected.
// Drop this block once `android.builtInKotlin=true` is viable for every plugin.
subprojects {
    plugins.withId("com.android.library") {
        pluginManager.apply("kotlin-android")
    }
}

subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
