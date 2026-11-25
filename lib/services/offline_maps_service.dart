import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class IraqRegion {
  const IraqRegion({
    required this.id,
    required this.nameAr,
    required this.nameEn,
    required this.minLat,
    required this.maxLat,
    required this.minLng,
    required this.maxLng,
    required this.minZoom,
    required this.maxZoom,
    this.isAllIraq = false,
  });

  final String id;
  final String nameAr;
  final String nameEn;
  final double minLat;
  final double maxLat;
  final double minLng;
  final double maxLng;
  final int minZoom;
  final int maxZoom;
  final bool isAllIraq;

  LatLng get center => LatLng((minLat + maxLat) / 2, (minLng + maxLng) / 2);

  LatLngBounds get bounds =>
      LatLngBounds(LatLng(minLat, minLng), LatLng(maxLat, maxLng));

  List<LatLng> get boxPolygon => [
    LatLng(maxLat, minLng),
    LatLng(maxLat, maxLng),
    LatLng(minLat, maxLng),
    LatLng(minLat, minLng),
  ];
}

class DownloadedRegionInfo {
  const DownloadedRegionInfo({
    required this.regionId,
    required this.tileCount,
    required this.sizeBytes,
    required this.updatedAt,
  });

  final String regionId;
  final int tileCount;
  final int sizeBytes;
  final DateTime updatedAt;

  double get sizeMb => sizeBytes / (1024 * 1024);

  Map<String, dynamic> toJson() => {
    'region_id': regionId,
    'tile_count': tileCount,
    'size_bytes': sizeBytes,
    'updated_at': updatedAt.toIso8601String(),
  };

  factory DownloadedRegionInfo.fromJson(Map<String, dynamic> json) =>
      DownloadedRegionInfo(
        regionId: (json['region_id'] ?? '').toString(),
        tileCount: (json['tile_count'] as num?)?.toInt() ?? 0,
        sizeBytes: (json['size_bytes'] as num?)?.toInt() ?? 0,
        updatedAt:
            DateTime.tryParse((json['updated_at'] ?? '').toString()) ??
            DateTime.now(),
      );
}

class OfflineMapsService {
  OfflineMapsService._();
  static final OfflineMapsService instance = OfflineMapsService._();

  static const _prefsKey = 'darb_offline_regions_v1';

