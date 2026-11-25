import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/offline_maps_service.dart';

class OfflineMapsPage extends StatefulWidget {
  const OfflineMapsPage({super.key});

  @override
  State<OfflineMapsPage> createState() => _OfflineMapsPageState();
}

class _OfflineMapsPageState extends State<OfflineMapsPage> {
  static const _green = Color(0xFF087F65);

  bool _mapTab = false;
  String? _selectedRegionId = 'wasit';
  String? _downloadingRegionId;
  double _downloadProgress = 0;
  bool _cancelRequested = false;
  Map<String, DownloadedRegionInfo> _downloaded = {};
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final map = await OfflineMapsService.instance.loadDownloadedRegions();
    if (!mounted) return;
    setState(() {
      _downloaded = map;
      _loading = false;
    });
  }

  Future<void> _download(IraqRegion region) async {
    if (_downloadingRegionId != null) return;
    setState(() {
      _downloadingRegionId = region.id;
      _downloadProgress = 0;
      _cancelRequested = false;
    });
    try {
      final info = await OfflineMapsService.instance.downloadRegion(
        region,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _downloadProgress = total == 0 ? 0 : done / total;
          });
        },
        isCancelled: () => _cancelRequested,
      );
      if (!mounted) return;
      final next = Map<String, DownloadedRegionInfo>.from(_downloaded);
      next[region.id] = info;
      setState(() {
        _downloaded = next;
        _downloadingRegionId = null;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _green,
          content: Text('تم تحميل خريطة ${region.nameAr} للاستخدام دون اتصال.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _downloadingRegionId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('تعذر إكمال التحميل. تحقق من اتصال الإنترنت.'),
        ),
      );
    }
  }

  Future<void> _delete(IraqRegion region) async {
    await OfflineMapsService.instance.deleteRegion(region.id);
    if (!mounted) return;
    final next = Map<String, DownloadedRegionInfo>.from(_downloaded);
    next.remove(region.id);
    setState(() => _downloaded = next);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final cs = theme.colorScheme;
    final allIraq = OfflineMapsService.regions.first;
    final governorates = OfflineMapsService.regions.skip(1).toList();
    final selectedRegion = OfflineMapsService.regions.firstWhere(
      (r) => r.id == _selectedRegionId,
      orElse: () => governorates.first,
    );

    return Scaffold(
      appBar: AppBar(
        title: const Text('خرائط دون اتصال'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: dark
                      ? const Color(0xFF1A2825)
                      : _green.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _green.withValues(alpha: 0.25),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.map_outlined, color: _green, size: 28),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'دربك جاهز، حتى بلا إنترنت',
                            style: theme.textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            'حمّل خريطة العراق أو محافظتك لإكمال التنقل عند انقطاع الشبكة.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: cs.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.list_rounded),
                    label: Text('قائمة'),
                  ),
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.public_rounded),
                    label: Text('خريطة'),
                  ),
                ],
                selected: {_mapTab},
                onSelectionChanged: (s) => setState(() => _mapTab = s.first),
              ),
            ),
            const SizedBox(height: 10),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : _mapTab
                      ? _buildIraqMapTab(
                          governorates,
                          allIraq,
                          selectedRegion,
                          dark,
                        )
                      : _buildListTab(allIraq, governorates, theme, cs),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildIraqMapTab(
    List<IraqRegion> governorates,
    IraqRegion allIraq,
    IraqRegion selectedRegion,
    bool dark,
  ) {
    final isDownloaded = _downloaded.containsKey(selectedRegion.id);
    final isDownloading = _downloadingRegionId == selectedRegion.id;
    return Column(
      children: [
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: FlutterMap(
                options: const MapOptions(
                  initialCenter: LatLng(33.22, 43.68),
                  initialZoom: 5.5,
                ),
                children: [
                  TileLayer(
                    urlTemplate:
                        'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                    userAgentPackageName: 'iq.ridepassenger.car',
                    tileProvider: DarbOfflineTileProvider(),
                    tileBuilder: dark ? darkModeTileBuilder : null,
                  ),
                  PolygonLayer(
                    polygons: [
                      for (final gov in governorates)
                        Polygon(
                          points: gov.boxPolygon,
                          color: gov.id == _selectedRegionId
                              ? _green.withValues(alpha: 0.42)
                              : (_downloaded.containsKey(gov.id)
                                  ? _green.withValues(alpha: 0.22)
                                  : Colors.teal.withValues(alpha: 0.14)),
                          borderColor: gov.id == _selectedRegionId
                              ? _green
                              : Colors.teal.shade700,
                          borderStrokeWidth:
                              gov.id == _selectedRegionId ? 2.5 : 1.0,
                        ),
                    ],
                  ),
                  MarkerLayer(
                    markers: [
                      for (final gov in governorates)
                        Marker(
                          point: gov.center,
                          width: 82,
                          height: 30,
                          child: GestureDetector(
                            onTap: () =>
                                setState(() => _selectedRegionId = gov.id),
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: gov.id == _selectedRegionId
                                      ? _green
                                      : Colors.black.withValues(alpha: 0.65),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  gov.nameAr,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              selectedRegion.nameAr,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                            Text(
                              'الحجم التقديري: ${OfflineMapsService.estimateSizeMb(selectedRegion).toStringAsFixed(1)} MB',
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.grey.shade600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (isDownloading)
                        SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(
                            value: _downloadProgress,
                            strokeWidth: 3,
                          ),
                        )
                      else if (isDownloaded)
                        IconButton(
                          tooltip: 'حذف الخريطة',
                          onPressed: () => _delete(selectedRegion),
                          icon: const Icon(Icons.delete_outline,
                              color: Colors.redAccent),
                        ),
                      const SizedBox(width: 6),
                      FilledButton.icon(
                        onPressed: _downloadingRegionId != null
                            ? null
                            : () => _download(selectedRegion),
                        style: FilledButton.styleFrom(backgroundColor: _green),
                        icon: Icon(
                          isDownloaded
                              ? Icons.refresh_rounded
                              : Icons.download_rounded,
                        ),
                        label: Text(isDownloaded ? 'تحديث' : 'تحميل'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _downloadingRegionId != null
                        ? null
                        : () => _download(allIraq),
                    icon: const Icon(Icons.public_rounded),
                    label: Text(
                      'تحميل خريطة كل العراق (${OfflineMapsService.estimateSizeMb(allIraq).toStringAsFixed(1)} MB)',
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildListTab(
    IraqRegion allIraq,
    List<IraqRegion> governorates,
    ThemeData theme,
    ColorScheme cs,
  ) {
    final downloadedRegions = OfflineMapsService.regions
        .where((r) => _downloaded.containsKey(r.id))
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
      children: [
        if (downloadedRegions.isNotEmpty) ...[
          Text(
            'الخرائط المحمّلة',
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 8),
          for (final region in downloadedRegions)
            _buildRegionTile(region, theme, cs),
          const SizedBox(height: 14),
        ],
        Text(
          'خريطة العراق والمحافظات',
          style: theme.textTheme.titleSmall?.copyWith(
            fontWeight: FontWeight.w900,
          ),
        ),
        const SizedBox(height: 8),
        _buildRegionTile(allIraq, theme, cs),
        for (final gov in governorates) _buildRegionTile(gov, theme, cs),
      ],
    );
  }

  Widget _buildRegionTile(
    IraqRegion region,
    ThemeData theme,
    ColorScheme cs,
  ) {
    final info = _downloaded[region.id];
    final isDownloading = _downloadingRegionId == region.id;
    final estMb = OfflineMapsService.estimateSizeMb(region);

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Column(
          children: [
            Row(
              children: [
                Icon(
                  region.isAllIraq
                      ? Icons.public_rounded
                      : Icons.location_city_rounded,
                  color: info != null ? _green : cs.primary,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        region.nameAr,
                        style: const TextStyle(
                          fontWeight: FontWeight.w800,
                          fontSize: 15,
                        ),
                      ),
                      Text(
                        info != null
                            ? 'جاهزة دون اتصال • ${info.sizeMb.toStringAsFixed(1)} MB'
                            : 'الحجم التقديري: ${estMb.toStringAsFixed(1)} MB',
                        style: TextStyle(
                          fontSize: 12,
                          color: info != null ? _green : cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isDownloading)
                  TextButton(
                    onPressed: () => setState(() => _cancelRequested = true),
                    child: const Text('إلغاء'),
                  )
                else ...[
                  if (info != null)
                    IconButton(
                      tooltip: 'حذف',
                      onPressed: () => _delete(region),
                      icon: const Icon(
                        Icons.delete_outline,
                        color: Colors.redAccent,
                      ),
                    ),
                  FilledButton.tonalIcon(
                    onPressed: _downloadingRegionId != null
                        ? null
                        : () => _download(region),
                    icon: Icon(
                      info != null ? Icons.check_circle : Icons.download_rounded,
                      size: 18,
                    ),
                    label: Text(info != null ? 'تحديث' : 'تحميل'),
                  ),
                ],
              ],
            ),
            if (isDownloading) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _downloadProgress),
            ],
          ],
        ),
      ),
    );
  }
}
