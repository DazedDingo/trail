package com.dazeddingo.trail

import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * Standard Flutter host activity. Registers the `com.dazeddingo.trail/cell_wifi`
 * MethodChannel so Flutter can pull passive cell-tower + Wi-Fi info from the
 * native side without triggering active scans (see PLAN.md battery rules).
 *
 * Extends [FlutterFragmentActivity] (NOT [FlutterActivity]) — this is a
 * hard requirement of `local_auth`: the biometric prompt is rendered as a
 * Fragment and needs a FragmentActivity host. Using FlutterActivity makes
 * `LocalAuthentication.authenticate()` throw, which our service swallows
 * into a generic "Authentication failed" with no biometric UI ever shown.
 */
class MainActivity : FlutterFragmentActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        CellWifiPlugin.register(flutterEngine, applicationContext)
    }
}
