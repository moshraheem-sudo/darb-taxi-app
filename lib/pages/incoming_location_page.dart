import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../services/map_link_parser.dart';

class IncomingLocationPage extends StatelessWidget {
  const IncomingLocationPage({
    super.key,
    required this.location,
    required this.isRideActive,
    required this.onSetDestination,
    required this.onSetOrigin,
    required this.onViewOnMap,
    this.onSetBoth,
  });

  final ParsedMapLocation location;
  final bool isRideActive;
  final VoidCallback onSetDestination;
  final VoidCallback onSetOrigin;
  final VoidCallback? onSetBoth;
  final VoidCallback onViewOnMap;

  Future<void> _confirmIfRideActive(
    BuildContext context,
    VoidCallback action,
    bool isArabic,
  ) async {
    if (!isRideActive) {
      action();
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(isArabic ? 'رحلة نشطة حالياً' : 'Active Ride in Progress'),
        content: Text(
          isArabic
              ? 'لديك رحلة قيد التنفيذ حالياً. هل تريد تحديث مسار الرحلة بهذا الموقع؟'
              : 'You currently have an active ride. Do you want to update your route with this location?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(isArabic ? 'إلغاء' : 'Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(isArabic ? 'تأكيد' : 'Confirm'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      action();
    }
  }

  @override
  Widget build(BuildContext context) {
    final isArabic = Directionality.of(context) == TextDirection.rtl;
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final targetPoint = LatLng(location.latitude, location.longitude);
    final originPoint = location.hasDirections
        ? LatLng(location.originLatitude!, location.originLongitude!)
        : null;

    final markers = <Marker>[
      if (originPoint != null)
        Marker(
          point: originPoint,
          width: 44,
          height: 44,
          child: const _MapPinBadge(
            color: Color(0xFF087F65),
            icon: Icons.trip_origin_rounded,
          ),
        ),
      Marker(
        point: targetPoint,
        width: 48,
        height: 48,
        child: const _MapPinBadge(
          color: Color(0xFFD9383A),
          icon: Icons.location_on_rounded,
        ),
      ),
    ];

    final initialOptions = originPoint != null
        ? MapOptions(
            initialCameraFit: CameraFit.bounds(
              bounds: LatLngBounds.fromPoints([originPoint, targetPoint]),
              padding: const EdgeInsets.all(48),
            ),
          )
        : MapOptions(
            initialCenter: targetPoint,
            initialZoom: 15.5,
          );

    return Scaffold(
      appBar: AppBar(
        title: Text(isArabic ? 'موقع مشترك' : 'Shared Location'),
        centerTitle: true,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: cs.primaryContainer,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.share_location_rounded,
                      size: 16,
                      color: cs.onPrimaryContainer,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      isArabic
                          ? 'المصدر: ${location.source}'
                          : 'Source: ${location.source}',
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: cs.onPrimaryContainer,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(18),
              child: SizedBox(
                height: 240,
                child: FlutterMap(
                  options: initialOptions,
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'iq.ridepassenger.car',
                    ),
                    if (originPoint != null)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: [originPoint, targetPoint],
                            strokeWidth: 4,
                            color: const Color(0xFF087F65),
                          ),
                        ],
                      ),
                    MarkerLayer(markers: markers),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 16),
            Card(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: cs.outlineVariant),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      location.placeName?.isNotEmpty == true
                          ? location.placeName!
                          : (isArabic ? 'موقع محدد على الخريطة' : 'Pinned Location'),
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (location.address?.isNotEmpty == true) ...[
                      const SizedBox(height: 6),
                      Text(
                        location.address!,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (originPoint != null) ...[
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          const Icon(
                            Icons.trip_origin_rounded,
                            size: 16,
                            color: Color(0xFF087F65),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              isArabic
                                  ? 'نقطة الانطلاق: ${location.originName ?? "${originPoint.latitude.toStringAsFixed(5)}, ${originPoint.longitude.toStringAsFixed(5)}"}'
                                  : 'Origin: ${location.originName ?? "${originPoint.latitude.toStringAsFixed(5)}, ${originPoint.longitude.toStringAsFixed(5)}"}',
                              style: theme.textTheme.bodySmall,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ),
            if (isRideActive) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: cs.tertiaryContainer.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline_rounded, color: cs.onTertiaryContainer),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        isArabic
                            ? 'توجد رحلة نشطة حالياً — لن يتم تعديل المسار إلا بعد تأكيدك.'
                            : 'An active ride is in progress — your route will not change without confirmation.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: cs.onTertiaryContainer,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: () =>
                  _confirmIfRideActive(context, onSetDestination, isArabic),
              icon: const Icon(Icons.flag_rounded),
              label: Text(
                isArabic ? 'اعتماد كوجهة' : 'Set as Destination',
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            const SizedBox(height: 10),
            FilledButton.tonalIcon(
              onPressed: () =>
                  _confirmIfRideActive(context, onSetOrigin, isArabic),
              icon: const Icon(Icons.trip_origin_rounded),
              label: Text(
                isArabic ? 'اعتماد كنقطة انطلاق' : 'Set as Pickup',
              ),
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
            if (location.hasDirections && onSetBoth != null) ...[
              const SizedBox(height: 10),
              OutlinedButton.icon(
                onPressed: () =>
                    _confirmIfRideActive(context, onSetBoth!, isArabic),
                icon: const Icon(Icons.alt_route_rounded),
                label: Text(
                  isArabic
                      ? 'اعتماد الانطلاق والوجهة معاً'
                      : 'Set Pickup & Destination',
                ),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                ),
              ),
            ],
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: onViewOnMap,
              icon: const Icon(Icons.map_rounded),
              label: Text(isArabic ? 'عرض على الخريطة' : 'View on Map'),
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(48),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MapPinBadge extends StatelessWidget {
  const _MapPinBadge({
    required this.color,
    required this.icon,
  });

  final Color color;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2.5),
        boxShadow: const [
          BoxShadow(
            color: Colors.black26,
            blurRadius: 6,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: Icon(icon, color: Colors.white, size: 22),
    );
  }
}
