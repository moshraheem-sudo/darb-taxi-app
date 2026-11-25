package iq.ridepassenger.car

import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.speech.tts.TextToSpeech
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.Locale

class MainActivity : FlutterActivity(), TextToSpeech.OnInitListener {
    private val navChannel = "iq.ridepassenger.car/external_nav"
    private val ttsChannel = "iq.ridepassenger.car/tts"
    private val incomingLinksChannel = "iq.ridepassenger.car/incoming_links"
    private val incomingLinksStreamChannel = "iq.ridepassenger.car/incoming_links_stream"
    private var tts: TextToSpeech? = null
    private var ttsReady = false
    private var initialIncomingLink: String? = null
    private var incomingLinksSink: EventChannel.EventSink? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        initialIncomingLink = extractIncomingLink(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val incoming = extractIncomingLink(intent)
        if (!incoming.isNullOrBlank()) {
            if (incomingLinksSink != null) {
                incomingLinksSink?.success(incoming)
            } else {
                initialIncomingLink = incoming
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        tts = TextToSpeech(this, this)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, incomingLinksChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "getInitialLink" -> {
                        val link = initialIncomingLink
                        initialIncomingLink = null
                        result.success(link)
                    }
                    else -> result.notImplemented()
                }
            }

        EventChannel(flutterEngine.dartExecutor.binaryMessenger, incomingLinksStreamChannel)
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                    incomingLinksSink = events
                }

                override fun onCancel(arguments: Any?) {
                    incomingLinksSink = null
                }
            })

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

    private fun extractIncomingLink(intent: Intent?): String? {
        if (intent == null) return null
        return when (intent.action) {
            Intent.ACTION_SEND -> {
                if (intent.type?.startsWith("text/") == true) {
                    intent.getStringExtra(Intent.EXTRA_TEXT)?.trim()?.takeIf { it.isNotEmpty() }
                } else {
                    null
                }
            }
            Intent.ACTION_VIEW -> {
                intent.dataString?.trim()?.takeIf { it.isNotEmpty() }
            }
            else -> null
        }
    }
}
