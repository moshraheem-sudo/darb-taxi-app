import 'package:flutter/material.dart';

/// Shared map floating control button used across Passenger & Captain screens.
class DarbMapControlButton extends StatelessWidget {
  const DarbMapControlButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
    this.backgroundColor,
    this.foregroundColor,
    super.key,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;
  final Color? backgroundColor;
  final Color? foregroundColor;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: backgroundColor ?? (dark ? const Color(0xFF182522) : Colors.white),
        elevation: 4,
        shadowColor: Colors.black26,
        shape: const CircleBorder(),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(
              icon,
              size: 21,
              color: foregroundColor ?? (dark ? Colors.white : const Color(0xFF142421)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Animated ground shadow dot shown beneath a lifted center map pin.
class DarbPinGroundShadow extends StatelessWidget {
  const DarbPinGroundShadow({required this.lifted, super.key});

  final bool lifted;

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      width: lifted ? 14 : 8,
      height: lifted ? 5 : 3,
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: lifted ? 0.28 : 0.14),
        borderRadius: BorderRadius.circular(8),
      ),
    );
  }
}

/// Unified Loading / Empty / Error / Offline state display for all screens.
class DarbStateView extends StatelessWidget {
  const DarbStateView.loading({
    this.message = 'جارٍ التحميل...',
    super.key,
  })  : _kind = _StateKind.loading,
        icon = Icons.hourglass_empty_rounded,
        title = message,
        subtitle = null,
        onRetry = null;

  const DarbStateView.empty({
    required this.icon,
    required this.title,
    this.subtitle,
    this.onRetry,
    super.key,
  })  : _kind = _StateKind.empty,
        message = '';

  const DarbStateView.offline({
    this.title = 'لا يوجد اتصال بالإنترنت',
    this.subtitle = 'تحقق من الشبكة وحاول مجدداً.',
    this.onRetry,
    super.key,
  })  : _kind = _StateKind.offline,
        icon = Icons.wifi_off_rounded,
        message = '';

  final _StateKind _kind;
  final IconData icon;
  final String title;
  final String? subtitle;
  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    if (_kind == _StateKind.loading) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 12),
              Text(message),
            ],
          ),
        ),
      );
    }
    return Semantics(
      container: true,
      child: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 52, color: Colors.grey.shade500),
              const SizedBox(height: 10),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 16.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
              if (subtitle != null && subtitle!.isNotEmpty) ...[
                const SizedBox(height: 6),
                Text(
                  subtitle!,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
                ),
              ],
              if (onRetry != null) ...[
                const SizedBox(height: 14),
                OutlinedButton.icon(
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('إعادة المحاولة'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

enum _StateKind { loading, empty, offline }
