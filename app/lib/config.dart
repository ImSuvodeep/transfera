import 'package:flutter/foundation.dart';

class AppConfig {
  // Permanent cloud server URL — no Mac, no tunnel, no NTFY bridge needed.
  static const String _renderUrl = 'https://transfera-server.onrender.com';
  static String _remoteUrl = _renderUrl;

  /// Called once at app startup.
  static Future<void> initialize() async {
    _remoteUrl = _renderUrl;
    debugPrint('[CONFIG] Using permanent Render server: $_remoteUrl');
  }

  static String get remoteUrl => _remoteUrl;

  static void updateRemoteUrl(String url) {
    if (url.isNotEmpty && url.startsWith('http')) {
      _remoteUrl = url;
      debugPrint('[CONFIG] Remote URL updated dynamically to: $_remoteUrl');
    }
  }

  static String get signalingUrl => _remoteUrl;
}


class FEATURES {
  static const bool smartTransportRace = true;
  static const bool warmFallbacks = true;
  static const bool routeIndicator = true;
  static const bool remoteContinuation = true;
  static const bool transferMetrics = true;
  static const bool advancedTelemetry = true;
  static const bool carrierLearning = true;

  /// Monitors throughput and falls back to relay if performance degrades.
  static const bool smartSwitching = true;

  /// Retries individual chunks locally upon transient network failures to prevent stream crashes.
  static const bool preciseRetries = true;

  /// Replaces unbounded stream reading with controlled chunk-size reads.
  /// Starts at 512KB, grows up to 2MB based on ACK speed, shrinks on retry.
  static const bool adaptiveChunkSize = false;

  /// Read+encrypt next chunk(s) while the current chunk is being sent.
  /// Send order remains strictly sequential. No parallel network writes.
  static const bool parallelChunks = false;
}
