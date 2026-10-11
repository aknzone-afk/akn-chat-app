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
subprojects {
    project.evaluationDependsOn(":app")
}

// ---------------------------------------------------------------------------
// Phase 4 workaround: make file_picker's Kotlin actually compile.
//
// THE BUG, so nobody has to rediscover it: file_picker 11.0.2's own
// android/build.gradle contains
//
//     def isAgp9OrAbove = ANDROID_GRADLE_PLUGIN_VERSION.tokenize('.')[0] >= 9
//     apply plugin: 'com.android.library'
//     if (!isAgp9OrAbove) { apply plugin: 'org.jetbrains.kotlin.android' }
//
// i.e. on AGP 9+ it deliberately stops applying the Kotlin plugin, assuming
// AGP 9's BUILT-IN Kotlin support will pick the sources up. This project runs
// AGP 9.0.1 — but the Flutter template sets `android.builtInKotlin=false` in
// gradle.properties, so nothing compiles src/main/kotlin at all. The plugin's
// five Kotlin files silently never become classes, and the failure surfaces
// much later and somewhere else entirely:
//
//     GeneratedPluginRegistrant.java: cannot find symbol
//       class FilePickerPlugin
//
// Flipping `android.builtInKotlin=true` globally would also "fix" it, but that
// changes how EVERY module in the build compiles Kotlin — including the app
// module, where the Flutter Gradle plugin already applies the Kotlin plugin
// itself. Two Kotlin toolchains on one module is a worse problem than the one
// being solved. So this is scoped to the single misconfigured subproject.
//
// Remove this block when file_picker ships a build that handles AGP 9
// correctly (12.x is expected to), and verify with a clean
// `flutter build apk --debug`.
// ---------------------------------------------------------------------------
subprojects {
    if (project.name != "file_picker") return@subprojects

    plugins.withId("com.android.library") {
        if (!plugins.hasPlugin("org.jetbrains.kotlin.android")) {
            apply(plugin = "org.jetbrains.kotlin.android")
        }
        // file_picker's own `kotlinOptions { jvmTarget = 17 }` is inside the
        // same `if (!isAgp9OrAbove)` guard, so it is skipped too. Kotlin 2.x
        // defaults to JVM target 1.8 while AGP compiles the Java here at 17,
        // and Gradle fails the build on the mismatch rather than guessing.
        extensions.configure<org.jetbrains.kotlin.gradle.dsl.KotlinAndroidProjectExtension> {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
