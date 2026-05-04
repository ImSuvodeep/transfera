import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/foundation.dart';

/// NETWORK MONITORING SERVICE
/// Detects transitions between Wi-Fi, Hotspot, and Mobile Data.
class NetworkService {
  final Connectivity _connectivity = Connectivity();
  StreamSubscription<List<ConnectivityResult>>? _subscription;
  
  Function(List<ConnectivityResult>)? onNetworkChanged;
  List<ConnectivityResult> _lastResults = [];

  void start() {
    debugPrint('[NETWORK] Starting connectivity monitoring...');
    _subscription = _connectivity.onConnectivityChanged.listen((List<ConnectivityResult> results) {
      if (_hasChanged(results)) {
        debugPrint('[NETWORK] Interface change detected: $results');
        onNetworkChanged?.call(results);
      }
      _lastResults = results;
    });
  }

  bool _hasChanged(List<ConnectivityResult> newResults) {
    if (_lastResults.length != newResults.length) return true;
    for (int i = 0; i < newResults.length; i++) {
      if (_lastResults[i] != newResults[i]) return true;
    }
    return false;
  }

  void stop() {
    _subscription?.cancel();
  }
}
