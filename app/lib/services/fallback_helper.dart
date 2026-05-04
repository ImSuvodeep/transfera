import 'package:flutter/foundation.dart';
import 'webrtc_service.dart';

/// WARM FALLBACK HELPER
/// Manages standby transport states for seamless mid-transfer recovery.
class FallbackHelper {
  // Track state per session to ensure unique fallback attempts
  static final Map<String, bool> _didAttemptFallback = {};
  static final Map<String, bool> _isTransportFailed = {};

  /// Pre-warms fallback configurations after a successful primary connection.
  /// Does not create new connections, only verifies/prepares existing lightweight state.
  static void preWarm(WebRTCService webrtc, String sessionId) {
    debugPrint('[FALLBACK] Pre-warming standby transports for session: $sessionId');
    
    // 1. Verify Relay Socket health (Signaling socket is already active)
    // We check if the signaling socket is connected as it doubles as our relay.
    if (webrtc.isSocketConnected.value) {
      debugPrint('[FALLBACK] Relay transport is WARM and READY (Signaling Socket)');
    }
    
    // 2. Prepare QUIC/TCP configurations (Placeholders for future expansion)
    _prepareQuicConfig();
    _prepareTcpConfig();
    
    // Initialize flags for this session if not already present
    _didAttemptFallback[sessionId] ??= false;
    _isTransportFailed[sessionId] ??= false;
  }

  /// Marks the active transport as failed, triggering the potential for a fallback swap.
  /// Called when WebRTC connection state changes to 'disconnected' or 'failed'.
  static void markFailed(String sessionId) {
    if (_isTransportFailed[sessionId] == true) return;
    
    debugPrint('[FALLBACK] Active transport failed for session: $sessionId. Standby transports notified.');
    _isTransportFailed[sessionId] = true;
  }

  /// Queries if a fallback swap should be performed.
  /// Rules: 
  /// - Only triggers if the transport has failed.
  /// - Only allows ONE fallback attempt per session to prevent loops.
  static bool querySwap(String sessionId) {
    if (_isTransportFailed[sessionId] == true && _didAttemptFallback[sessionId] == false) {
      debugPrint('[FALLBACK] Swap condition met. Activating standby relay transport for session: $sessionId');
      _didAttemptFallback[sessionId] = true; // Mark as attempted
      return true; // Yes, activate fallback
    }
    return false; // No swap needed or already attempted
  }

  /// Resets state for a new session.
  static void reset(String sessionId) {
    _didAttemptFallback.remove(sessionId);
    _isTransportFailed.remove(sessionId);
    debugPrint('[FALLBACK] State reset for session: $sessionId');
  }

  // --- Placeholder Pre-warmers ---
  
  static void _prepareQuicConfig() {
    // Logic for pre-computing QUIC handshake state would go here.
  }

  static void _prepareTcpConfig() {
    // Logic for local bridge pre-connection would go here.
  }
}
