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

  static const String dahlizPlayUrl =
      'https://play.google.com/store/apps/details?id=$dahlizPackage';
  static const String darbunaPlayUrl =
      'https://play.google.com/store/apps/details?id=$darbunaPackage';

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
    final url = app == IraqiNavApp.dahliz ? dahlizPlayUrl : darbunaPlayUrl;
    await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
  }
}