  static const List<IraqRegion> regions = [
    IraqRegion(
      id: 'all_iraq',
      nameAr: 'كل العراق',
      nameEn: 'All Iraq',
      minLat: 29.06,
      maxLat: 37.38,
      minLng: 38.79,
      maxLng: 48.62,
      minZoom: 6,
      maxZoom: 11,
      isAllIraq: true,
    ),
    IraqRegion(
      id: 'baghdad',
      nameAr: 'بغداد',
      nameEn: 'Baghdad',
      minLat: 33.15,
      maxLat: 33.48,
      minLng: 44.18,
      maxLng: 44.56,
      minZoom: 10,
      maxZoom: 14,
    ),
    IraqRegion(
      id: 'wasit',
      nameAr: 'واسط',
      nameEn: 'Wasit',
      minLat: 32.10,
      maxLat: 33.20,
      minLng: 45.20,
      maxLng: 46.40,
      minZoom: 10,
      maxZoom: 14,
    ),
    IraqRegion(
      id: 'basra',
      nameAr: 'البصرة',
      nameEn: 'Basra',
      minLat: 29.95,
      maxLat: 31.10,
      minLng: 47.20,
      maxLng: 48.45,
      minZoom: 10,
      maxZoom: 14,
    ),
    IraqRegion(
      id: 'ninawa',
      nameAr: 'نينوى',
      nameEn: 'Nineveh',
      minLat: 35.80,
      maxLat: 36.80,
      minLng: 42.20,
      maxLng: 43.65,
      minZoom: 10,
      maxZoom: 13,
    ),
    IraqRegion(
      id: 'erbil',
      nameAr: 'أربيل',
      nameEn: 'Erbil',
      minLat: 35.85,
      maxLat: 36.95,
      minLng: 43.65,
      maxLng: 44.85,
      minZoom: 10,
      maxZoom: 13,
    ),
    IraqRegion(
      id: 'sulaymaniyah',
      nameAr: 'السليمانية',
      nameEn: 'Sulaymaniyah',
      minLat: 35.10,
      maxLat: 36.35,
      minLng: 44.80,
      maxLng: 46.10,
      minZoom: 10,
      maxZoom: 13,
    ),
    IraqRegion(
      id: 'halabja',
      nameAr: 'حلبجة',
      nameEn: 'Halabja',
      minLat: 35.05,
      maxLat: 35.32,
      minLng: 45.85,
      maxLng: 46.15,
      minZoom: 10,
      maxZoom: 14,
    ),
    IraqRegion(
      id: 'duhok',
      nameAr: 'دهوك',
      nameEn: 'Duhok',
      minLat: 36.70,
      maxLat: 37.35,
      minLng: 42.45,
      maxLng: 43.95,
      minZoom: 10,
      maxZoom: 13,
    ),
    IraqRegion(
      id: 'kirkuk',
      nameAr: 'كركوك',
      nameEn: 'Kirkuk',
      minLat: 34.95,
      maxLat: 35.75,
      minLng: 43.65,
      maxLng: 44.65,
      minZoom: 10,
      maxZoom: 14,
    ),
    IraqRegion(
      id: 'salah_al_din',
      nameAr: 'صلاح الدين',
      nameEn: 'Salah al-Din',
      minLat: 33.85,
      maxLat: 35.25,
      minLng: 43.10,
      maxLng: 44.50,
      minZoom: 10,
      maxZoom: 13,
    ),
    IraqRegion(
      id: 'diyala',
      nameAr: 'ديالى',
      nameEn: 'Diyala',
      minLat: 33.40,
      maxLat: 34.80,
      minLng: 44.45,
      maxLng: 45.65,
      minZoom: 10,
      maxZoom: 13,
    ),
    IraqRegion(
      id: 'anbar',
      nameAr: 'الأنبار',
      nameEn: 'Anbar',
      minLat: 32.80,
      maxLat: 34.65,
      minLng: 40.20,
      maxLng: 43.90,
      minZoom: 9,
      maxZoom: 12,
    ),
    IraqRegion(
      id: 'babil',
      nameAr: 'بابل',
      nameEn: 'Babil',
      minLat: 32.20,
      maxLat: 33.00,
      minLng: 44.15,
      maxLng: 44.85,
      minZoom: 10,
      maxZoom: 14,
    ),
    IraqRegion(
      id: 'karbala',
      nameAr: 'كربلاء',
      nameEn: 'Karbala',
      minLat: 32.40,
      maxLat: 32.80,
      minLng: 43.75,
      maxLng: 44.20,
      minZoom: 10,
      maxZoom: 14,
    ),
    IraqRegion(
      id: 'najaf',
      nameAr: 'النجف',
      nameEn: 'Najaf',
      minLat: 31.40,
      maxLat: 32.25,
      minLng: 43.70,
      maxLng: 44.65,
      minZoom: 10,
      maxZoom: 14,
    ),
    IraqRegion(
      id: 'qadisiyah',
      nameAr: 'القادسية',
      nameEn: 'Al-Qadisiyyah',
      minLat: 31.55,
      maxLat: 32.35,
      minLng: 44.55,
      maxLng: 45.45,
      minZoom: 10,
      maxZoom: 14,
    ),
    IraqRegion(
      id: 'muthanna',
      nameAr: 'المثنى',
      nameEn: 'Al-Muthanna',
      minLat: 29.90,
      maxLat: 31.55,
      minLng: 44.50,
      maxLng: 46.00,
      minZoom: 9,
      maxZoom: 13,
    ),
    IraqRegion(
      id: 'dhi_qar',
      nameAr: 'ذي قار',
      nameEn: 'Dhi Qar',
      minLat: 30.70,
      maxLat: 31.80,
      minLng: 45.85,
      maxLng: 46.95,
      minZoom: 10,
      maxZoom: 14,
    ),
    IraqRegion(
      id: 'maysan',
      nameAr: 'ميسان',
      nameEn: 'Maysan',
      minLat: 31.35,
      maxLat: 32.65,
      minLng: 46.60,
      maxLng: 47.65,
      minZoom: 10,
      maxZoom: 14,
    ),
  ];

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 6),
      receiveTimeout: const Duration(seconds: 8),
      responseType: ResponseType.bytes,
      headers: const {'User-Agent': 'DarbTaxiApp/1.0 (iq.ridepassenger.car)'},
    ),
  );

  Directory? _tilesRoot;

  Future<Directory> _ensureRoot() async {
    if (_tilesRoot != null) return _tilesRoot!;
    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/offline_tiles');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _tilesRoot = dir;
    return dir;
  }

  static (int x, int y) latLngToTile(double lat, double lng, int zoom) {
    final n = 1 << zoom;
    final x = ((lng + 180.0) / 360.0 * n).floor().clamp(0, n - 1);
    final latRad = lat * math.pi / 180.0;
    final y =
        ((1.0 -
                    math.log(math.tan(latRad) + 1.0 / math.cos(latRad)) /
                        math.pi) /
                2.0 *
                n)
            .floor()
            .clamp(0, n - 1);
    return (x, y);
  }

  static List<(int z, int x, int y)> tilesForRegion(IraqRegion region) {
    final tiles = <(int z, int x, int y)>[];
    for (var z = region.minZoom; z <= region.maxZoom; z++) {
      final (xMin, yMax) = latLngToTile(region.minLat, region.minLng, z);
      final (xMax, yMin) = latLngToTile(region.maxLat, region.maxLng, z);
      for (var x = math.min(xMin, xMax); x <= math.max(xMin, xMax); x++) {
        for (var y = math.min(yMin, yMax); y <= math.max(yMin, yMax); y++) {
          tiles.add((z, x, y));
        }
      }
    }
    return tiles;
  }

  static int countTilesForRegion(IraqRegion region) {
    var total = 0;
    for (var z = region.minZoom; z <= region.maxZoom; z++) {
      final (xMin, yMax) = latLngToTile(region.minLat, region.minLng, z);
      final (xMax, yMin) = latLngToTile(region.maxLat, region.maxLng, z);
      total +=
          ((xMax - xMin).abs() + 1) * ((yMax - yMin).abs() + 1);
    }
    return total;
  }

  static double estimateSizeMb(IraqRegion region) =>
      (countTilesForRegion(region) * 14.5) / 1024.0;

  Future<File> _tileFile(int z, int x, int y) async {
    final root = await _ensureRoot();
    return File('${root.path}/$z/$x/$y.png');
  }

  Future<Uint8List?> getCachedTileBytes(int z, int x, int y) async {
    try {
      final file = await _tileFile(z, x, y);
      if (await file.exists()) {
        return await file.readAsBytes();
      }
    } catch (_) {}
    return null;
  }

  Future<void> saveTileBytes(int z, int x, int y, List<int> bytes) async {
    if (bytes.isEmpty) return;
    try {
      final file = await _tileFile(z, x, y);
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      await file.writeAsBytes(bytes, flush: false);
    } catch (_) {}
  }

  Future<Uint8List?> fetchAndCacheTile(int z, int x, int y) async {
    final cached = await getCachedTileBytes(z, x, y);
    if (cached != null) return cached;

    try {
      final res = await _dio.get<List<int>>(
        'https://tile.openstreetmap.org/$z/$x/$y.png',
      );
      final data = res.data;
      if (data != null && data.isNotEmpty) {
        await saveTileBytes(z, x, y, data);
        return Uint8List.fromList(data);
      }
    } catch (_) {}
    return null;
  }

  Future<Map<String, DownloadedRegionInfo>> loadDownloadedRegions() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    if (raw == null || raw.isEmpty) return {};
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      final map = <String, DownloadedRegionInfo>{};
      for (final item in list) {
        if (item is Map) {
          final info = DownloadedRegionInfo.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (info.regionId.isNotEmpty) {
            map[info.regionId] = info;
          }
        }
      }
      return map;
    } catch (_) {
      return {};
    }
  }

  Future<void> _saveDownloadedRegions(
    Map<String, DownloadedRegionInfo> map,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(map.values.map((e) => e.toJson()).toList()),
    );
  }

  Future<DownloadedRegionInfo> downloadRegion(
    IraqRegion region, {
    required void Function(int done, int total) onProgress,
    bool Function()? isCancelled,
  }) async {
    final tiles = tilesForRegion(region);
    final total = tiles.length;
    var done = 0;
    var totalBytes = 0;

    const batchSize = 4;
    for (var i = 0; i < tiles.length; i += batchSize) {
      if (isCancelled?.call() == true) break;
      final batch = tiles.sublist(i, math.min(i + batchSize, tiles.length));
      final results = await Future.wait(
        batch.map((t) => fetchAndCacheTile(t.$1, t.$2, t.$3)),
      );
      for (final bytes in results) {
        if (bytes != null) totalBytes += bytes.length;
      }
      done += batch.length;
      onProgress(done, total);
    }

    final info = DownloadedRegionInfo(
      regionId: region.id,
      tileCount: done,
      sizeBytes: totalBytes,
      updatedAt: DateTime.now(),
    );
    final existing = await loadDownloadedRegions();
    existing[region.id] = info;
    await _saveDownloadedRegions(existing);
    return info;
  }

  Future<void> deleteRegion(String regionId) async {
    final existing = await loadDownloadedRegions();
    existing.remove(regionId);
    await _saveDownloadedRegions(existing);
  }

  /// Pre-caches tiles along an active ride route so the map remains visible
  /// if internet drops mid-trip.
  Future<void> precacheRouteCorridor(List<LatLng> points) async {
    if (points.isEmpty) return;
    final step = math.max(1, (points.length / 12).floor());
    final seen = <String>{};
    for (var i = 0; i < points.length; i += step) {
      final p = points[i];
      for (final z in const [13, 14]) {
        final (cx, cy) = latLngToTile(p.latitude, p.longitude, z);
        for (var dx = -1; dx <= 1; dx++) {
          for (var dy = -1; dy <= 1; dy++) {
            final key = '$z/${cx + dx}/${cy + dy}';
            if (seen.add(key)) {
              unawaited(fetchAndCacheTile(z, cx + dx, cy + dy));
            }
          }
        }
      }
    }
  }
}

