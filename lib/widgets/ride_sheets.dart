import 'package:flutter/material.dart';

import 'car_graphic.dart';

/// Formats integer price into Arabic currency format: e.g. "1,000 دينار"
String formatIraqiDinar(int value) {
  final str = value.toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return '$str دينار';
}

/// Downward pointing triangle used as pointer under map badges
class TriangleDownPainter extends CustomPainter {
  const TriangleDownPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(size.width, 0)
      ..lineTo(size.width / 2, size.height)
      ..close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

/// Map marker widget with label pill and shape indicator matching Image 3
class LocationMapMarker extends StatelessWidget {
  const LocationMapMarker({
    super.key,
    required this.title,
    required this.pinColor,
    required this.isSquare,
  });

  final String title;
  final Color pinColor;
  final bool isSquare;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final pillColor = dark ? const Color(0xFF1F2E2A) : Colors.white;
    final textColor = dark ? Colors.white : const Color(0xFF142421);
    return FittedBox(
      fit: BoxFit.scaleDown,
      alignment: Alignment.topCenter,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: pillColor,
              borderRadius: BorderRadius.circular(10),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black26,
                  blurRadius: 5,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: textColor,
              ),
            ),
          ),
          CustomPaint(
            size: const Size(10, 6),
            painter: TriangleDownPainter(pillColor),
          ),
          const SizedBox(height: 2),
          Container(
            width: 22,
            height: 22,
            decoration: BoxDecoration(
              color: pinColor,
              shape: isSquare ? BoxShape.rectangle : BoxShape.circle,
              borderRadius: isSquare ? BorderRadius.circular(6) : null,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Modal bottom sheet for entering and applying promo discount codes (Image 1)
class PromoCodeSheet extends StatefulWidget {
  const PromoCodeSheet({super.key, this.currentCode, required this.onApply});

  final String? currentCode;
  final void Function(String code, int discount) onApply;

  @override
  State<PromoCodeSheet> createState() => _PromoCodeSheetState();
}

class _PromoCodeSheetState extends State<PromoCodeSheet> {
  late final TextEditingController _controller;
  bool _canApply = false;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentCode ?? '');
    _canApply = _controller.text.trim().isNotEmpty;
    _controller.addListener(() {
      final valid = _controller.text.trim().isNotEmpty;
      if (valid != _canApply) {
        setState(() => _canApply = valid);
      }
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _controller.text.trim();
    if (code.isEmpty) return;

    // Apply a standard discount of 250 - 500 IQD
    final discount = code.toUpperCase().contains('VIP') ? 500 : 250;
    widget.onApply(code, discount);
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF182522) : Colors.white;
    final primaryText = dark ? Colors.white : const Color(0xFF142421);
    final mutedText = dark ? Colors.white70 : Colors.grey.shade600;
    return Material(
      color: surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 14,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Center(
              child: Container(
                width: 44,
                height: 5,
                decoration: BoxDecoration(
                  color: Colors.grey.shade300,
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
            const SizedBox(height: 8),

            // Header
            Stack(
              alignment: Alignment.center,
              children: [
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: IconButton(
                    onPressed: () => Navigator.of(context).pop(),
                    icon: Icon(
                      Icons.close,
                      color: dark ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
                Text(
                  'رمز الخصم',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: primaryText,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Car graphic
            const Center(child: CarGraphic(badgeType: 'dollar', size: 105)),
            const SizedBox(height: 18),

            // Questions
            Text(
              'هل لديك رمز خصم؟',
              style: TextStyle(
                fontSize: 21,
                fontWeight: FontWeight.w900,
                color: primaryText,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'رجاءً أدخل رمز الخصم',
              style: TextStyle(fontSize: 15, color: mutedText),
            ),
            const SizedBox(height: 24),

            // Outlined TextField with blue border and tag icon
            TextField(
              controller: _controller,
              textCapitalization: TextCapitalization.characters,
              textDirection: TextDirection.rtl,
              decoration: InputDecoration(
                labelText: 'رمز الخصم',
                floatingLabelBehavior: FloatingLabelBehavior.always,
                suffixIcon: const Icon(
                  Icons.local_offer_outlined,
                  color: Colors.grey,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 18,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(
                    color: Color(0xFF194BFB),
                    width: 1.8,
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(
                    color: Color(0xFF194BFB),
                    width: 1.8,
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: const BorderSide(
                    color: Color(0xFF194BFB),
                    width: 2.2,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 32),

            // Bottom button
            SizedBox(
              width: double.infinity,
              height: 52,
              child: FilledButton(
                onPressed: _canApply ? _submit : null,
                style: FilledButton.styleFrom(
                  backgroundColor: _canApply
                      ? const Color(0xFF194BFB)
                      : const Color(0xFFE2E4E9),
                  foregroundColor: _canApply
                      ? Colors.white
                      : const Color(0xFF8C93A3),
                  disabledBackgroundColor: const Color(0xFFE2E4E9),
                  disabledForegroundColor: const Color(0xFF8C93A3),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  elevation: 0,
                ),
                child: const Text(
                  'تثبيت الرمز',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Ride Options Sheet (Image 2)
class RideOptionsSheet extends StatefulWidget {
  const RideOptionsSheet({
    super.key,
    required this.selectedTier,
    required this.secondDestinationName,
    required this.stopWaitMinutes,
    required this.roundTrip,
    required this.basePrice,
    required this.onSelectSecondDestination,
    required this.onRemoveSecondDestination,
    required this.onChangeStopWait,
    required this.onChangeRoundTrip,
    required this.onConfirm,
  });

  final String selectedTier;
  final String? secondDestinationName;
  final int stopWaitMinutes;
  final bool roundTrip;
  final int basePrice;
  final VoidCallback onSelectSecondDestination;
  final VoidCallback onRemoveSecondDestination;
  final void Function(int minutes) onChangeStopWait;
  final void Function(bool value) onChangeRoundTrip;
  final VoidCallback onConfirm;

  @override
  State<RideOptionsSheet> createState() => _RideOptionsSheetState();
}

class _RideOptionsSheetState extends State<RideOptionsSheet> {
  late bool _roundTrip;
  late int _stopMinutes;

  @override
  void initState() {
    super.initState();
    _roundTrip = widget.roundTrip;
    _stopMinutes = widget.stopWaitMinutes;
  }

  int _calculateCurrentPrice() {
    int price = widget.basePrice;
    if (widget.secondDestinationName != null) {
      price += 500;
    }
    if (_stopMinutes > 0) {
      price += (_stopMinutes <= 5
          ? 250
          : _stopMinutes <= 15
          ? 500
          : 750);
    }
    if (_roundTrip) {
      price = (price * 1.6).round();
      // Round to nearest 250
      price = ((price / 250).round()) * 250;
    }
    return price;
  }

  void _showStopPicker() {
    showModalBottomSheet<int>(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 18),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'مدة التوقف أو الانتظار في الطريق',
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 12),
                ListTile(
                  title: const Text('بدون توقف'),
                  trailing: _stopMinutes == 0
                      ? const Icon(Icons.check, color: Color(0xFF194BFB))
                      : null,
                  onTap: () => Navigator.pop(context, 0),
                ),
                ListTile(
                  title: const Text('5 دقائق (+250 دينار)'),
                  trailing: _stopMinutes == 5
                      ? const Icon(Icons.check, color: Color(0xFF194BFB))
                      : null,
                  onTap: () => Navigator.pop(context, 5),
                ),
                ListTile(
                  title: const Text('10 دقائق (+500 دينار)'),
                  trailing: _stopMinutes == 10
                      ? const Icon(Icons.check, color: Color(0xFF194BFB))
                      : null,
                  onTap: () => Navigator.pop(context, 10),
                ),
                ListTile(
                  title: const Text('15 دقيقة (+750 دينار)'),
                  trailing: _stopMinutes == 15
                      ? const Icon(Icons.check, color: Color(0xFF194BFB))
                      : null,
                  onTap: () => Navigator.pop(context, 15),
                ),
              ],
            ),
          ),
        );
      },
    ).then((selected) {
      if (selected != null) {
        setState(() => _stopMinutes = selected);
        widget.onChangeStopWait(selected);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final tierName = widget.selectedTier == 'plus' ? 'بَلَس' : 'توفير';
    final badgeType = widget.selectedTier == 'plus' ? 'star' : 'dollar';
    final currentPrice = _calculateCurrentPrice();
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF182522) : Colors.white;
    final primaryText = dark ? Colors.white : const Color(0xFF142421);

    return Material(
      color: surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Top Bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 6),
              child: Stack(
                alignment: Alignment.center,
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: IconButton(
                      icon: const Icon(Icons.arrow_forward),
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ),
                  Text(
                    'خيارات الرحلة',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: primaryText,
                    ),
                  ),
                ],
              ),
            ),

            // Car illustration with tier title
            CarGraphic(badgeType: badgeType, size: 85),
            const SizedBox(height: 6),
            Text(
              tierName,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: primaryText,
              ),
            ),
            const SizedBox(height: 14),

            // Notice Card
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 18),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: dark ? const Color(0xFF3A2927) : const Color(0xFFFFF7F6),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: dark
                      ? const Color(0xFF70453E)
                      : const Color(0xFFFFD5D0),
                  width: 0.8,
                ),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.phone_android_rounded,
                    color: Color(0xFFE53935),
                    size: 28,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'ملحوظة: لا يمكن تغيير الخيارات التي اخترتها أثناء الرحلة.',
                      style: TextStyle(
                        fontSize: 13,
                        color: Color(0xFF5A5F6B),
                        fontWeight: FontWeight.w600,
                        height: 1.35,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Section title
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  'خيارات الرحلة',
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.bold,
                    color: primaryText,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 6),

            // Option 1: الوجهة الثانية
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 2,
              ),
              trailing: const Icon(Icons.chevron_left, color: Colors.grey),
              leading: Icon(
                Icons.add_location_alt_outlined,
                color: dark ? Colors.white70 : const Color(0xFF5A5F6B),
                size: 26,
              ),
              title: Text(
                'الوجهة الثانية',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: primaryText,
                ),
              ),
              subtitle: widget.secondDestinationName != null
                  ? Text(
                      widget.secondDestinationName!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: Color(0xFF194BFB),
                        fontSize: 13,
                      ),
                    )
                  : null,
              onTap: widget.onSelectSecondDestination,
            ),
            const Divider(height: 1, indent: 20, endIndent: 20),

            // Option 2: التوقف في الطريق
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 2,
              ),
              trailing: const Icon(Icons.chevron_left, color: Colors.grey),
              leading: Icon(
                Icons.access_time_rounded,
                color: dark ? Colors.white70 : const Color(0xFF5A5F6B),
                size: 26,
              ),
              title: Text(
                'التوقف في الطريق',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: primaryText,
                ),
              ),
              subtitle: Text(
                _stopMinutes == 0 ? 'بدون توقف' : '$_stopMinutes دقائق توقف',
                style: TextStyle(
                  color: _stopMinutes > 0
                      ? const Color(0xFF194BFB)
                      : Colors.grey.shade600,
                  fontSize: 13,
                ),
              ),
              onTap: _showStopPicker,
            ),
            const Divider(height: 1, indent: 20, endIndent: 20),

            // Option 3: رحلة ذهاب وإياب
            ListTile(
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 20,
                vertical: 2,
              ),
              leading: Icon(
                Icons.swap_horiz_rounded,
                color: dark ? Colors.white70 : const Color(0xFF5A5F6B),
                size: 28,
              ),
              title: Text(
                'رحلة ذهاب وإياب',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                  color: primaryText,
                ),
              ),
              trailing: Switch.adaptive(
                value: _roundTrip,
                activeThumbColor: const Color(0xFF194BFB),
                onChanged: (val) {
                  setState(() => _roundTrip = val);
                  widget.onChangeRoundTrip(val);
                },
              ),
            ),
            const Divider(height: 1),

            // Bottom bar
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
              child: Row(
                children: [
                  // Price on right in RTL
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          'مبلغ الرحلة',
                          style: TextStyle(
                            fontSize: 13,
                            color: dark ? Colors.white70 : Colors.grey,
                          ),
                        ),
                        Text(
                          formatIraqiDinar(currentPrice),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                            color: primaryText,
                          ),
                        ),
                      ],
                    ),
                  ),

                  // Actions on left in RTL
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      'انهاء',
                      style: TextStyle(
                        fontSize: 16,
                        color: primaryText,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      widget.onConfirm();
                      Navigator.of(context).pop();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF194BFB),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 26,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'تأكيد',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Driver and trip feedback rating screen/sheet (Image 4)
