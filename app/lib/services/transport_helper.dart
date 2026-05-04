import 'dart:async';
import 'package:flutter/foundation.dart';
import 'webrtc_service.dart';
import 'telemetry_service.dart';
import 'platform_utils.dart';
import '../config.dart';

/// SMART TRANSPORT RACE HELPER
/// Coordinates multiple transport attempts without interrupting existing flows.
/// Wrapped under FEATURES.smartTransportRace — called only by TransferManager.sendFile().
class TransportHelper {

  /// Races WebRTC and Relay transports.
  /// Returns true if relay (fallback) should be used, false for WebRTC P2P.
  ///
  /// Rules:
  ///  - Only 2 real participants: WebRTC open event vs. relay timeout.
  ///  - Carrier learning can short-circuit the race entirely (no wait).
  ///  - Fails silently on any error — caller falls back to original flow.
  static Future<bool> race(WebRTCService webrtc, String? sessionId) async {
    debugPrint('[TRANSPORT-RACE] Initiating smart race (FEATURES.smartTransportRace=true)');

    // ── CARRIER LEARNING: decide before the race ──────────────────────────────
    if (FEATURES.carrierLearning) {
      try {
        final String? learned = await TelemetryService().getLearnedRoute(
          carrier: webrtc.currentResultsString,
          senderPlatform: PlatformUtils.operatingSystem,
          receiverPlatform: 'any',
        );

        if (learned == 'Relay') {
          // Relay is historically superior on this carrier → skip race entirely.
          debugPrint('[TRANSPORT-RACE] LEARNED: Relay is superior on this carrier. Skipping race.');
          return true; // useFallback = true
        } else if (learned != null) {
          // WebRTC (or TCP) was historically better → let the full 6s race run.
          debugPrint('[TRANSPORT-RACE] LEARNED: $learned is superior on this carrier. Running full race.');
        }
      } catch (e) {
        // Advisory only — never block the transfer on a learning error.
        debugPrint('[TRANSPORT-RACE] Carrier learning error (ignored): $e');
      }
    }

    // ── RACE: WebRTC vs. Relay timeout ────────────────────────────────────────
    // Only real participants are included — no dead QUIC/TCP placeholders.
    try {
      final bool useFallback = await Future.any([
        // Participant 1: WebRTC DataChannel open (monitors existing connection, no restart)
        webrtc.onDataChannelOpen.then((_) {
          debugPrint('[TRANSPORT-RACE] WINNER: WebRTC P2P');
          return false; // useFallback = false
        }),

        // Participant 2: Relay timeout — relay wins if WebRTC hasn't opened in 6s
        Future.delayed(const Duration(seconds: 6)).then((_) {
          debugPrint('[TRANSPORT-RACE] WINNER: Relay (WebRTC did not open in 6s)');
          return true; // useFallback = true
        }),
      ]);
      return useFallback;
    } catch (e) {
      // Fail silently — caller will fall back to original connection flow.
      debugPrint('[TRANSPORT-RACE] Race error (ignored): $e');
      rethrow;
    }
  }
}