/// Offline-first [TileProvider] for `flutter_map` that serves cached disk tiles
/// immediately and caches newly fetched OSM tiles automatically.
class DarbOfflineTileProvider extends TileProvider {
  DarbOfflineTileProvider();

  @override
  ImageProvider getImage(TileCoordinates coordinates, TileLayer options) =>
      _DarbCachedTileImageProvider(
        z: coordinates.z,
        x: coordinates.x,
        y: coordinates.y,
      );
}

class _DarbCachedTileImageProvider
    extends ImageProvider<_DarbCachedTileImageProvider> {
  const _DarbCachedTileImageProvider({
    required this.z,
    required this.x,
    required this.y,
  });

  final int z;
  final int x;
  final int y;

  // Transparent 1x1 PNG fallback when offline and tile is not cached.
  static final Uint8List _transparentPng = Uint8List.fromList([
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
    0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
    0x0A, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49,
    0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
  ]);

  @override
  Future<_DarbCachedTileImageProvider> obtainKey(
    ImageConfiguration configuration,
  ) => SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(
    _DarbCachedTileImageProvider key,
    ImageDecoderCallback decode,
  ) => MultiFrameImageStreamCompleter(
    codec: _loadAsync(key, decode),
    scale: 1.0,
  );

  Future<ui.Codec> _loadAsync(
    _DarbCachedTileImageProvider key,
    ImageDecoderCallback decode,
  ) async {
    final bytes =
        await OfflineMapsService.instance.fetchAndCacheTile(key.z, key.x, key.y);
    final buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes ?? _transparentPng,
    );
    return decode(buffer);
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is _DarbCachedTileImageProvider &&
          other.z == z &&
          other.x == x &&
          other.y == y);

  @override
  int get hashCode => Object.hash(z, x, y);
}
