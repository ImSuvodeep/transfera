import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

class TransferRecord {
  final String fileName;
  final int fileSize; // bytes
  final String direction; // 'sent' or 'received'
  final DateTime timestamp;
  final Duration? duration;
  final double? speedBytesPerSec;

  TransferRecord({
    required this.fileName,
    required this.fileSize,
    required this.direction,
    required this.timestamp,
    this.duration,
    this.speedBytesPerSec,
  });

  Map<String, dynamic> toJson() => {
        'fileName': fileName,
        'fileSize': fileSize,
        'direction': direction,
        'timestamp': timestamp.toIso8601String(),
        'durationMs': duration?.inMilliseconds,
        'speedBytesPerSec': speedBytesPerSec,
      };

  factory TransferRecord.fromJson(Map<String, dynamic> j) => TransferRecord(
        fileName: j['fileName'] ?? 'Unknown',
        fileSize: j['fileSize'] ?? 0,
        direction: j['direction'] ?? 'unknown',
        timestamp: DateTime.tryParse(j['timestamp'] ?? '') ?? DateTime.now(),
        duration: j['durationMs'] != null
            ? Duration(milliseconds: j['durationMs'])
            : null,
        speedBytesPerSec: (j['speedBytesPerSec'] as num?)?.toDouble(),
      );

  String get formattedSize {
    if (fileSize < 1024) return '${fileSize}B';
    if (fileSize < 1024 * 1024) return '${(fileSize / 1024).toStringAsFixed(1)}KB';
    if (fileSize < 1024 * 1024 * 1024) return '${(fileSize / (1024 * 1024)).toStringAsFixed(1)}MB';
    return '${(fileSize / (1024 * 1024 * 1024)).toStringAsFixed(2)}GB';
  }

  String get formattedSpeed {
    if (speedBytesPerSec == null || speedBytesPerSec == 0) return '';
    final mbps = speedBytesPerSec! / (1024 * 1024);
    return '${mbps.toStringAsFixed(1)} MB/s';
  }

  String get formattedDuration {
    if (duration == null) return '';
    final s = duration!.inSeconds;
    if (s < 60) return '${s}s';
    return '${duration!.inMinutes}m ${s % 60}s';
  }
}

class HistoryService {
  static final HistoryService _instance = HistoryService._internal();
  factory HistoryService() => _instance;
  HistoryService._internal();

  final ValueNotifier<List<TransferRecord>> records = ValueNotifier([]);

  Future<File> _getFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/transfera_history.json');
  }

  Future<void> load() async {
    try {
      final file = await _getFile();
      if (!file.existsSync()) return;
      final raw = file.readAsStringSync();
      final list = jsonDecode(raw) as List;
      records.value = list
          .map((e) => TransferRecord.fromJson(e as Map<String, dynamic>))
          .toList()
          .reversed
          .toList();
    } catch (e) {
      debugPrint('[HISTORY] Load error: $e');
    }
  }

  Future<void> add(TransferRecord record) async {
    try {
      // Prepend so newest is first
      records.value = [record, ...records.value];
      final file = await _getFile();
      // Save newest-first in file too
      file.writeAsStringSync(
        jsonEncode(records.value.map((r) => r.toJson()).toList()),
      );
    } catch (e) {
      debugPrint('[HISTORY] Save error: $e');
    }
  }

  Future<void> clear() async {
    records.value = [];
    final file = await _getFile();
    if (file.existsSync()) file.deleteSync();
  }
}
