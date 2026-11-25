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
