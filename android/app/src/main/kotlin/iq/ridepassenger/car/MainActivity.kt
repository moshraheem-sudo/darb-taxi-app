package iq.ridepassenger.car

import android.content.Intent
import android.net.Uri
import android.speech.tts.TextToSpeech
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity(), TextToSpeech.OnInitListener {
    private val navChannel = "iq.ridepassenger.car/external_nav"
    private val ttsChannel = "iq.ridepassenger.car/tts"
    private var tts: TextToSpeech? = null
    private var ttsReady = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        tts = TextToSpeech(this, this)

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

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ttsChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "speakArabic" -> {
                        val text = call.argument<String>("text") ?: ""
                        if (ttsReady && text.isNotBlank()) {
                            tts?.speak(text, TextToSpeech.QUEUE_FLUSH, null, "darb_nav")
                        }
                        result.success(null)
                    }
                    "stop" -> {
                        tts?.stop()
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    override fun onInit(status: Int) {
        if (status == TextToSpeech.SUCCESS) {
            val res = tts?.setLanguage(Locale("ar"))
            ttsReady = res != TextToSpeech.LANG_MISSING_DATA &&
                res != TextToSpeech.LANG_NOT_SUPPORTED
        }
    }

    override fun onDestroy() {
        tts?.stop()
        tts?.shutdown()
        super.onDestroy()
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
