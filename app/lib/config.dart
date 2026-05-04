import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

class AppConfig {
  static String _remoteUrl = '';

  /// Called once at app startup. Fetches the live tunnel URL.
  static Future<void> initialize() async {
    try {
      // Fetch the latest published Cloudflare URL from the unique discovery bridge
      final response = await http
          .get(Uri.parse('https://ntfy.sh/transfera-suvodeep-bridge/raw?poll=1'))
          .timeout(const Duration(seconds: 5));

      if (response.statusCode == 200) {
        final lines = response.body.split('\n').where((l) => l.trim().isNotEmpty).toList();
        if (lines.isNotEmpty) {
          final url = lines.last.trim();
          if (url.startsWith('http')) {
            _remoteUrl = url;
            debugPrint('[CONFIG] Fetched live Cloudflare URL from unique bridge: $_remoteUrl');
            return;
          }
        }
      }
    } catch (e) {
      debugPrint('[CONFIG] Could not fetch remote config from bridge: $e');
    }

    // Local fallback: try localhost config if we're running locally on macOS
    try {
      final response = await http
          .get(Uri.parse('http://127.0.0.1:3000/config'))
          .timeout(const Duration(seconds: 2));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final url = data['tunnelUrl'] as String?;
        if (url != null && url.isNotEmpty) {
          _remoteUrl = url;
          debugPrint('[CONFIG] Fetched live tunnel URL from local server: $_remoteUrl');
          return;
        }
      }
    } catch (_) {}

    // Ultimate fallback: On macOS the server IS localhost, so use that directly.
    if (!kIsWeb && Platform.isMacOS) {
      _remoteUrl = 'http://127.0.0.1:3000';
    }
    debugPrint('[CONFIG] Using fallback URL: $_remoteUrl');
  }

  static String get remoteUrl => _remoteUrl;
  
  static void updateRemoteUrl(String url) {
    if (url.isNotEmpty && url.startsWith('http')) {
      _remoteUrl = url;
      debugPrint('[CONFIG] Remote URL updated dynamically to: $_remoteUrl');
    }
  }

  static String get signalingUrl {
    // macOS: the server runs locally, always hit it directly.
    if (!kIsWeb && Platform.isMacOS) {
      return 'http://127.0.0.1:3000';
    }
    // Android/iOS: must use the remote tunnel URL
    if (_remoteUrl.isNotEmpty) return _remoteUrl;
    return 'http://10.0.2.2:3000'; // emulator fallback
  }
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
