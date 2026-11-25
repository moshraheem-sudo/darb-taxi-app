package iq.ridepassenger.car

import android.content.Intent
import android.net.Uri
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val navChannel = "iq.ridepassenger.car/external_nav"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, navChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isAppInstalled" -> {
                        val pkg = call.argument<String>("packageName") ?: ""
                        result.success(isPackageInstalled(pkg))
                    }
                    "launchGeoUri" -> {
                        val pkg = call.argument<String>("packageName") ?: ""
                        val geoUri = call.argument<String>("geoUri") ?: ""
                        result.success(launchExternalGeo(pkg, geoUri))
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun isPackageInstalled(packageName: String): Boolean {
        if (packageName.isBlank()) return false
        return try {
            packageManager.getPackageInfo(packageName, 0)
            true
        } catch (_: Exception) {
            false
        }
    }

    private fun launchExternalGeo(packageName: String, geoUri: String): String {
        if (!isPackageInstalled(packageName)) return "not_installed"
        return try {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(geoUri)).apply {
                setPackage(packageName)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            val resolved = intent.resolveActivity(packageManager)
            if (resolved == null) {
                "unsupported_geo"
            } else {
                startActivity(intent)
                "launched"
            }
        } catch (_: Exception) {
            "unsupported_geo"
        }
    }
}
