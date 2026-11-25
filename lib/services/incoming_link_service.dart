import 'dart:async';

import 'package:flutter/services.dart';

import 'map_link_parser.dart';

/// Bridges native Android/iOS Share Sheet (`ACTION_SEND`) and Deep Links
/// (`ACTION_VIEW` for `darb://`, `geo:`) into Darb Taxi across cold start,
/// background, and foreground states.
class IncomingLinkService {
  IncomingLinkService._();
  static final IncomingLinkService instance = IncomingLinkService._();

  static const _methodChannel = MethodChannel(
    'iq.ridepassenger.car/incoming_links',
  );
  static const _eventChannel = EventChannel(
    'iq.ridepassenger.car/incoming_links_stream',
  );

  final _controller = StreamController<String>.broadcast();
  StreamSubscription<dynamic>? _nativeSub;
  bool _initialized = false;

  Stream<String> get rawIncomingLinks => _controller.stream;

  Future<String?> initializeAndCheckInitial() async {
    if (!_initialized) {
      _initialized = true;
      try {
        _nativeSub = _eventChannel.receiveBroadcastStream().listen((event) {
          if (event is String && event.trim().isNotEmpty) {
            _controller.add(event.trim());
          }
        }, onError: (_) {});
      } catch (_) {}
    }

    try {
      final initial = await _methodChannel.invokeMethod<String>(
        'getInitialLink',
      );
      if (initial != null && initial.trim().isNotEmpty) {
        return initial.trim();
      }
    } catch (_) {}
    return null;
  }

  Future<ParsedMapLocation?> parseIncomingText(String text) =>
      MapLinkParserService.resolveAndParse(text);

  void dispose() {
    _nativeSub?.cancel();
    _controller.close();
  }
}
