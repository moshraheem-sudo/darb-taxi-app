import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

enum IraqiNavApp { ask, dahliz, darbuna }

enum ExternalNavLaunchResult { launched, unsupportedGeo, notInstalled }

/// Handles safe, manual external navigation handoff to Iraqi navigation apps
/// (Dahliz & Darbuna) using exact stored coordinates and no customer PII.
class IraqiNavigationService {
  const IraqiNavigationService._();

  static const _channel = MethodChannel('iq.ridepassenger.car/external_nav');
  static const _prefKey = 'darb_captain_preferred_nav_v1';

  static const String dahlizPackage = 'com.ms.jaber.wain';
  static const String darbunaPackage = 'iq.darbuna.app';

  static const String darbunaAndroidUrl =
      'https://play.google.com/store/apps/details?id=iq.darbuna.app';
  static const String darbunaIosUrl =
      'https://apps.apple.com/iq/app/%D8%AF%D8%B1%D8%A8%D9%88%D9%86%D8%A9-%D8%AA%D8%B7%D8%A8%D9%8A%D9%82-%D8%A7%D9%84%D9%85%D9%84%D8%A7%D8%AD%D8%A9-%D8%A7%D9%84%D8%B9%D8%B1%D8%A7%D9%82%D9%8A/id6823260015';
  static const String dahlizAndroidUrl = 'https://dahliz.app/ar/';
  static const String dahlizIosUrl =
      'https://apps.apple.com/us/app/%D8%AF%D9%87%D9%84%D9%8A%D8%B2-dahliz/id6813242600';

  static String storeUrlFor(IraqiNavApp app) {
    final isIos = defaultTargetPlatform == TargetPlatform.iOS;
    return switch (app) {
      IraqiNavApp.dahliz => isIos ? dahlizIosUrl : dahlizAndroidUrl,
      IraqiNavApp.darbuna => isIos ? darbunaIosUrl : darbunaAndroidUrl,
      IraqiNavApp.ask => darbunaAndroidUrl,
    };
  }

  static String packageFor(IraqiNavApp app) =>
      app == IraqiNavApp.dahliz ? dahlizPackage : darbunaPackage;

  static String labelFor(IraqiNavApp app) => switch (app) {
    IraqiNavApp.ask => 'السؤال في كل مرة',
    IraqiNavApp.dahliz => 'دهليز (Dahliz)',
    IraqiNavApp.darbuna => 'دربونة (Darbuna)',
  };

  /// Builds standard `geo:` URI with exact stored destination coordinates.
  /// Never rounds coordinates, replaces with GPS, or includes customer PII.
  static String buildExactGeoUri(double destLat, double destLng) =>
      'geo:$destLat,$destLng?q=$destLat,$destLng';

  static Future<IraqiNavApp> loadPreferredNavApp() async {
    final prefs = await SharedPreferences.getInstance();
    switch (prefs.getString(_prefKey)) {
      case 'dahliz':
        return IraqiNavApp.dahliz;
      case 'darbuna':
        return IraqiNavApp.darbuna;
      default:
        return IraqiNavApp.ask;
    }
  }

  static Future<void> savePreferredNavApp(IraqiNavApp app) async {
    final prefs = await SharedPreferences.getInstance();
    final raw = switch (app) {
      IraqiNavApp.dahliz => 'dahliz',
      IraqiNavApp.darbuna => 'darbuna',
      IraqiNavApp.ask => 'ask',
    };
    await prefs.setString(_prefKey, raw);
  }

  static Future<bool> isAppInstalled(IraqiNavApp app) async {
    if (app == IraqiNavApp.ask) return false;
    try {
      final res = await _channel.invokeMethod<bool>('isAppInstalled', {
        'packageName': packageFor(app),
      });
      return res == true;
    } catch (_) {
      return false;
    }
  }

  static Future<ExternalNavLaunchResult> launchExternalNav({
    required IraqiNavApp app,
    required double destLat,
    required double destLng,
  }) async {
    if (app == IraqiNavApp.ask) return ExternalNavLaunchResult.unsupportedGeo;
    final geoUri = buildExactGeoUri(destLat, destLng);
    try {
      final res = await _channel.invokeMethod<String>('launchGeoUri', {
        'packageName': packageFor(app),
        'geoUri': geoUri,
      });
      switch (res) {
        case 'launched':
          return ExternalNavLaunchResult.launched;
        case 'not_installed':
          return ExternalNavLaunchResult.notInstalled;
        default:
          return ExternalNavLaunchResult.unsupportedGeo;
      }
    } catch (_) {
      return ExternalNavLaunchResult.unsupportedGeo;
    }
  }

  static Future<void> openStoreForApp(IraqiNavApp app) async {
    await launchUrl(
      Uri.parse(storeUrlFor(app)),
      mode: LaunchMode.externalApplication,
    );
  }
}
