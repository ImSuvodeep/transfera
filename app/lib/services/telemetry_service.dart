import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';
import '../config.dart';

class TransferSession {
  final String id;
  final DateTime timestamp;
  int? connectTimeMs;
  int? firstByteTimeMs;
  String? route;
  String? carrier;
  String? natType;
  String? senderPlatform;
  String? receiverPlatform;
  double? speedMbps;
  bool isSuccess;

  TransferSession({
    required this.id,
    required this.timestamp,
    this.isSuccess = false,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'timestamp': timestamp.toIso8601String(),
    'connectTimeMs': connectTimeMs,
    'firstByteTimeMs': firstByteTimeMs,
    'route': route,
    'carrier': carrier,
    'natType': natType,
    'senderPlatform': senderPlatform,
    'receiverPlatform': receiverPlatform,
    'speedMbps': speedMbps,
    'isSuccess': isSuccess,
  };

  factory TransferSession.fromJson(Map<String, dynamic> json) {
    var session = TransferSession(
      id: json['id'],
      timestamp: DateTime.parse(json['timestamp']),
      isSuccess: json['isSuccess'] ?? false,
    );
    session.connectTimeMs = json['connectTimeMs'];
    session.firstByteTimeMs = json['firstByteTimeMs'];
    session.route = json['route'];
    session.carrier = json['carrier'];
    session.natType = json['natType'];
    session.senderPlatform = json['senderPlatform'];
    session.receiverPlatform = json['receiverPlatform'];
    session.speedMbps = json['speedMbps'];
    return session;
  }
}

class TelemetryService {
  static final TelemetryService _instance = TelemetryService._internal();
  factory TelemetryService() => _instance;
  TelemetryService._internal();

  TransferSession? _current;
  DateTime? _connStartTime;
  DateTime? _transferStartTime;
  int _bytesTransferred = 0;
  bool _firstByteMarked = false;

  void startSession(String sid) {
    if (!FEATURES.transferMetrics) return;
    _current = TransferSession(id: sid, timestamp: DateTime.now());
    _connStartTime = DateTime.now();
    _bytesTransferred = 0;
    _firstByteMarked = false;
  }

  void markConnected(String route, String carrier, {String? natType, String? senderPlatform, String? receiverPlatform}) {
    if (_current == null) return;
    _current!.connectTimeMs = DateTime.now().difference(_connStartTime!).inMilliseconds;
    _current!.route = route;
    _current!.carrier = carrier;
    _current!.natType = natType;
    _current!.senderPlatform = senderPlatform;
    _current!.receiverPlatform = receiverPlatform;
    _transferStartTime = DateTime.now();
    debugPrint('[TELEMETRY] Connected in ${_current!.connectTimeMs}ms via $route ($carrier)');
  }

  void markFirstByte() {
    if (_current == null || _transferStartTime == null || _firstByteMarked) return;
    _firstByteMarked = true;
    _current!.firstByteTimeMs = DateTime.now().difference(_transferStartTime!).inMilliseconds;
    debugPrint('[TELEMETRY] First byte in ${_current!.firstByteTimeMs}ms');
  }

  void updatePlatforms({String? sender, String? receiver}) {
    if (_current == null) return;
    if (sender != null) _current!.senderPlatform = sender;
    if (receiver != null) _current!.receiverPlatform = receiver;
  }

  void trackProgress(int bytes) {
    _bytesTransferred += bytes;
  }

  Future<void> finish(bool success) async {
    if (_current == null) return;
    _current!.isSuccess = success;
    
    if (_transferStartTime != null && _bytesTransferred > 0) {
      final durationSec = DateTime.now().difference(_transferStartTime!).inSeconds;
      if (durationSec > 0) {
        _current!.speedMbps = (_bytesTransferred * 8) / (durationSec * 1024 * 1024);
      }
    }

    debugPrint('[TELEMETRY] Session ${_current!.id} finished. Success: $success. Speed: ${_current!.speedMbps?.toStringAsFixed(2)} Mbps');
    await _saveSession(_current!);
    _current = null;
  }

  Future<void> _saveSession(TransferSession session) async {
    try {
      final file = await _getStorageFile();
      List<dynamic> history = [];
      if (await file.exists()) {
        final content = await file.readAsString();
        history = json.decode(content);
      }
      history.insert(0, session.toJson());
      // Keep only last 50
      if (history.length > 50) history = history.sublist(0, 50);
      await file.writeAsString(json.encode(history));
    } catch (e) {
      debugPrint('[TELEMETRY] Error saving session: $e');
    }
  }

  Future<List<TransferSession>> getHistory() async {
    try {
      final file = await _getStorageFile();
      if (!await file.exists()) return [];
      final content = await file.readAsString();
      final List<dynamic> jsonList = json.decode(content);
      return jsonList.map((j) => TransferSession.fromJson(j)).toList();
    } catch (e) {
      debugPrint('[TELEMETRY] Error loading history: $e');
      return [];
    }
  }

  Future<File> _getStorageFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/telemetry.json');
  }

  /// CARRIER LEARNING: Predicts the best route based on history
  Future<String?> getLearnedRoute({
    required String carrier,
    required String senderPlatform,
    required String receiverPlatform,
  }) async {
    if (!FEATURES.carrierLearning) return null;
    
    final history = await getHistory();
    final matching = history.where((s) => 
      s.carrier == carrier && 
      s.senderPlatform == senderPlatform && 
      s.receiverPlatform == receiverPlatform
    ).toList();

    if (matching.length < 3) return null; // Need minimum data

    // Group by route
    final Map<String, List<TransferSession>> routes = {};
    for (var s in matching) {
      routes[s.route!] ??= [];
      routes[s.route!]!.add(s);
    }

    String? bestRoute;
    double bestScore = 0;

    routes.forEach((routeName, sessions) {
      final successRate = sessions.where((s) => s.isSuccess).length / sessions.length;
      if (successRate >= 0.7) {
        final avgSpeed = sessions.fold(0.0, (double sum, s) => sum + (s.speedMbps ?? 0)) / sessions.length;
        // Score = Speed weighted by success
        final score = avgSpeed * successRate;
        if (score > bestScore) {
          bestScore = score;
          bestRoute = routeName;
        }
      }
    });

    if (bestRoute != null) {
      debugPrint('[LEARNING] Historically superior route found: $bestRoute (Score: ${bestScore.toStringAsFixed(2)})');
    }
    
    return bestRoute;
  }
}
