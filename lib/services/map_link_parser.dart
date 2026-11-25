import 'package:dio/dio.dart';

/// Structured location result extracted from any supported map link or share text.
class ParsedMapLocation {
  const ParsedMapLocation({
    required this.source,
    required this.latitude,
    required this.longitude,
    required this.rawUrl,
    this.placeName,
    this.address,
    this.placeId,
    this.originLatitude,
    this.originLongitude,
    this.originName,
  });

  final String source;
  final double latitude;
  final double longitude;
  final String rawUrl;
  final String? placeName;
  final String? address;
  final String? placeId;
  final double? originLatitude;
  final double? originLongitude;
  final String? originName;

  bool get hasDirections =>
      originLatitude != null && originLongitude != null;
}

/// Parses and validates map links from Google Maps, Apple Maps, OpenStreetMap,
/// Waze, Bing Maps, `geo:` URIs, `darb://` links, and shared WhatsApp/Telegram texts.
class MapLinkParserService {
  const MapLinkParserService._();

  static final RegExp _urlRegex = RegExp(
    r'((?:https?://|geo:|darb://)[^\s<>"\x27\u200f\u200e]+)',
    caseSensitive: false,
  );

  static const Set<String> _shortMapHosts = {
    'maps.app.goo.gl',
    'goo.gl',
  };

  /// Extracts the first supported URL (`https://`, `http://`, `geo:`, `darb://`)
  /// even when embedded inside conversational text.
  static String? extractFirstUrl(String sharedText) {
    final match = _urlRegex.firstMatch(sharedText.trim());
    if (match == null) return null;
    var url = match.group(1)!.trim();
    while (url.isNotEmpty &&
        (url.endsWith('.') ||
            url.endsWith(',') ||
            url.endsWith(')') ||
            url.endsWith('؛'))) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  static bool isValidCoordinate(double? lat, double? lng) {
    if (lat == null || lng == null) return false;
    if (lat.isNaN || lng.isNaN) return false;
    if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return false;
    if (lat == 0 && lng == 0) return false;
    return true;
  }

  static bool isShortMapUrl(Uri uri) {
    final host = uri.host.toLowerCase();
    if (host == 'maps.app.goo.gl') return true;
    if (host == 'goo.gl' && uri.path.startsWith('/maps')) return true;
    return _shortMapHosts.contains(host) && uri.path.contains('maps');
  }

  /// Resolves shortened map links (e.g. `maps.app.goo.gl`) safely and parses
  /// exact coordinates without guessing. Returns `null` if invalid/unsupported.
  static Future<ParsedMapLocation?> resolveAndParse(
    String sharedText, {
    Dio? dio,
  }) async {
    final rawUrl = extractFirstUrl(sharedText);
    if (rawUrl == null) return null;

    final immediate = parseUrl(rawUrl);
    if (immediate != null) return immediate;

    final uri = Uri.tryParse(rawUrl);
    if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
      return null;
    }
    if (!isShortMapUrl(uri)) return null;

    final client = dio ??
        Dio(
          BaseOptions(
            connectTimeout: const Duration(seconds: 6),
            receiveTimeout: const Duration(seconds: 6),
            followRedirects: true,
            maxRedirects: 5,
            validateStatus: (s) => s != null && s < 400,
          ),
        );

    try {
      final response = await client.get<dynamic>(
        rawUrl,
        options: Options(
          responseType: ResponseType.plain,
          validateStatus: (s) => s != null && s < 400,
          headers: const {'User-Agent': 'DarbTaxiApp/1.0'},
        ),
      );
      final locationHeader = response.headers.value('location');
      if (locationHeader != null && locationHeader.isNotEmpty) {
        final parsedHeader = parseUrl(locationHeader);
        if (parsedHeader != null) return parsedHeader;
      }

      final finalUri = response.realUri.toString();
      final parsedFinal = parseUrl(finalUri);
      if (parsedFinal != null) return parsedFinal;

      // Some Google short links embed canonical/meta coordinates in HTML
      final body = response.data?.toString() ?? '';
      final embeddedUrl = extractFirstUrl(body);
      if (embeddedUrl != null && embeddedUrl != rawUrl) {
        return parseUrl(embeddedUrl);
      }
    } catch (_) {
      return null;
    }
    return null;
  }

