# R8 keep rules for release builds (isMinifyEnabled / isShrinkResources = true,
# see android/app/build.gradle.kts). Flutter's own rules (io.flutter.**) are
# injected automatically by the Flutter Gradle plugin and are NOT duplicated
# here. Every plugin below was checked for shipped consumer rules
# (consumer-rules.pro / proguard-rules.pro / AAR-bundled proguard.txt /
# jar META-INF/proguard/*.pro) before anything was added — see PERF_PLAN
# task notes for the full plugin-by-plugin table. Only add a rule here if
# research shows it's actually needed; most federated Flutter plugins are
# referenced directly by GeneratedPluginRegistrant (a compile-time call, not
# reflection) so R8 keeps them via the ordinary call graph with no help.
#
# Dart obfuscation stays OFF (not enabled in the build) so stack traces
# remain readable — do not add --obfuscate/--split-debug-info to the Flutter
# build, and do not add -dontobfuscate here either.

# ---------------------------------------------------------------------------
# flutter_local_notifications (com.dexterous.flutterlocalnotifications)
# ---------------------------------------------------------------------------
# The plugin's manifest-declared receivers (ScheduledNotificationReceiver,
# ScheduledNotificationBootReceiver, ActionBroadcastReceiver) are already
# kept automatically by R8's default manifest-component rules — no explicit
# -keep needed for those. What IS needed: the plugin persists pending
# notification state via Gson with a custom RuntimeTypeAdapterFactory and
# generic TypeToken usage, which relies on generic-signature reflection that
# R8 strips by default. These rules are copied verbatim from the plugin's
# own example app (flutter_local_notifications-17.2.4/example/android/app/
# proguard-rules.pro), which the README's "Release build configuration"
# section points to.
-keepattributes Signature
-keepattributes *Annotation*
-dontwarn sun.misc.**

-keep class * extends com.google.gson.TypeAdapter
-keep class * implements com.google.gson.TypeAdapterFactory
-keep class * implements com.google.gson.JsonSerializer
-keep class * implements com.google.gson.JsonDeserializer

-keepclassmembers,allowobfuscation class * {
  @com.google.gson.annotations.SerializedName <fields>;
}

-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

# ---------------------------------------------------------------------------
# flutter_secure_storage -> androidx.security:security-crypto -> Tink
# ---------------------------------------------------------------------------
# security-crypto's EncryptedSharedPreferences backs flutter_secure_storage,
# which stores the panic-passphrase-derived SQLCipher key. Neither the
# security-crypto AAR nor the tink-android jar ship a proguard.txt/
# META-INF/proguard/*.pro that protects this: tink-android only bundles a
# narrow rule for its shaded protobuf classes
# (META-INF/proguard/protobuf.pro). Tink's KeyTemplates/KeysetHandle
# machinery resolves proto message types from a `type_url` string embedded
# in the serialized keyset via reflection, which R8 cannot trace statically.
# The plugin's own example app works around this by disabling R8 full mode
# (android.enableR8.fullMode=false in its gradle.properties) instead of
# adding keep rules; we don't own gradle.properties here, and getting this
# wrong would silently corrupt the panic-passphrase flow, so keep the
# whole package instead of chasing individual classes.
-keep class com.google.crypto.tink.** { *; }
-keep interface com.google.crypto.tink.** { *; }
-dontwarn com.google.crypto.tink.**

# ---------------------------------------------------------------------------
# Our own Kotlin (com.dazeddingo.trail.*)
# ---------------------------------------------------------------------------
# All of MainActivity, the plugins (CellWifiPlugin, EncryptedZipPlugin,
# PanicMethodChannel, SchedulerMethodChannel, MapLibreLogTrap), the
# manifest-declared components (BootReceiver, ExactAlarmReceiver,
# PanicForegroundService, PanicTileService, PanicWidgetProvider) and the
# plain helper classes (ExactAlarmScheduler, PanicPrefs, SchedulerPrefs,
# SchedulerEventsLog) are either manifest-declared or reached directly from
# MainActivity/GeneratedPluginRegistrant — no Class.forName/reflection found
# in this package. Keeping it anyway is cheap insurance: the package is tiny
# and this removes an entire class of "which one of ours got stripped"
# debugging if a future addition does add reflection.
-keep class com.dazeddingo.trail.** { *; }
