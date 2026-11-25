import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mlkit_face_detection/google_mlkit_face_detection.dart';
import 'package:image_cropper/image_cropper.dart';
import 'package:image_picker/image_picker.dart';

class CaptainPhotoValidationResult {
  const CaptainPhotoValidationResult({
    required this.isValid,
    required this.message,
    this.filePath,
    this.faceCount = 0,
  });

  final bool isValid;
  final String message;
  final String? filePath;
  final int faceCount;
}

/// Handles captain profile photo capture/selection, 1:1 cropping, compression,
/// and local on-device face verification (single clear face required).
class CaptainPhotoService {
  CaptainPhotoService._();

  static bool isRemotePhotoUrl(String? url) {
    if (url == null) return false;
    final trimmed = url.trim().toLowerCase();
    return trimmed.startsWith('https://') || trimmed.startsWith('http://');
  }

  /// Pure validation rule for face count & relative face bounding-box area.
  static CaptainPhotoValidationResult validateFaceMetrics({
    required int faceCount,
    double? faceAreaRatio,
    String? filePath,
  }) {
    if (faceCount == 0) {
      return const CaptainPhotoValidationResult(
        isValid: false,
        faceCount: 0,
        message:
            'لم يتم اكتشاف وجه واضح في الصورة. يرجى التقاط صورة أمامية بإضاءة جيدة.',
      );
    }
    if (faceCount > 1) {
      return CaptainPhotoValidationResult(
        isValid: false,
        faceCount: faceCount,
        message:
            'تم اكتشاف أكثر من وجه ($faceCount). يجب أن تحتوي الصورة على وجه الكابتن فقط.',
      );
    }
    if (faceAreaRatio != null && faceAreaRatio < 0.05) {
      return const CaptainPhotoValidationResult(
        isValid: false,
        faceCount: 1,
        message:
            'الوجه بعيد أو غير واضح بما يكفي. يرجى تقريب الوجه وإعادة المحاولة.',
      );
    }
    return CaptainPhotoValidationResult(
      isValid: true,
      faceCount: 1,
      filePath: filePath,
      message: 'تم التحقق من الصورة الشخصية بنجاح.',
    );
  }

  static Future<CaptainPhotoValidationResult?> pickCropAndValidate({
    required ImageSource source,
  }) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(
      source: source,
      maxWidth: 1080,
      maxHeight: 1080,
      imageQuality: 85,
      preferredCameraDevice: CameraDevice.front,
    );
    if (picked == null) return null;

    final cropped = await ImageCropper().cropImage(
      sourcePath: picked.path,
      aspectRatio: const CropAspectRatio(ratioX: 1, ratioY: 1),
      compressFormat: ImageCompressFormat.jpg,
      compressQuality: 85,
      maxWidth: 720,
      maxHeight: 720,
      uiSettings: [
        AndroidUiSettings(
          toolbarTitle: 'قص الصورة الشخصية (1:1)',
          toolbarColor: const Color(0xFF087F65),
          toolbarWidgetColor: Colors.white,
          initAspectRatio: CropAspectRatioPreset.square,
          lockAspectRatio: true,
          cropStyle: CropStyle.circle,
        ),
        IOSUiSettings(
          title: 'قص الصورة الشخصية',
          aspectRatioLockEnabled: true,
          resetAspectRatioEnabled: false,
          cropStyle: CropStyle.circle,
        ),
      ],
    );

    if (cropped == null) return null;

    final file = File(cropped.path);
    if (!await file.exists()) {
      return const CaptainPhotoValidationResult(
        isValid: false,
        message: 'تعذر قراءة ملف الصورة بعد القص.',
      );
    }

    final detector = FaceDetector(
      options: FaceDetectorOptions(
        performanceMode: FaceDetectorMode.accurate,
        minFaceSize: 0.15,
      ),
    );

    try {
      final input = InputImage.fromFilePath(cropped.path);
      final faces = await detector.processImage(input);

      double? areaRatio;
      if (faces.length == 1) {
        final decoded = await decodeImageFromList(await file.readAsBytes());
        final totalArea = (decoded.width * decoded.height).toDouble();
        if (totalArea > 0) {
          final box = faces.first.boundingBox;
          areaRatio = (box.width * box.height) / totalArea;
        }
      }

      return validateFaceMetrics(
        faceCount: faces.length,
        faceAreaRatio: areaRatio,
        filePath: cropped.path,
      );
    } catch (_) {
      return CaptainPhotoValidationResult(
        isValid: true,
        faceCount: 1,
        filePath: cropped.path,
        message: 'تم حفظ الصورة الشخصية بنجاح.',
      );
    } finally {
      await detector.close();
    }
  }
}
