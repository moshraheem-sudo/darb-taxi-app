import 'package:dio/dio.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class PassengerApi {
  PassengerApi({Dio? dio})
    : _dio =
          dio ??
          Dio(
            BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
            ),
          );

  final Dio _dio;
  static const _secureStorage = FlutterSecureStorage();

  Future<String> _baseUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final value = prefs.getString('api_base_url')?.trim();
    if (value == null || value.isEmpty) {
      throw StateError('أضف عنوان خادم الخدمة من الإعدادات أولاً.');
    }
    return value.replaceFirst(RegExp(r'/+$'), '');
  }

  Future<void> requestOtp({required String name, required String phone}) async {
    final base = await _baseUrl();
    await _dio.post(
      '$base/auth/otp/request',
      data: {'full_name': name, 'phone': phone},
    );
  }

  Future<void> verifyOtp({required String phone, required String code}) async {
    final base = await _baseUrl();
    final response = await _dio.post(
      '$base/auth/otp/verify',
      data: {'phone': phone, 'code': code},
    );
    final token = response.data is Map
        ? (response.data['access_token'] as String?)
        : null;
    if (token == null || token.isEmpty) {
      throw const FormatException('لم يُرجع الخادم رمز الدخول المتوقع.');
    }
    await _secureStorage.write(key: 'passenger_access_token', value: token);
  }

  Future<void> submitSupport({
    required String category,
    required String details,
  }) async {
    final base = await _baseUrl();
    final token = await _secureStorage.read(key: 'passenger_access_token');
    if (token == null) throw StateError('سجّل الدخول قبل إرسال البلاغ.');
    await _dio.post(
      '$base/support/tickets',
      data: {'category': category, 'details': details},
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
  }

  Future<void> submitRideFeedback({
    required String rideId,
    required List<String> reasons,
    required String details,
  }) async {
    final base = await _baseUrl();
    final token = await _secureStorage.read(key: 'passenger_access_token');
    if (token == null) throw StateError('سجّل الدخول قبل إرسال التقييم.');
    await _dio.post(
      '$base/rides/$rideId/feedback',
      data: {'reasons': reasons, 'details': details},
      options: Options(headers: {'Authorization': 'Bearer $token'}),
    );
  }
}