class DriverRatingSheet extends StatefulWidget {
  const DriverRatingSheet({
    super.key,
    required this.driverName,
    required this.driverCar,
    required this.destinationName,
    required this.tripTime,
    required this.onSubmit,
  });

  final String driverName;
  final String driverCar;
  final String destinationName;
  final String tripTime;
  final void Function(int rating, String comment) onSubmit;

  @override
  State<DriverRatingSheet> createState() => _DriverRatingSheetState();
}

class _DriverRatingSheetState extends State<DriverRatingSheet> {
  int _rating = 5; // Default 5 stars
  final _commentController = TextEditingController();

  @override
  void dispose() {
    _commentController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? const Color(0xFF182522) : Colors.white;
    final primaryText = dark ? Colors.white : const Color(0xFF142421);
    final mutedText = dark ? Colors.white70 : Colors.grey.shade700;
    return Material(
      color: surface,
      borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 14,
          bottom: MediaQuery.of(context).viewInsets.bottom + 24,
        ),
        child: SafeArea(
          top: false,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Header
                Stack(
                  alignment: Alignment.center,
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: IconButton(
                        icon: Icon(
                          Icons.close,
                          color: dark ? Colors.white : Colors.black87,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                    Text(
                      'تقييم السائق',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: primaryText,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // Driver Card
                Row(
                  children: [
                    // Driver Avatar Circle
                    Container(
                      width: 60,
                      height: 60,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: dark
                            ? const Color(0xFF273B38)
                            : Colors.grey.shade200,
                        border: Border.all(
                          color: dark ? const Color(0xFF30413D) : Colors.white,
                          width: 2,
                        ),
                        boxShadow: const [
                          BoxShadow(color: Colors.black12, blurRadius: 6),
                        ],
                      ),
                      clipBehavior: Clip.antiAlias,
                      child: const Icon(
                        Icons.person,
                        size: 44,
                        color: Color(0xFF4A5568),
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.driverName,
                            style: TextStyle(
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                              color: primaryText,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Text(
                            widget.driverCar,
                            style: TextStyle(fontSize: 14, color: mutedText),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),

                // Route details
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: const Color(0xFF0038FF),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        widget.destinationName,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: primaryText,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                const Divider(height: 1),
                const SizedBox(height: 10),

                // Date details
                Row(
                  children: [
                    const Icon(
                      Icons.calendar_today_outlined,
                      size: 18,
                      color: Colors.grey,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      widget.tripTime,
                      style: TextStyle(
                        fontSize: 15,
                        color: mutedText,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 28),

                // Rating section
                Text(
                  'قيم الرحلة والسائق',
                  style: TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w900,
                    color: primaryText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'كيف كانت الرحلة؟',
                  style: TextStyle(fontSize: 15, color: Colors.grey.shade600),
                ),
                const SizedBox(height: 16),

                // 5 Star Rating Row
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(5, (index) {
                    final starIndex = index + 1;
                    return IconButton(
                      iconSize: 42,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      icon: Icon(
                        starIndex <= _rating
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        color: starIndex <= _rating
                            ? const Color(0xFFFFB800)
                            : Colors.grey.shade300,
                      ),
                      onPressed: () => setState(() => _rating = starIndex),
                    );
                  }),
                ),

                // Labels under stars: سيء جداً (on right) and جيد جداً (on left)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(
                        'سيء جداً',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                      Text(
                        'جيد جداً',
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey.shade600,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // Privacy Notice
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(
                      Icons.visibility_off_outlined,
                      size: 20,
                      color: Color(0xFF5A5F6B),
                    ),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'سيتم الاحتفاظ بتقييمك بشكل سري ولن يعرف السائق به.',
                        style: TextStyle(
                          fontSize: 13,
                          color: Color(0xFF5A5F6B),
                          height: 1.3,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),

                // Submit Button
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: () {
                      widget.onSubmit(_rating, _commentController.text.trim());
                      Navigator.of(context).pop();
                    },
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF0038FF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 0,
                    ),
                    child: const Text(
                      'إرسال التقييم',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
