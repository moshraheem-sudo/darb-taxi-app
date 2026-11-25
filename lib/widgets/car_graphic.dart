import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Renders a modern sedan car illustration with badges (dollar coin, star, or box)
/// exactly as shown in the screenshots.
class CarGraphic extends StatelessWidget {
  const CarGraphic({
    super.key,
    this.badgeType = 'dollar', // 'dollar', 'star', 'box'
    this.size = 110,
  });

  final String badgeType;
  final double size;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size * 1.5,
      height: size,
      child: CustomPaint(
        painter: _CarPainter(badgeType: badgeType),
        size: Size(size * 1.5, size),
      ),
    );
  }
}

/// Compact top-down car used as a moving, bearing-aware map marker.
class TopDownCarMarker extends StatelessWidget {
  const TopDownCarMarker({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: 34,
    height: 48,
    child: CustomPaint(painter: _TopDownCarPainter(color)),
  );
}

class _TopDownCarPainter extends CustomPainter {
  const _TopDownCarPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final shadow = Paint()..color = Colors.black38;
    final tire = Paint()..color = const Color(0xFF17202A);
    final body = Paint()..color = color;
    final glass = Paint()..color = const Color(0xFFB9D9F2);
    final trim = Paint()..color = Colors.white;

    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * .12, h * .08, w * .76, h * .86),
        const Radius.circular(11),
      ),
      shadow,
    );
    for (final y in [.22, .68]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * .02, h * y, w * .18, h * .19),
          const Radius.circular(3),
        ),
        tire,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(w * .80, h * y, w * .18, h * .19),
          const Radius.circular(3),
        ),
        tire,
      );
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * .13, h * .04, w * .74, h * .90),
        const Radius.circular(10),
      ),
      body,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * .24, h * .17, w * .52, h * .24),
        const Radius.circular(5),
      ),
      glass,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * .24, h * .59, w * .52, h * .20),
        const Radius.circular(4),
      ),
      glass,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * .24, h * .44, w * .52, h * .12),
        const Radius.circular(3),
      ),
      trim,
    );
    final lights = Paint()..color = const Color(0xFFFFF2A6);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * .18, h * .07, w * .18, h * .035),
        const Radius.circular(2),
      ),
      lights,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(w * .64, h * .07, w * .18, h * .035),
        const Radius.circular(2),
      ),
      lights,
    );
  }

  @override
  bool shouldRepaint(covariant _TopDownCarPainter oldDelegate) =>
      oldDelegate.color != color;
}

class _CarPainter extends CustomPainter {
  _CarPainter({required this.badgeType});
  final String badgeType;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // Car Body dimensions
    final carLeft = w * 0.12;
    final carRight = w * 0.88;
    final carBottom = h * 0.78;
    final cabinTop = h * 0.38;
    final bodyHeight = h * 0.28;