  /// Synchronously parses any full map URL or `geo:` / `darb://` URI.
  static ParsedMapLocation? parseUrl(String rawUrl) {
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null) return null;

    final scheme = uri.scheme.toLowerCase();
    if (scheme == 'darb') return _parseDarbUri(uri, rawUrl);
    if (scheme == 'geo') return _parseGeoUri(rawUrl);
    if (scheme != 'http' && scheme != 'https') return null;

    final host = uri.host.toLowerCase();
    if (host.contains('google.') || host == 'goo.gl' || host == 'maps.app.goo.gl') {
      return _parseGoogleMaps(uri, rawUrl);
    }
    if (host.contains('maps.apple.com')) {
      return _parseAppleMaps(uri, rawUrl);
    }
    if (host.contains('openstreetmap.org') || host == 'osm.org') {
      return _parseOsm(uri, rawUrl);
    }
    if (host.contains('waze.com')) {
      return _parseWaze(uri, rawUrl);
    }
    if (host.contains('bing.com')) {
      return _parseBingMaps(uri, rawUrl);
    }
    return _parseGenericLatLng(uri, rawUrl, 'رابط موقع');
  }

  static ParsedMapLocation? _parseDarbUri(Uri uri, String rawUrl) {
    final q = uri.queryParameters;
    final dLat = double.tryParse(q['dlat'] ?? q['lat'] ?? '');
    final dLng = double.tryParse(q['dlng'] ?? q['lng'] ?? q['lon'] ?? '');
    if (!isValidCoordinate(dLat, dLng)) return null;

    final oLat = double.tryParse(q['olat'] ?? '');
    final oLng = double.tryParse(q['olng'] ?? '');
    return ParsedMapLocation(
      source: 'رابط درب (Darb)',
      latitude: dLat!,
      longitude: dLng!,
      rawUrl: rawUrl,
      placeName: q['name'] ?? q['dname'],
      address: q['address'],
      originLatitude: isValidCoordinate(oLat, oLng) ? oLat : null,
      originLongitude: isValidCoordinate(oLat, oLng) ? oLng : null,
      originName: q['oname'],
    );
  }

  static ParsedMapLocation? _parseGeoUri(String rawUrl) {
    final match = RegExp(
      r'^geo:(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)(?:;[^\?]*)?(?:\?(.*))?$',
      caseSensitive: false,
    ).firstMatch(rawUrl.trim());
    if (match == null) return null;
    final lat = double.tryParse(match.group(1)!);
    final lng = double.tryParse(match.group(2)!);
    if (!isValidCoordinate(lat, lng)) return null;

    String? placeName;
    final queryPart = match.group(3);
    if (queryPart != null && queryPart.isNotEmpty) {
      final params = Uri.splitQueryString(queryPart);
      final q = params['q'];
      if (q != null) {
        final labelMatch = RegExp(r'\(([^)]+)\)').firstMatch(q);
        if (labelMatch != null) {
          placeName = labelMatch.group(1);
        } else {
          final qPair = _tryParseLatLngPair(q);
          if (qPair == null) placeName = q;
        }
      }
    }
    return ParsedMapLocation(
      source: 'Geo URI',
      latitude: lat!,
      longitude: lng!,
      rawUrl: rawUrl,
      placeName: placeName,
    );
  }

  static ParsedMapLocation? _parseGoogleMaps(Uri uri, String rawUrl) {
    final q = uri.queryParameters;
    final dataIdMatch = RegExp(r'!1s(0x[0-9a-fA-F]+:0x[0-9a-fA-F]+|ChIJ[A-Za-z0-9_-]+)')
        .firstMatch(rawUrl);
    final placeId = q['query_place_id'] ?? q['place_id'] ?? dataIdMatch?.group(1);
    String? placeName;
    final pathPlace = RegExp(r'/maps/place/([^/]+)').firstMatch(uri.path);
    if (pathPlace != null) {
      placeName = Uri.decodeComponent(pathPlace.group(1)!).replaceAll('+', ' ');
    }

    // 1) Directions API format: ?api=1&origin=lat,lng&destination=lat,lng
    final originPair = _tryParseLatLngPair(q['origin'] ?? q['saddr'] ?? '');
    final destPair = _tryParseLatLngPair(
      q['destination'] ?? q['daddr'] ?? '',
    );
    if (destPair != null) {
      return ParsedMapLocation(
        source: 'Google Maps',
        latitude: destPair.$1,
        longitude: destPair.$2,
        rawUrl: rawUrl,
        placeName: placeName,
        placeId: placeId,
        originLatitude: originPair?.$1,
        originLongitude: originPair?.$2,
      );
    }

    // 2) Path directions format: /maps/dir/lat1,lng1/lat2,lng2
    if (uri.path.contains('/maps/dir/')) {
      final segs = uri.pathSegments;
      final dirIdx = segs.indexOf('dir');
      if (dirIdx >= 0) {
        final pairs = <(double, double)>[];
        for (final seg in segs.skip(dirIdx + 1)) {
          final p = _tryParseLatLngPair(Uri.decodeComponent(seg));
          if (p != null) pairs.add(p);
        }
        if (pairs.length >= 2) {
          return ParsedMapLocation(
            source: 'Google Maps',
            latitude: pairs.last.$1,
            longitude: pairs.last.$2,
            rawUrl: rawUrl,
            placeName: placeName,
            placeId: placeId,
            originLatitude: pairs.first.$1,
            originLongitude: pairs.first.$2,
          );
        }
      }
    }

    // 3) !3dLAT!4dLNG (exact pin) takes precedence over @LAT,LNG (viewport)
    final pinMatch = RegExp(
      r'!3d(-?\d+(?:\.\d+)?)!4d(-?\d+(?:\.\d+)?)',
    ).firstMatch(rawUrl);
    if (pinMatch != null) {
      final lat = double.tryParse(pinMatch.group(1)!);
      final lng = double.tryParse(pinMatch.group(2)!);
      if (isValidCoordinate(lat, lng)) {
        return ParsedMapLocation(
          source: 'Google Maps',
          latitude: lat!,
          longitude: lng!,
          rawUrl: rawUrl,
          placeName: placeName,
          placeId: placeId,
        );
      }
    }

    // 4) Query parameters: q, query, ll, center
    for (final key in const ['q', 'query', 'll', 'center']) {
      final val = q[key];
      if (val != null) {
        final pair = _tryParseLatLngPair(val);
        if (pair != null) {
          return ParsedMapLocation(
            source: 'Google Maps',
            latitude: pair.$1,
            longitude: pair.$2,
            rawUrl: rawUrl,
            placeName: placeName,
            placeId: placeId,
          );
        }
        placeName ??= val;
      }
    }

    // 5) Viewport @LAT,LNG
    final atMatch = RegExp(
      r'@(-?\d+(?:\.\d+)?),(-?\d+(?:\.\d+)?)',
    ).firstMatch(rawUrl);
    if (atMatch != null) {
      final lat = double.tryParse(atMatch.group(1)!);
      final lng = double.tryParse(atMatch.group(2)!);
      if (isValidCoordinate(lat, lng)) {
        return ParsedMapLocation(
          source: 'Google Maps',
          latitude: lat!,
          longitude: lng!,
          rawUrl: rawUrl,
          placeName: placeName,
          placeId: placeId,
        );
      }
    }

    return null;
  }

  static ParsedMapLocation? _parseAppleMaps(Uri uri, String rawUrl) {
    final q = uri.queryParameters;
    final saddr = _tryParseLatLngPair(q['saddr'] ?? '');
    final daddr = _tryParseLatLngPair(q['daddr'] ?? '');
    if (daddr != null) {
      return ParsedMapLocation(
        source: 'Apple Maps',
        latitude: daddr.$1,
        longitude: daddr.$2,
        rawUrl: rawUrl,
        placeName: q['q'],
        originLatitude: saddr?.$1,
        originLongitude: saddr?.$2,
      );
    }
    for (final key in const ['ll', 'q', 'sll']) {
      final p = _tryParseLatLngPair(q[key] ?? '');
      if (p != null) {
        return ParsedMapLocation(
          source: 'Apple Maps',
          latitude: p.$1,
          longitude: p.$2,
          rawUrl: rawUrl,
          placeName: q['q'] != null && _tryParseLatLngPair(q['q']!) == null
              ? q['q']
              : q['address'],
          address: q['address'],
        );
      }
    }
    return null;
  }

  static ParsedMapLocation? _parseOsm(Uri uri, String rawUrl) {
    final q = uri.queryParameters;
    final mlat = double.tryParse(q['mlat'] ?? '');
    final mlon = double.tryParse(q['mlon'] ?? '');
    if (isValidCoordinate(mlat, mlon)) {
      return ParsedMapLocation(
        source: 'OpenStreetMap',
        latitude: mlat!,
        longitude: mlon!,
        rawUrl: rawUrl,
      );
    }
    final fragMatch = RegExp(
      r'map=\d+/(-?\d+(?:\.\d+)?)/(-?\d+(?:\.\d+)?)',
    ).firstMatch(uri.fragment);
    if (fragMatch != null) {
      final lat = double.tryParse(fragMatch.group(1)!);
      final lng = double.tryParse(fragMatch.group(2)!);
      if (isValidCoordinate(lat, lng)) {
        return ParsedMapLocation(
          source: 'OpenStreetMap',
          latitude: lat!,
          longitude: lng!,
          rawUrl: rawUrl,
        );
      }
    }
    return null;
  }

  static ParsedMapLocation? _parseWaze(Uri uri, String rawUrl) {
    final q = uri.queryParameters;
    final pair = _tryParseLatLngPair(q['ll'] ?? '') ??
        _tryParseLatLngPair((q['to'] ?? '').replaceFirst('ll.', ''));
    if (pair == null) return null;
    return ParsedMapLocation(
      source: 'Waze',
      latitude: pair.$1,
      longitude: pair.$2,
      rawUrl: rawUrl,
      placeName: q['q'],
    );
  }

  static ParsedMapLocation? _parseBingMaps(Uri uri, String rawUrl) {
    final q = uri.queryParameters;
    final cp = q['cp'];
    if (cp != null) {
      final parts = cp.split('~');
      if (parts.length >= 2) {
        final lat = double.tryParse(parts[0]);
        final lng = double.tryParse(parts[1]);
        if (isValidCoordinate(lat, lng)) {
          return ParsedMapLocation(
            source: 'Bing Maps',
            latitude: lat!,
            longitude: lng!,
            rawUrl: rawUrl,
            placeName: q['q'],
          );
        }
      }
    }
    final w1 = _tryParseLatLngPair(q['where1'] ?? '');
    if (w1 != null) {
      return ParsedMapLocation(
        source: 'Bing Maps',
        latitude: w1.$1,
        longitude: w1.$2,
        rawUrl: rawUrl,
      );
    }
    return null;
  }

  static ParsedMapLocation? _parseGenericLatLng(
    Uri uri,
    String rawUrl,
    String source,
  ) {
    final q = uri.queryParameters;
    final lat = double.tryParse(q['lat'] ?? q['latitude'] ?? '');
    final lng = double.tryParse(q['lng'] ?? q['lon'] ?? q['longitude'] ?? '');
    if (!isValidCoordinate(lat, lng)) return null;
    return ParsedMapLocation(
      source: source,
      latitude: lat!,
      longitude: lng!,
      rawUrl: rawUrl,
      placeName: q['name'] ?? q['q'],
      address: q['address'],
    );
  }

  static (double, double)? _tryParseLatLngPair(String input) {
    final match = RegExp(
      r'^\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)(?:\s.*)?$',
    ).firstMatch(input.trim());
    if (match == null) return null;
    final lat = double.tryParse(match.group(1)!);
    final lng = double.tryParse(match.group(2)!);
    if (!isValidCoordinate(lat, lng)) return null;
    return (lat!, lng!);
  }
}
