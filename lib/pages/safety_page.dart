import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/location_service.dart';
import '../theme/darb_theme.dart';
import '../widgets/darb_components.dart';

class TrustedContact {
  const TrustedContact({required this.name, required this.phone});

  final String name;
  final String phone;

  Map<String, dynamic> toJson() => {'name': name, 'phone': phone};

  factory TrustedContact.fromJson(Map<String, dynamic> json) => TrustedContact(
    name: (json['name'] ?? '').toString(),
    phone: (json['phone'] ?? '').toString(),
  );
}

/// Passenger Safety Center: Emergency SOS actions + local Trusted Contacts.
class SafetyCenterPage extends StatefulWidget {
  const SafetyCenterPage({super.key});

  @override
  State<SafetyCenterPage> createState() => _SafetyCenterPageState();
}

class _SafetyCenterPageState extends State<SafetyCenterPage> {
  static const _prefsKey = 'darb_trusted_contacts_v1';

  List<TrustedContact> _contacts = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  Future<void> _loadContacts() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefsKey);
    final list = <TrustedContact>[];
    if (raw != null && raw.isNotEmpty) {
      try {
        for (final item in (jsonDecode(raw) as List<dynamic>)) {
          if (item is Map) {
            list.add(TrustedContact.fromJson(Map<String, dynamic>.from(item)));
          }
        }
      } catch (_) {}
    }
    if (mounted) {
      setState(() {
        _contacts = list;
        _loading = false;
      });
    }
  }

  Future<void> _saveContacts(List<TrustedContact> next) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _prefsKey,
      jsonEncode(next.map((c) => c.toJson()).toList()),
    );
    if (mounted) setState(() => _contacts = next);
  }

  Future<void> _addContactDialog() async {
    final nameCtrl = TextEditingController();
    final phoneCtrl = TextEditingController();
    final added = await showDialog<TrustedContact>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('إضافة جهة اتصال موثوقة'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'الاسم (مثال: أخي علي)',
                prefixIcon: Icon(Icons.person_outline),
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: phoneCtrl,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(
                labelText: 'رقم الهاتف',
                prefixIcon: Icon(Icons.phone_outlined),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () {
              final n = nameCtrl.text.trim();
              final p = phoneCtrl.text.trim();
              if (n.isEmpty || p.isEmpty) return;
              Navigator.pop(ctx, TrustedContact(name: n, phone: p));
            },
            style: FilledButton.styleFrom(backgroundColor: DarbColors.green),
            child: const Text('حفظ'),
          ),
        ],
      ),
    );
    if (added != null) {
      await _saveContacts([added, ..._contacts]);
    }
  }

  Future<void> _callEmergency(String number) async {
    await launchUrl(Uri(scheme: 'tel', path: number));
  }

  Future<void> _shareSosLocation() async {
    final loc = await GeolocatorLocationService.instance
        .getCurrentUserLocation();
    final mapUrl =
        'https://www.openstreetmap.org/?mlat=${loc.latitude}&mlon=${loc.longitude}#map=16/${loc.latitude}/${loc.longitude}';
    final msg =
        'تنبيه طوارئ من تطبيق درب!\n'
        'أحتاج مساعدة عاجلة، موقعي الحالي:\n$mapUrl';
    await SharePlus.instance.share(ShareParams(text: msg));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('الأمان والطوارئ (SOS)')),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _addContactDialog,
        backgroundColor: DarbColors.green,
        foregroundColor: Colors.white,
        icon: const Icon(Icons.person_add_alt_1_outlined),
        label: const Text('إضافة جهة موثوقة'),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 96),
        children: [
          Card(
            color: Colors.redAccent.withValues(alpha: 0.08),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.emergency_share_rounded,
                        color: Colors.redAccent,
                        size: 26,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'نداء الطوارئ السريع (SOS)',
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w900,
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'يستخدم الاتصال المباشر بالجهات الرسمية أو مشاركة موقعك الحالي عبر تطبيقات الرسائل.',
                    style: TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _callEmergency('104'),
                          style: FilledButton.styleFrom(
                            backgroundColor: Colors.redAccent,
                          ),
                          icon: const Icon(Icons.local_police_outlined),
                          label: const Text('الشرطة 104'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: FilledButton.icon(
                          onPressed: () => _callEmergency('122'),
                          style: FilledButton.styleFrom(
                            backgroundColor: DarbColors.orange,
                          ),
                          icon: const Icon(Icons.medical_services_outlined),
                          label: const Text('الإسعاف 122'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(
                    onPressed: _shareSosLocation,
                    icon: const Icon(Icons.my_location),
                    label: const Text('مشاركة موقعي للطوارئ فوراً'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          const Text(
            'جهات الاتصال الموثوقة (محفوظة على جهازك)',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (_loading)
            const DarbStateView.loading(message: 'جارٍ تحميل جهات الاتصال...')
          else if (_contacts.isEmpty)
            const DarbStateView.empty(
              icon: Icons.contact_phone_outlined,
              title: 'لا توجد جهات اتصال موثوقة',
              subtitle: 'أضف رقم قريب أو صديق للتواصل السريع عند الطوارئ.',
            )
          else
            ..._contacts.asMap().entries.map((entry) {
              final idx = entry.key;
              final c = entry.value;
              return Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      backgroundColor: DarbColors.green.withValues(alpha: 0.12),
                      child: const Icon(
                        Icons.verified_user_outlined,
                        color: DarbColors.green,
                      ),
                    ),
                    title: Text(
                      c.name,
                      style: const TextStyle(fontWeight: FontWeight.bold),
                    ),
                    subtitle: Text(c.phone),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          tooltip: 'إرسال SMS',
                          onPressed: () =>
                              launchUrl(Uri(scheme: 'sms', path: c.phone)),
                          icon: const Icon(Icons.sms_outlined),
                        ),
                        IconButton(
                          tooltip: 'حذف',
                          onPressed: () {
                            final next = [..._contacts]..removeAt(idx);
                            _saveContacts(next);
                          },
                          icon: const Icon(
                            Icons.delete_outline,
                            color: Colors.redAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}