    // Paints
    final carPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [Color(0xFF74A8FF), Color(0xFF2765D8), Color(0xFF123E91)],
        stops: [0, .42, 1],
      ).createShader(Rect.fromLTWH(0, h * .3, w, h * .5))
      ..style = PaintingStyle.fill;

    final darkBluePaint = Paint()
      ..color = const Color(0xFF1243B5)
      ..style = PaintingStyle.fill;

    final windowPaint = Paint()
      ..shader = const LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [Color(0xFFB9D9F2), Color(0xFF244B76), Color(0xFF101E32)],
      ).createShader(Rect.fromLTWH(w * .28, cabinTop, w * .45, h * .28))
      ..style = PaintingStyle.fill;

    final windowDividerPaint = Paint()
      ..color = const Color(0xFF1243B5)
      ..strokeWidth = 3.5
      ..style = PaintingStyle.stroke;

    final wheelTirePaint = Paint()
      ..color =
          const Color(0xFF1A2645) // Dark navy/black
      ..style = PaintingStyle.fill;

    final wheelRimPaint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.fill;

    final wheelInnerRimPaint = Paint()
      ..color = const Color(0xFF2C55BE)
      ..style = PaintingStyle.fill;

    final headlightPaint = Paint()
      ..color =
          const Color(0xFFFFF275) // Yellow headlight
      ..style = PaintingStyle.fill;

    final taillightPaint = Paint()
      ..color =
          const Color(0xFFFF3B30) // Red taillight
      ..style = PaintingStyle.fill;

    // Draw badge first (so it sits on / behind roof naturally)
    _drawRoofBadge(canvas, w, h);

    // 1. Draw Car Lower Body + Cabin using Path
    final bodyPath = Path();
    // Start at rear bumper
    bodyPath.moveTo(carLeft, carBottom);
    // Rear bumper curve up
    bodyPath.lineTo(carLeft * 0.95, carBottom - bodyHeight * 0.45);
    bodyPath.quadraticBezierTo(
      carLeft * 0.95,
      carBottom - bodyHeight * 0.8,
      carLeft * 1.05,
      carBottom - bodyHeight,
    );
    // Trunk
    bodyPath.lineTo(w * 0.25, carBottom - bodyHeight);
    // Rear windshield to roof
    bodyPath.quadraticBezierTo(w * 0.32, cabinTop + 2, w * 0.40, cabinTop);
    // Roof
    bodyPath.lineTo(w * 0.65, cabinTop);
    // Front windshield
    bodyPath.quadraticBezierTo(
      w * 0.72,
      cabinTop + 4,
      w * 0.76,
      carBottom - bodyHeight,
    );
    // Hood to front bumper
    bodyPath.lineTo(carRight * 0.95, carBottom - bodyHeight * 0.85);
    bodyPath.quadraticBezierTo(
      carRight,
      carBottom - bodyHeight * 0.7,
      carRight,
      carBottom - bodyHeight * 0.3,
    );
    bodyPath.lineTo(carRight, carBottom);
    // Bottom undercarriage (with cutouts for wheels)
    bodyPath.lineTo(carRight * 0.88, carBottom);
    // Front wheel arch cutout
    bodyPath.arcToPoint(
      Offset(carRight * 0.70, carBottom),
      radius: Radius.circular(h * 0.16),
      clockwise: false,
    );
    // Mid bottom
    bodyPath.lineTo(carLeft * 2.1, carBottom);
    // Rear wheel arch cutout
    bodyPath.arcToPoint(
      Offset(carLeft * 1.35, carBottom),
      radius: Radius.circular(h * 0.16),
      clockwise: false,
    );
    // To rear bumper
    bodyPath.lineTo(carLeft, carBottom);
    bodyPath.close();

    // Draw main car body
    canvas.drawPath(bodyPath, carPaint);

    // Soft reflections and sculpted side panels give the sedan a finished,
    // automotive silhouette instead of a flat toy-like block.
    final reflection = Paint()
      ..color = Colors.white.withValues(alpha: .58)
      ..strokeWidth = h * .018
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(w * .19, carBottom - bodyHeight * .66),
      Offset(w * .34, carBottom - bodyHeight * .66),
      reflection,
    );
    canvas.drawLine(
      Offset(w * .77, carBottom - bodyHeight * .62),
      Offset(w * .84, carBottom - bodyHeight * .62),
      reflection,
    );
    final sillPaint = Paint()
      ..color = const Color(0xFF0E347B).withValues(alpha: .78)
      ..strokeWidth = h * .025
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(w * .29, carBottom - h * .035),
      Offset(w * .70, carBottom - h * .035),
      sillPaint,
    );

    // Subtle bottom shadow strip on car body
    final shadowStrip = Path();
    shadowStrip.moveTo(carLeft, carBottom - 4);
    shadowStrip.lineTo(carRight, carBottom - 4);
    shadowStrip.lineTo(carRight, carBottom);
    shadowStrip.lineTo(carLeft, carBottom);
    shadowStrip.close();
    canvas.drawPath(shadowStrip, darkBluePaint);

    // 2. Draw Windows
    final windowPath = Path();
    // Rear window
    windowPath.moveTo(w * 0.28, carBottom - bodyHeight + 2);
    windowPath.quadraticBezierTo(
      w * 0.34,
      cabinTop + 5,
      w * 0.40,
      cabinTop + 4,
    );
    windowPath.lineTo(w * 0.50, cabinTop + 4);
    windowPath.lineTo(w * 0.50, carBottom - bodyHeight + 2);
    windowPath.close();
    canvas.drawPath(windowPath, windowPaint);

    // Front window
    final frontWindowPath = Path();
    frontWindowPath.moveTo(w * 0.52, cabinTop + 4);
    frontWindowPath.lineTo(w * 0.63, cabinTop + 4);
    frontWindowPath.quadraticBezierTo(
      w * 0.69,
      cabinTop + 7,
      w * 0.73,
      carBottom - bodyHeight + 2,
    );
    frontWindowPath.lineTo(w * 0.52, carBottom - bodyHeight + 2);
    frontWindowPath.close();
    canvas.drawPath(frontWindowPath, windowPaint);

    // Window B-pillar divider
    canvas.drawLine(
      Offset(w * 0.51, cabinTop + 3),
      Offset(w * 0.51, carBottom - bodyHeight + 2),
      windowDividerPaint,
    );

    // 3. Taillight (Red rounded rect on left)
    final taillightRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        carLeft * 0.95,
        carBottom - bodyHeight * 0.8,
        w * 0.035,
        h * 0.08,
      ),
      const Radius.circular(3),
    );
    canvas.drawRRect(taillightRRect, taillightPaint);

    // 4. Headlight (Yellow rounded rect on right)
    final headlightRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(
        carRight - w * 0.035,
        carBottom - bodyHeight * 0.65,
        w * 0.04,
        h * 0.07,
      ),
      const Radius.circular(3),
    );
    canvas.drawRRect(headlightRRect, headlightPaint);

    // 5. Door handle line
    final handlePaint = Paint()
      ..color = const Color(0xFF0D328C)
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(w * 0.42, carBottom - bodyHeight * 0.6),
      Offset(w * 0.46, carBottom - bodyHeight * 0.6),
      handlePaint,
    );
    canvas.drawLine(
      Offset(w * 0.58, carBottom - bodyHeight * 0.6),
      Offset(w * 0.62, carBottom - bodyHeight * 0.6),
      handlePaint,
    );

    // 6. Draw Wheels
    final wheelRadius = h * 0.15;
    final rearWheelCenter = Offset(carLeft * 1.725, carBottom + 2);
    final frontWheelCenter = Offset(carRight * 0.79, carBottom + 2);

    for (final center in [rearWheelCenter, frontWheelCenter]) {
      // Tire
      canvas.drawCircle(center, wheelRadius, wheelTirePaint);
      // Outer Rim
      canvas.drawCircle(center, wheelRadius * 0.68, wheelRimPaint);
      // Inner blue hub
      canvas.drawCircle(center, wheelRadius * 0.45, wheelInnerRimPaint);
      final spokePaint = Paint()
        ..color = const Color(0xFF8C9BAD)
        ..strokeWidth = wheelRadius * .10;
      for (var spoke = 0; spoke < 6; spoke++) {
        final angle = spoke * math.pi / 3;
        canvas.drawLine(
          center + Offset(math.cos(angle), math.sin(angle)) * wheelRadius * .22,
          center + Offset(math.cos(angle), math.sin(angle)) * wheelRadius * .57,
          spokePaint,
        );
      }
      // Center cap
      final wheelCapPaint = Paint()..color = Colors.white;
      canvas.drawCircle(center, wheelRadius * 0.20, wheelCapPaint);
    }
  }

  void _drawRoofBadge(Canvas canvas, double w, double h) {
    if (badgeType == 'dollar') {
      // Golden Dollar Coin on the roof
      final coinCenter = Offset(w * 0.29, h * 0.32);
      final coinRadius = h * 0.23;

      // Outer gold border/shadow
      final borderPaint = Paint()
        ..color = const Color(0xFFD49200)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(coinCenter, coinRadius + 2.5, borderPaint);

      // Gold coin face
      final coinPaint = Paint()
        ..color =
            const Color(0xFFFFC727) // Bright gold
        ..style = PaintingStyle.fill;
      canvas.drawCircle(coinCenter, coinRadius, coinPaint);

      // Inner coin ring
      final innerRingPaint = Paint()
        ..color = const Color(0xFFE5A910)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(coinCenter, coinRadius * 0.82, innerRingPaint);

      // $ symbol in center
      final textSpan = TextSpan(
        text: '\$',
        style: TextStyle(
          color: const Color(0xFF142421),
          fontSize: coinRadius * 1.35,
          fontWeight: FontWeight.w900,
          fontFamily: 'Arial',
        ),
      );
      final textPainter = TextPainter(
        text: textSpan,
        textDirection: TextDirection.ltr,
      );
      textPainter.layout();
      textPainter.paint(
        canvas,
        Offset(
          coinCenter.dx - textPainter.width / 2,
          coinCenter.dy - textPainter.height / 2,
        ),
      );
    } else if (badgeType == 'star') {
      // Golden Star on roof (Plus tier)
      final starCenter = Offset(w * 0.30, h * 0.30);
      final starRadius = h * 0.22;

      final starPaint = Paint()
        ..color = const Color(0xFFFFB800)
        ..style = PaintingStyle.fill;

      final starOutline = Paint()
        ..color = const Color(0xFFCC8400)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;

      final path = _createStarPath(
        starCenter,
        5,
        starRadius,
        starRadius * 0.45,
      );
      canvas.drawPath(path, starPaint);
      canvas.drawPath(path, starOutline);
    } else if (badgeType == 'box') {
      // Cardboard box for parcel delivery
      final boxRect = Rect.fromCenter(
        center: Offset(w * 0.31, h * 0.32),
        width: h * 0.38,
        height: h * 0.38,
      );
      final boxPaint = Paint()..color = const Color(0xFFCB8B4F);
      final borderPaint = Paint()
        ..color = const Color(0xFF9E6532)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      final tapePaint = Paint()..color = const Color(0xFFEADBBE);

      canvas.drawRRect(
        RRect.fromRectAndRadius(boxRect, const Radius.circular(4)),
        boxPaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(boxRect, const Radius.circular(4)),
        borderPaint,
      );
      // Tape across
      canvas.drawRect(
        Rect.fromCenter(
          center: Offset(w * 0.31, h * 0.32),
          width: h * 0.12,
          height: h * 0.38,
        ),
        tapePaint,
      );
    }
  }

  Path _createStarPath(
    Offset center,
    int points,
    double outerRadius,
    double innerRadius,
  ) {
    final path = Path();
    final double step = math.pi / points;
    double angle = -math.pi / 2;

    for (int i = 0; i < points * 2; i++) {
      final double r = (i % 2 == 0) ? outerRadius : innerRadius;
      final double x = center.dx + math.cos(angle) * r;
      final double y = center.dy + math.sin(angle) * r;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      angle += step;
    }
    path.close();
    return path;
  }

  @override
  bool shouldRepaint(covariant _CarPainter oldDelegate) =>
      oldDelegate.badgeType != badgeType;
}
