import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:flutter/foundation.dart';
import 'platform_utils.dart';
import 'package:path_provider/path_provider.dart';
import '../config.dart';
import 'encryption_service.dart';
import 'webrtc_service.dart';
import 'transport_helper.dart';
import 'telemetry_service.dart';
import 'package:crypto/crypto.dart';
import 'package:open_file_plus/open_file_plus.dart';
import 'tcp_transport_service.dart';
import 'file_handler.dart';
import 'fallback_helper.dart';

class BatchFile {
  final String id;
  final String path;
  final int size;
  final int lastModified;
  final dynamic source; // File object or byte list

  BatchFile({required this.id, required this.path, required this.size, required this.lastModified, this.source});

  Map<String, dynamic> toJson() => {
    'id': id,
    'path': path,
    'size': size,
    'lastModified': lastModified,
  };

  factory BatchFile.fromJson(Map<String, dynamic> json) {
    return BatchFile(
      id: json['id'],
      path: json['path'],
      size: json['size'],
      lastModified: json['lastModified'],
    );
  }
}

enum TransferState { idle, connecting, transferring, paused, completed, failed }

class TransferManager {
  final WebRTCService webrtc;
  final TcpTransportService? tcpTransport;
  String encryptionKey;
  String encryptionIv;

  TransferState _state = TransferState.idle;
  TransferState get state => _state;
  
  DateTime? startTime;
  DateTime? endTime;

  // Speed tracking — updated by UI screens via the progress stream.
  final ValueNotifier<double> speedBytesPerSec = ValueNotifier(0.0);

  set state(TransferState value) {
    if (_state != value) {
      if (value == TransferState.transferring && startTime == null) {
        startTime = DateTime.now();
      } else if (value == TransferState.completed) {
        endTime = DateTime.now();
      }
      _state = value;
    }
  }
  double progress = 0.0;
  
  // Batch State Variables
  String? batchId;
  String? manifestHash;
  int totalBatchBytes = 0;
  int _completedBatchBytes = 0;
  double get globalProgress => totalBatchBytes == 0 ? 0.0 : ((_completedBatchBytes + (_isSender ? _lastAckOffset : _receivedCount)) / totalBatchBytes);
  
  // Current File Variables (Legacy names preserved for compatibility)
  String? fileName;
  int? fileSize;
  String? lastSavedPath;
  String? sessionId;
  
  // The transfer queue
  final List<BatchFile> _transferQueue = [];
  final List<BatchFile> _originalBatchFiles = [];
  final Map<String, int> _indexMap = {};
  BatchFile? _currentBatchFile;
  String? _lastCompletedFileId;

  StreamController<double> progressController = StreamController<double>.broadcast();
  final ValueNotifier<String> route = ValueNotifier<String>('Analyzing Path...');
  int _lastAckOffset = 0; // For sender
  int _sendGeneration = 0; // Concurrency lock for overlapping resume_requests
  int _lastResumeRequestTime = 0;
  int _reconnectGeneration = 0;

  int currentFileIndex = 0;
  int totalFiles = 0;
  String currentFileName = '';

  TransferManager({
    required this.webrtc,
    this.tcpTransport,
    required this.encryptionKey,
    required this.encryptionIv,
    this.sessionId,
  }) {
    webrtc.onMessage = _handleIncomingMessage;
    webrtc.onRelayReady = _handleRelayReady;
    tcpTransport?.onData.listen((msg) {
      if (msg.isBinary) {
        _handleIncomingData(msg.data);
      } else {
        _handleIncomingText(msg.data, fromTcp: true);
      }
    });

    tcpTransport?.onStatus.listen((status) {
      if (status == 'connected') {
         route.value = 'Direct Gigabit P2P';
      } else if (status == 'disconnected' || status == 'failed') {
         if (state == TransferState.transferring) {
            state = TransferState.paused;
            debugPrint('[TRANSFER] TCP network drop detected. Pausing stream for resume...');
         }
      }
    });

    webrtc.onBufferedAmountLow = (amount) {
      if (_bufferCompleter != null && !_bufferCompleter!.isCompleted) {
        _bufferCompleter!.complete();
      }
    };
    
    // Top-level Network Drop Handlers
    webrtc.onDisconnected = () {
      _isFetchingRelay = false; // Release lock in case of hard drop mid-fetch
      if (state == TransferState.transferring) {
        state = TransferState.paused;
        debugPrint('[TRANSFER] Mid-air network drop detected. Pausing stream...');
      }
    };

    webrtc.onReconnected = () {
      debugPrint('[TRANSFER] Network restored! Signaling reconnected.');
      
      // CRITICAL: If signaling had to reconnect, the physical network dropped.
      // This means any existing TCP socket is a "ghost" half-open pipe.
      // We MUST aggressively kill it to prevent routing data into the void.
      if (tcpTransport != null && tcpTransport!.isConnected) {
        debugPrint('[TRANSFER] Aggressively purging dead TCP socket due to network change.');
        tcpTransport!.disconnect();
      }
      
      // Since the network dropped, local routing is broken. Lock to relay.
      _isLockedToRelay = true;
      _isLockedToTcp = false;
      
      // CRITICAL: Force-reset the relay fetch lock. If airplane mode was briefly toggled,
      // Mac's relay HTTP GET may still be mid-flight (15s timeout). _isFetchingRelay
      // would stay true, silently dropping all relay-ready events from Android's resumed
      // stream. Resetting here guarantees the next relay-ready starts a fresh fetch cycle.
      _isFetchingRelay = false;
      _resumeRequestTimer?.cancel();
      _reconnectGeneration++;
      final myGeneration = _reconnectGeneration;
      
      if (!_isSender) {
        // RECEIVER: Fire resume_request whenever a transfer was in progress.
        if (_receivedCount > 0 && state != TransferState.completed) {
          state = TransferState.transferring;
          final targetOffset = _receivedCount;
          
          _resumeRequestTimer?.cancel();
          _resumeRequestTimer = Timer.periodic(const Duration(seconds: 10), (timer) {
            if (myGeneration != _reconnectGeneration || state == TransferState.completed || _receivedCount > targetOffset) {
              timer.cancel();
              return;
            }
            debugPrint('[TRANSFER] Receiver sending strict resume vector at offset: $_receivedCount');
            final resumeMsg = json.encode({
              'type': 'resume_request',
              'batchId': batchId,
              'manifestHash': manifestHash,
              'fileId': _currentBatchFile?.id,
              'lastCompletedFileId': _lastCompletedFileId,
              'offset': _receivedCount
            });
            webrtc.sendSocketMessage(resumeMsg, sessionId ?? 'global');
          });
          
          // Fire immediately once
          debugPrint('[TRANSFER] Receiver sending strict resume vector at offset: $_receivedCount');
          final resumeMsg = json.encode({
            'type': 'resume_request',
            'batchId': batchId,
            'manifestHash': manifestHash,
            'fileId': _currentBatchFile?.id,
            'lastCompletedFileId': _lastCompletedFileId,
            'offset': _receivedCount
          });
          webrtc.sendSocketMessage(resumeMsg, sessionId ?? 'global');
        }
      } else {
        // SENDER: Pause and wait for receiver's resume_request.
        // The receiver will send one now that it has detected the reconnect.
        if (state == TransferState.transferring) {
          state = TransferState.paused;
          debugPrint('[TRANSFER] Sender paused — waiting for receiver resume vector...');
        }
      }
    };

    // WARM FALLBACK: if WebRTC fails mid-transfer, lock to relay on next chunk iteration.
    // sendFile() checks _isLockedToRelay every chunk — no restart needed.
    webrtc.onFallbackSwap = () {
      if (FEATURES.warmFallbacks) {
        debugPrint('[TRANSFER] Warm fallback activated: locking to relay transport.');
        _isLockedToRelay = true;
        _isLockedToTcp = false;
      }
    };

    // Link route tracking for receiver side
    webrtc.currentRoute.addListener(() {
      route.value = webrtc.currentRoute.value;
    });
  }

  void updateEncryption(String key, String iv) {
    encryptionKey = key;
    encryptionIv = iv;
    debugPrint('[TRANSFER] Keys updated via signaling: KeyLen=${encryptionKey.length}, IvLen=${encryptionIv.length}');
  }

  static const int chunkSize = 65536; // 64KB chunks to quadruple throughput over Pinggy bounds

  int _unackedChunks = 0;
  int _receiverChunksProcessed = 0;
  bool _isSender = false;
  bool _isLockedToTcp = false;
  bool _isLockedToRelay = false;
  bool streamAborted = false;
  int _consecutiveTimeouts = 0;

  // --- Sender Logic ---

  Completer<void>? _bufferCompleter;
  Completer<void>? _metadataAckCompleter;
  Completer<void>? _endAckCompleter;

  dynamic _currentFileSource;

  Future<void> sendFile(dynamic fileSource, {int? startOffset}) async {
    final file = fileSource as dynamic;
    final fName = kIsWeb ? "web_upload" : file.uri.pathSegments.last;
    final fSize = kIsWeb ? (fileSource as Uint8List).length : await file.length();
    
    // For legacy single-file compatibility, we wrap it in a BatchFile
    final bf = BatchFile(
      id: 'single-${DateTime.now().millisecondsSinceEpoch}',
      path: fName,
      size: fSize,
      lastModified: 0,
      source: fileSource,
    );
    
    await startBatchTransfer([bf], startFromIndex: 0, fileStartOffset: startOffset ?? 0);
  }

  Future<void> startBatchTransfer(List<BatchFile> files, {String? customBatchId, int startFromIndex = 0, int fileStartOffset = 0}) async {
    batchId = customBatchId ?? 'batch-${DateTime.now().millisecondsSinceEpoch}';
    
    // Reset route locks ONLY on fresh user-initiated transfers, not during mid-air resumptions
    if (fileStartOffset == 0 && startFromIndex == 0) {
      _isLockedToRelay = false;
      _isLockedToTcp = false;
    }
    
    _transferQueue.clear();
    _originalBatchFiles.clear();
    _originalBatchFiles.addAll(files);
    _indexMap.clear();
    totalBatchBytes = 0;
    _completedBatchBytes = 0;
    
    totalFiles = files.length;
    final hashData = StringBuffer();
    for (int i = 0; i < files.length; i++) {
      final f = files[i];
      _transferQueue.add(f);
      _indexMap[f.id] = i;
      totalBatchBytes += f.size;
      hashData.write('${f.id}|${f.path}|${f.size}|${f.lastModified};');
    }
    
    manifestHash = sha256.convert(utf8.encode(hashData.toString())).toString();
    
    // If starting fresh, send the manifest
    if (startFromIndex == 0 && fileStartOffset == 0) {
      final batchMeta = json.encode({
        'type': 'batch_manifest',
        'batchId': batchId,
        'manifestHash': manifestHash,
        'totalFiles': files.length,
        'totalBytes': totalBatchBytes,
        'completedBytes': _completedBatchBytes,
        'files': files.map((f) => f.toJson()).toList(),
      });
      
      if (!_isLockedToRelay && tcpTransport != null && tcpTransport!.isConnected) {
        tcpTransport!.sendText(batchMeta);
      } else {
        webrtc.sendSocketMessage(batchMeta, sessionId ?? 'global');
      }
      
      // Wait for receiver to ack manifest
      _metadataAckCompleter = Completer<void>();
      await _metadataAckCompleter!.future.timeout(
        const Duration(seconds: 15),
        onTimeout: () { debugPrint('[SENDER] Batch metadata ACK timeout!'); }
      );
    }
    
    int myGeneration = _sendGeneration;
    
    // Fast forward to resume point
    for (int i = 0; i < startFromIndex; i++) {
      if (_transferQueue.isNotEmpty) {
        _completedBatchBytes += _transferQueue.removeAt(0).size;
      }
    }
    
    while (_transferQueue.isNotEmpty) {
      if (myGeneration != _sendGeneration) {
        debugPrint('[BATCH] Aborting loop because generation changed ($myGeneration != $_sendGeneration)');
        return;
      }
      _currentBatchFile = _transferQueue.removeAt(0);
      currentFileIndex = totalFiles - _transferQueue.length;
      currentFileName = _currentBatchFile!.path.split('/').last;
      fileName = _currentBatchFile!.path; // Legacy compat
      fileSize = _currentBatchFile!.size; // Legacy compat
      
      await _processCurrentFileInQueue(_currentBatchFile!, startOffset: fileStartOffset);
      
      if (!streamAborted && myGeneration == _sendGeneration) {
        _completedBatchBytes += _currentBatchFile!.size;
        fileStartOffset = 0; // Next file starts at 0
      } else {
        debugPrint('[BATCH] Stream aborted mid-batch at file: ${fileName}');
        break;
      }
    }
    
    if (_transferQueue.isEmpty && !streamAborted && myGeneration == _sendGeneration) {
      state = TransferState.completed;
      debugPrint('[BATCH] Fully completed. Sending end_batch verification.');
      
      final endBatchMsg = json.encode({
        'type': 'end_batch',
        'totalFiles': _originalBatchFiles.length,
      });
      if (!_isLockedToRelay && tcpTransport != null && tcpTransport!.isConnected) {
        tcpTransport!.sendText(endBatchMsg);
      } else {
        webrtc.sendSocketMessage(endBatchMsg, sessionId ?? 'global');
      }
    }
  }

  Future<void> _processCurrentFileInQueue(BatchFile batchFile, {int? startOffset}) async {
    final int currentGeneration = _sendGeneration;
    
    _isSender = true;
    _currentFileSource = batchFile.source;
    int actualStart = startOffset ?? 0;
    _lastAckOffset = actualStart;
    
    state = TransferState.transferring;
    if (batchId != null && totalBatchBytes > 0) {
      progress = globalProgress;
    } else {
      progress = actualStart / fileSize!;
    }
    progressController.add(progress);

    webrtc.onBufferedAmountLow = (amount) {
      if (_bufferCompleter != null && !_bufferCompleter!.isCompleted) {
        _bufferCompleter!.complete();
      }
    };

    // TRANSPORT SELECTION: Try WebRTC first, fallback to Socket if channel is closed
    // We do this BEFORE sending metadata so we know which pipe to use
    bool useFallback = false;
    bool raceSuccessful = false;

    if (!_isLockedToRelay && tcpTransport != null && tcpTransport!.isConnected) {
      debugPrint('[TRANSFER] TCP is connected. Skipping Smart Transport Race.');
      route.value = 'Direct Gigabit P2P';
      raceSuccessful = true;
    } else if (_isLockedToRelay) {
      debugPrint('[TRANSFER] Stream is locked to Relay. Skipping Smart Transport Race.');
      useFallback = true;
      raceSuccessful = true;
      route.value = 'Relay';
    } else if (FEATURES.smartTransportRace) {
      try {
        debugPrint('[TRANSFER] Smart Transport Race enabled. Racing participants...');
        useFallback = await TransportHelper.race(webrtc, sessionId);
        raceSuccessful = true;
        route.value = useFallback ? 'Relay' : 'Encrypted P2P';
      } catch (e) {
        debugPrint('[TRANSFER] Smart Race wrapper failed: $e. Continuing with default flow.');
        // Continue to existing connection logic below
      }
    }

    // ORIGINAL CONNECTION FLOW (Default)
    if (!raceSuccessful) {
      try {
        debugPrint('[TRANSFER] Waiting for WebRTC DataChannel (1s timeout)...');
        await webrtc.onDataChannelOpen.timeout(const Duration(seconds: 1));
        debugPrint('[TRANSFER] Using HIGH-SPEED WebRTC Transport');
        useFallback = false;
        route.value = 'Encrypted P2P';
      } catch (e) {
        debugPrint('[TRANSFER] WebRTC Timeout. Using RELIABLE Socket-Pipe Fallback');
        useFallback = true;
        route.value = 'Relay';
      }
    }

    // Send metadata across BOTH pipes if available, to be safe
    final metadata = {
      'type': 'metadata',
      'fileName': fileName,
      'fileSize': fileSize,
      'key': encryptionKey,
      'iv': encryptionIv,
      'platform': PlatformUtils.operatingSystem,
      'batchId': batchId,
      'manifestHash': manifestHash,
      'fileId': batchFile.id,
      'batchTotalBytes': totalBatchBytes,
      'batchCompletedBytes': _completedBatchBytes,
    };
    
    final metadataJson = jsonEncode(metadata);

    if (useFallback || _isLockedToRelay) {
      debugPrint('[TRANSFER] Routing metadata over Signaling (Relay fallback active)');
      webrtc.sendSocketMessage(metadataJson, sessionId ?? 'global');
    } else if (!_isLockedToRelay && tcpTransport != null && tcpTransport!.isConnected) {
      debugPrint('[TRANSFER] Sending metadata over Local TCP Socket');
      tcpTransport!.sendText(metadataJson);
    } else {
      webrtc.sendMessage(metadataJson);
    }

    _metadataAckCompleter = Completer<void>();
    try {
      await _metadataAckCompleter!.future.timeout(const Duration(seconds: 15));
    } catch (e) {
      if (_sendGeneration == currentGeneration) {
        debugPrint('[TRANSFER] Receiver did not acknowledge metadata. Aborting stream.');
        state = TransferState.failed;
      } else {
        debugPrint('[TRANSFER] Orphaned handshake timeout ignored. Generation $_sendGeneration > $currentGeneration.');
      }
      return;
    }

    // Do not unconditionally reset _isLockedToRelay because if we forced it 
    // to fallback to relay due to a dead TCP socket, we want it to stay locked.
    _isLockedToTcp = false;

    // --- SENDER STABILIZATION ---
    while (state == TransferState.transferring || state == TransferState.paused) {
      if (_sendGeneration != currentGeneration) {
        debugPrint('[TRANSFER] Stream aborted: Superseded by new resume generation $_sendGeneration.');
        return;
      }
      
      if (state == TransferState.paused) {
        await Future.delayed(const Duration(seconds: 1));
        continue;
      }

      int actualStart = _lastAckOffset;
      int sent = actualStart;
      bool streamAborted = false;

      // BACKPRESSURE MONITORING: Dynamically adjust buffer to prevent 3G/4G buffer bloat
      int bufferThreshold = 2 * 1024 * 1024; // 2MB default for Wi-Fi/Gigabit
      if (webrtc.currentResultsString.toLowerCase().contains('mobile')) {
        bufferThreshold = 512 * 1024; // 512KB strict buffer for 3G/4G to ensure smooth pacing
        debugPrint('[TRANSFER] Mobile Network Detected (3G/4G). Applying strict 512KB backpressure threshold.');
      }

      // ── ADAPTIVE CHUNK SIZE + ENCRYPT-AHEAD BUFFER ───────────────────────────
      // Both features are gated by flags and fail silently — any error falls
      // through to the original unbounded-stream path below.
      //
      // WHAT CHANGES:  how the file is READ (chunk size + prefetch).
      // WHAT DOES NOT: send calls, ACK logic, backpressure, encryption algorithm.
      bool _optimizedPathActive = false;

      if (!kIsWeb && (FEATURES.adaptiveChunkSize || FEATURES.parallelChunks)) {
        try {
          // Adaptive chunk size controller
          int _chunkSize     = 512  * 1024;  // start at 512KB
          const int _minChunk =  512 * 1024;  // floor
          const int _maxChunk = 2048 * 1024;  // ceiling 2MB
          int _stableRounds  = 0;             // consecutive fast ACKs

          // Encrypt-ahead queue: each entry = {bytes, encryptedBytes, offset}
          // Max 2 prepared chunks ahead. Send order is always queue[0] → dequeue → send.
          final List<({Uint8List raw, Uint8List encrypted, int offset})> _prefetchQueue = [];

          // Helper: read exactly one chunk from file starting at [readPos].
          // Returns null when EOF is reached.
          Future<Uint8List?> _readChunk(int readPos) async {
            if (readPos >= fileSize!) return null;
            final end = (readPos + _chunkSize).clamp(0, fileSize!);
            final bytes = <int>[];
            
            final bool isAndroidNative = (!kIsWeb && PlatformUtils.isMobile && PlatformUtils.operatingSystem == 'android');
            final String sourcePath = isAndroidNative ? ((_currentFileSource as dynamic).path as String) : '';
            final bool isContentUri = sourcePath.startsWith('content://');
            
            if (isAndroidNative && isContentUri) {
               final Uint8List rawBytes = await (_currentFileSource as dynamic).readAsBytes();
               final slice = rawBytes.sublist(readPos, end);
               bytes.addAll(slice);
            } else {
               final stream = isAndroidNative
                   ? PlatformUtils.getFileStream(sourcePath, readPos, end)
                   : (_currentFileSource as dynamic).openRead(readPos, end);
               await for (final part in stream) {
                 bytes.addAll(part as List<int>);
               }
            }
            if (bytes.isEmpty) return null;
            return Uint8List.fromList(bytes);
          }

          // Helper: prepare (read+encrypt) one chunk at logical position [readPos].
          Future<void> _prefetch(int readPos) async {
            if (readPos >= fileSize!) return;
            // Skip if already in queue at this offset
            if (_prefetchQueue.any((e) => e.offset == readPos)) return;
            final raw = await _readChunk(readPos);
            if (raw == null) return;
            // Encryption offset = logical byte position in file (not timing-dependent)
            final encrypted = EncryptionService.encryptChunk(raw, encryptionKey, encryptionIv, readPos);
            _prefetchQueue.add((raw: raw, encrypted: encrypted, offset: readPos));
          }

          _optimizedPathActive = true;

          // Seed the queue with the first chunk before the loop starts
          int _readHead = actualStart; // next position to read into the queue
          await _prefetch(_readHead);
          if (_prefetchQueue.isNotEmpty) _readHead += _prefetchQueue.last.raw.length;

          while (_prefetchQueue.isNotEmpty || _readHead < fileSize!) {
            // ── State / generation checks (identical to original) ──────────────
            if (_sendGeneration != currentGeneration) {
              debugPrint('[TRANSFER] Stream cancelled mid-chunk for new resume generation.');
              return;
            }
            if (state == TransferState.failed) { streamAborted = true; break; }
            if (state == TransferState.paused) {
              debugPrint('[TRANSFER] Stream externally paused! Aborting native reader...');
              streamAborted = true;
              break;
            }

            // Ensure queue has at least 1 ready chunk
            if (_prefetchQueue.isEmpty) {
              await _prefetch(_readHead);
              if (_prefetchQueue.isNotEmpty) _readHead += _prefetchQueue.last.raw.length;
              if (_prefetchQueue.isEmpty) break; // EOF
            }

            // Pop the front chunk (strictly sequential: always chunk N before N+1)
            final prepared = _prefetchQueue.removeAt(0);

            // Sanity check: offset must match current send position
            if (prepared.offset != sent) {
              debugPrint('[TRANSFER] Encrypt-ahead offset mismatch! Expected $sent got ${prepared.offset}. Disabling optimization.');
              throw StateError('offset_mismatch');
            }

            final encryptedChunk = prepared.encrypted;
            final chunk          = prepared.raw;

            // ── SEND PATHS — byte-for-byte identical to original ──────────────
            if (!_isLockedToRelay && tcpTransport != null && tcpTransport!.isConnected) {
              _isLockedToTcp = true;
              if (route.value != 'TCP/Local') route.value = 'TCP/Local';
              await tcpTransport!.sendBinary(encryptedChunk);
            } else if (useFallback || _isLockedToRelay) {
              _isLockedToRelay = true;
              if (route.value != 'Relay') route.value = 'Relay';

              while (_unackedChunks * chunkSize > bufferThreshold) {
                debugPrint('[TRANSFER] Relay Backpressure: Waiting for receiver acks...');
                _bufferCompleter = Completer<void>();
                try {
                  await _bufferCompleter!.future.timeout(const Duration(seconds: 15));
                } catch (e) {
                  debugPrint('[TRANSFER] Relay Buffer timeout. Network stall detected! Aborting stream to await resume.');
                  state = TransferState.paused;
                  streamAborted = true;
                  break;
                }
              }

              if (streamAborted) break;

              // STRICT SEQUENTIAL HTTP RELAY: Guarantee byte-order by awaiting each POST request natively
              await webrtc.sendSocketData(encryptedChunk, sessionId ?? 'global', sent);
              _unackedChunks++;
            } else {
              if (route.value != 'WebRTC') route.value = 'WebRTC';
              while (webrtc.bufferedAmount > bufferThreshold) {
                debugPrint('[TRANSFER] Backpressure: Waiting for buffer to clear (${webrtc.bufferedAmount} bytes)...');
                _bufferCompleter = Completer<void>();
                await _bufferCompleter!.future.timeout(const Duration(seconds: 5), onTimeout: () {
                  debugPrint('[TRANSFER] Buffer timeout. Continuing despite congestion.');
                  _consecutiveTimeouts++;
                });
                if (_consecutiveTimeouts > 3) {
                  debugPrint('[TRANSFER] Receiver unresponsive. Pausing optimized stream to await reconnect.');
                  state = TransferState.paused;
                  streamAborted = true;
                  break;
                }
              }
              if (streamAborted) break;
              if (state != TransferState.paused) {
                _consecutiveTimeouts = 0; // Successfully cleared buffer, reset timeout tracker
              }
              webrtc.sendBinary(encryptedChunk);
            }
            // ── END SEND PATHS ────────────────────────────────────────────────

            sent += chunk.length;
            _lastAckOffset = sent;
            TelemetryService().markFirstByte();
            TelemetryService().trackProgress(chunk.length);
            if (batchId != null && totalBatchBytes > 0) {
              progress = globalProgress;
            } else {
              progress = sent / fileSize!;
            }
            progressController.add(progress);

            // ── ADAPTIVE CHUNK SIZE: grow on stable rounds, shrink not needed ─
            if (FEATURES.adaptiveChunkSize) {
              _stableRounds++;
              if (_stableRounds >= 4 && _chunkSize < _maxChunk) {
                _chunkSize = (_chunkSize * 2).clamp(_minChunk, _maxChunk);
                _stableRounds = 0;
                debugPrint('[CHUNK] Grew chunk size to ${_chunkSize ~/ 1024}KB');
              }
            }

            // ── ENCRYPT-AHEAD: prefetch next chunk(s) during this send's await ─
            if (FEATURES.parallelChunks && _readHead < fileSize!) {
              // Prefetch up to 2 chunks ahead (non-blocking — runs concurrently with next loop)
              unawaited(_prefetch(_readHead).then((_) {
                if (_prefetchQueue.isNotEmpty) {
                  _readHead += _prefetchQueue.last.raw.length;
                }
              }).catchError((e) {
                debugPrint('[CHUNK] Prefetch error (ignored): $e');
              }));
            }
          } // end optimized while loop

        } catch (e) {
          // Any error in the optimized path: disable features and fall through
          // to the original stream below. Transfer continues uninterrupted.
          debugPrint('[CHUNK] Optimized path error ($e). Falling back to original stream.');
          _optimizedPathActive = false;
          sent = _lastAckOffset; // reset to last confirmed sent position
        }
      }

      // ── ORIGINAL STREAM PATH (fallback or non-web always) ────────────────────
      // Runs when: features are off, kIsWeb, or optimized path threw an error.
      if (!_optimizedPathActive) {
        final bool isAndroidNative = (!kIsWeb && PlatformUtils.isMobile && PlatformUtils.operatingSystem == 'android');
        final String sourcePath = isAndroidNative ? ((_currentFileSource as dynamic).path as String) : '';
        final bool isContentUri = sourcePath.startsWith('content://');
        
        dynamic stream;
        if (kIsWeb) {
           stream = Stream.fromIterable([(_currentFileSource as Uint8List).sublist(sent)]);
        } else if (isAndroidNative && isContentUri) {
           debugPrint('[TRANSFER] Content URI detected on Android. Using memory-mapped fallback...');
           final Uint8List rawBytes = await (_currentFileSource as dynamic).readAsBytes();
           stream = Stream.fromIterable([rawBytes.sublist(sent)]);
        } else if (isAndroidNative) {
           stream = PlatformUtils.getFileStream(sourcePath, sent);
        } else {
           stream = (_currentFileSource as dynamic).openRead(sent);
        }

        // ── SMART SWITCHING: Tracking Variables ───────────────────────────
        int _lastMonitorSent = sent;
        DateTime _lastMonitorTime = DateTime.now();
        DateTime _transferStartTime = DateTime.now();
        int _consecutiveSlowRounds = 0;
        int _monitorRetries = 0;
        bool _hasSwitched = false;

        await for (final chunk in stream) {
          if (_sendGeneration != currentGeneration) {
            debugPrint('[TRANSFER] Stream cancelled mid-chunk for new resume generation.');
            return;
          }
          if (state == TransferState.failed) { streamAborted = true; break; }
          if (state == TransferState.paused) {
            debugPrint('[TRANSFER] Stream externally paused! Aborting native reader...');
            streamAborted = true;
            break;
          }

          final encryptedChunk = EncryptionService.encryptChunk(chunk as Uint8List, encryptionKey, encryptionIv, sent);

          int chunkRetries = 0;
          bool chunkSuccess = false;

          while (!chunkSuccess && chunkRetries < 3) {
            try {
              if (!_isLockedToRelay && tcpTransport != null && tcpTransport!.isConnected) {
                _isLockedToTcp = true;
                if (route.value != 'TCP/Local') route.value = 'TCP/Local';
                await tcpTransport!.sendBinary(encryptedChunk);
              } else if (useFallback || _isLockedToRelay) {
                _isLockedToRelay = true;
                if (route.value != 'Relay') route.value = 'Relay';

                while (_unackedChunks * chunkSize > bufferThreshold) {
                  debugPrint('[TRANSFER] Relay Backpressure: Waiting for receiver acks...');
                  _bufferCompleter = Completer<void>();
                  try {
                    await _bufferCompleter!.future.timeout(const Duration(seconds: 15));
                  } catch (e) {
                    debugPrint('[TRANSFER] Relay Buffer timeout. Network stall detected! Aborting stream to await resume.');
                    state = TransferState.paused;
                    streamAborted = true;
                    break;
                  }
                }

                if (streamAborted) break;

                // STRICT SEQUENTIAL HTTP RELAY: Guarantee byte-order by awaiting each POST request natively
                await webrtc.sendSocketData(encryptedChunk, sessionId ?? 'global', sent);
                if (chunkRetries == 0) _unackedChunks++; // Only increment once per chunk
              } else {
                if (route.value != 'WebRTC') route.value = 'WebRTC';
                while (webrtc.bufferedAmount > bufferThreshold) {
                  debugPrint('[TRANSFER] Backpressure: Waiting for buffer to clear (${webrtc.bufferedAmount} bytes)...');
                  _bufferCompleter = Completer<void>();
                  await _bufferCompleter!.future.timeout(const Duration(seconds: 5), onTimeout: () {
                    debugPrint('[TRANSFER] Buffer timeout. Continuing despite congestion.');
                    _monitorRetries++; // Track retry/timeout
                    _consecutiveTimeouts++;
                  });
                  if (_consecutiveTimeouts > 3) {
                    debugPrint('[TRANSFER] Receiver unresponsive. Pausing WebRTC stream to await reconnect.');
                    state = TransferState.paused;
                    streamAborted = true;
                    break;
                  }
                }
                if (streamAborted) break;
                if (state != TransferState.paused) {
                  _consecutiveTimeouts = 0; // Successfully cleared buffer

                }
                webrtc.sendBinary(encryptedChunk);
              }
              chunkSuccess = true;
            } catch (e) {
              chunkRetries++;
              debugPrint('[RETRY] Chunk send failed at offset $sent. Retry $chunkRetries/3. Error: $e');
              if (!FEATURES.preciseRetries || chunkRetries >= 3) {
                rethrow;
              }
              await Future.delayed(Duration(milliseconds: 500));
            }
          }

          sent += (chunk as Uint8List).length;
          _lastAckOffset = sent;
          TelemetryService().markFirstByte();
          TelemetryService().trackProgress(chunk.length);
          if (batchId != null && totalBatchBytes > 0) {
            progress = globalProgress;
          } else {
            progress = sent / fileSize!;
          }
          progressController.add(progress);

          // ── SMART SWITCHING: Periodic Evaluation ─────────────────────────
          if (FEATURES.smartSwitching && !_hasSwitched && !_isLockedToRelay && (tcpTransport == null || !tcpTransport!.isConnected)) {
            try {
              final now = DateTime.now();
              final timeDelta = now.difference(_lastMonitorTime).inMilliseconds;
              
              if (timeDelta >= 3000) { // Evaluate every ~3 seconds
                final bytesSentDelta = sent - _lastMonitorSent;
                final double throughputKbps = (bytesSentDelta / 1024) / (timeDelta / 1000);
                
                debugPrint('[MONITOR] Throughput: ${throughputKbps.toStringAsFixed(1)} KB/s | Retries: $_monitorRetries');

                // Threshold: < 100 KB/s OR multiple timeouts
                if (throughputKbps < 100 || _monitorRetries > 0) {
                  _consecutiveSlowRounds++;
                } else {
                  _consecutiveSlowRounds = 0;
                }

                // Switch Condition: 2 consecutive slow rounds (~6 seconds of degradation)
                // Transfer must be running for at least 5 seconds to avoid premature switching
                final totalElapsed = now.difference(_transferStartTime).inSeconds;
                if (_consecutiveSlowRounds >= 2 && totalElapsed >= 5) {
                  debugPrint('[MONITOR] Switching to relay due to sustained degradation');
                  _isLockedToRelay = true;
                  useFallback = true;
                  _hasSwitched = true;
                }

                // Reset trackers
                _monitorRetries = 0;
                _lastMonitorSent = sent;
                _lastMonitorTime = now;
              }
            } catch (e) {
              // Fail silently: Catch any monitoring errors so transfer continues perfectly
              debugPrint('[MONITOR] Error during quality evaluation (ignored): $e');
            }
          }
        }
      }
      // ── END ORIGINAL STREAM PATH ──────────────────────────────────────────────
      
      // Prevent infinite watchdog loops on inaccessible/dataless files (e.g. iCloud)
      if (!streamAborted && state == TransferState.transferring && sent < fileSize!) {
        debugPrint('[ERROR] Premature EOF! Sent $sent bytes but expected $fileSize. File is inaccessible or an iCloud placeholder.');
        state = TransferState.failed;
        streamAborted = true;
        progressController.add(0.0);
        
        final errorMsg = json.encode({'type': 'error', 'message': 'File $fileName is inaccessible on the sender device (likely an iCloud placeholder).'});
        if (tcpTransport != null && tcpTransport!.isConnected) {
          tcpTransport!.sendText(errorMsg);
        } else {
          webrtc.sendAdaptiveMessage(errorMsg, sessionId ?? 'global');
        }
      }

      if (!streamAborted && state == TransferState.transferring) {
        if (batchId == null) {
          state = TransferState.completed;
          TelemetryService().finish(true);
        }
        final jsonEnd = json.encode({'type': 'end'});
        if (tcpTransport != null && tcpTransport!.isConnected) {
          tcpTransport!.sendText(jsonEnd);
        } else {
          webrtc.sendAdaptiveMessage(jsonEnd, sessionId ?? 'global');
        }
        
        // IMPORTANT: Wait for receiver to completely finish writing the file to disk!
        // This prevents the Mac from racing ahead and sending metadata for File N+1
        // before Android has fully processed chunks for File N.
        _endAckCompleter = Completer<void>();
        try {
           await _endAckCompleter!.future.timeout(const Duration(seconds: 45));
           debugPrint('[TRANSFER] Receiver acknowledged file finalization.');
           break; // Entire file finished flawlessly!
        } catch (e) {
           debugPrint('[TRANSFER] Timeout waiting for end_ack. Network stall! Aborting stream.');
           streamAborted = true;
           state = TransferState.paused;
           break;
        }
      }
    }
  }

  // --- Receiver Logic ---

  late final FileHandler _fileHandler = FileHandler();
  int _receivedCount = 0;
  bool _isInitializingSink = false;
  List<Uint8List> _chunkBuffer = [];
  bool _endReceived = false;
  
  bool _isFetchingRelay = false;
  bool _pendingRelayReady = false; // Set when relay-ready arrives while loop is running
  Timer? _receiverWatchdog;
  Timer? _resumeRequestTimer;
  int _lastChunkReceivedAt = 0; // milliseconds since epoch, updated on every chunk received

  void _resetReceiverWatchdog() {
    _receiverWatchdog?.cancel();
    if (_isSender) return; 
    if (state != TransferState.transferring) return;
    
    _receiverWatchdog = Timer(const Duration(seconds: 15), () {
      debugPrint('[TRANSFER] Watchdog timeout! No chunks received for 15s. Triggering explicit resume request...');
      
      // CRITICAL: If watchdog timed out, the active stream is completely dead.
      // If we have an active TCP connection, it's a ghost half-open pipe.
      // We must aggressively kill it so our resume request goes over the safe Relay channel!
      if (tcpTransport != null && tcpTransport!.isConnected) {
        debugPrint('[TRANSFER] Watchdog killing dead TCP socket.');
        tcpTransport!.disconnect();
      }
      
      _isLockedToRelay = true;
      _isLockedToTcp = false;
      
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastResumeRequestTime < 3000) return;
      _lastResumeRequestTime = now;
      
      final resumeMsg = json.encode({
        'type': 'resume_request',
        'batchId': batchId,
        'manifestHash': manifestHash,
        'fileId': _currentBatchFile?.id,
        'lastCompletedFileId': _lastCompletedFileId,
        'offset': _receivedCount,
      });
      if (tcpTransport != null && tcpTransport!.isConnected) {
        tcpTransport!.sendText(resumeMsg);
      } else {
        webrtc.sendSocketMessage(resumeMsg, sessionId ?? 'global');
      }
    });
  }

  void _handleRelayReady() async {
    if (_isSender) return; // Prevent the Sender from stealing its own chunks from the cloud
    if (_isFetchingRelay) {
      _pendingRelayReady = true; // Remember to re-poll once the current loop finishes
      return;
    }
    _isFetchingRelay = true;
    int _consecutiveErrors = 0;
    // Capture the active file at loop-start. If fileName changes mid-loop it means a new
    // file's metadata has arrived and its chunk is now sitting in the relay queue.
    // We must NOT consume that chunk here — break and let the new file's proactive poll
    // or relay-ready handler fetch it with the correct sink open.
    final String? _loopFileName = fileName;
    try {
      if (sessionId == null) return;
      final url = Uri.parse('${AppConfig.signalingUrl}/relay/$sessionId');
      
      while (true) {
        // Guard: if a new file has started (different fileName), stop immediately
        // to avoid consuming chunks that belong to the next file's stream.
        if (fileName != _loopFileName && !_isInitializingSink) break;
        try {
          // Short timeout: if network is dead, fail fast so _isFetchingRelay resets quickly
          // and can restart cleanly once Android reconnects and sends new chunks.
          final response = await http.get(url).timeout(const Duration(seconds: 4));
          _consecutiveErrors = 0; // Reset on success
          if (response.statusCode == 200) {
            if (route.value == 'Analyzing Path...') {
              route.value = 'WebRTC / Relay';
            }
            if (_isInitializingSink) {
              _chunkBuffer.add(response.bodyBytes);
            } else {
              await _processChunk(response.bodyBytes);
            }
          } else {
            break; // Node server queue is empty
          }
        } catch (e) {
          _consecutiveErrors++;
          debugPrint('[TRANSFER] HTTP GET Relay Error ($_consecutiveErrors): $e');
          if (_consecutiveErrors >= 3) {
            // Network is dead. Break so _isFetchingRelay resets and the next relay-ready
            // event (after Android reconnects) can start a fresh fetch cycle.
            debugPrint('[TRANSFER] Relay: 3 consecutive errors. Releasing lock to allow resume.');
            break;
          }
          await Future.delayed(const Duration(milliseconds: 1000));
        }
      }
    } finally {
      _isFetchingRelay = false;
    }
    // If a relay-ready arrived while we were fetching, drain immediately
    if (_pendingRelayReady) {
      _pendingRelayReady = false;
      _handleRelayReady();
    }
  }

  void _handleIncomingMessage(RTCDataChannelMessage message) async {
    if (!message.isBinary) {
      _handleIncomingText(message.text);
    } else {
      // Update Receiver UI to show active transport
      if (route.value == 'Analyzing Path...') {
        route.value = message.isBinary ? 'WebRTC / Relay' : 'Signaling';
      }

      if (_isInitializingSink) {
        _chunkBuffer.add(message.binary);
        return;
      }
      _processChunk(message.binary);
    }
  }

  void _handleIncomingData(Uint8List binaryData) {
      if (route.value == 'Analyzing Path...') route.value = 'TCP / Local';
      if (_isInitializingSink) {
        _chunkBuffer.add(binaryData);
        return;
      }
      _processChunk(binaryData);
  }

  void _handleIncomingText(String text, {bool fromTcp = false}) async {
    try {
      final data = json.decode(text);
        if (data['type'] == 'batch_manifest') {
          batchId = data['batchId'];
          manifestHash = data['manifestHash'];
          totalBatchBytes = data['totalBytes'];
          _completedBatchBytes = 0;
          
          if (data['files'] != null) {
            _indexMap.clear();
            _transferQueue.clear();
            List filesList = data['files'];
            for (int i = 0; i < filesList.length; i++) {
              final bf = BatchFile.fromJson(filesList[i]);
              _transferQueue.add(bf);
              _indexMap[bf.id] = i;
            }
          }
          
          debugPrint('[TRANSFER] Received Batch Manifest. Hash: $manifestHash, Total Bytes: $totalBatchBytes');
          final ackMsg = json.encode({'type': 'batch_manifest_ack'});
          if (tcpTransport != null && tcpTransport!.isConnected) {
            tcpTransport!.sendText(ackMsg);
          } else {
            webrtc.sendAdaptiveMessage(ackMsg, sessionId ?? 'global');
          }
          return;
        } else if (data['type'] == 'batch_manifest_ack') {
          if (_metadataAckCompleter != null && !_metadataAckCompleter!.isCompleted) {
             _metadataAckCompleter!.complete();
          }
          return;
        } else if (data['type'] == 'metadata') {
          if (_receivedCount > 0 && fileName == data['fileName']) {
             debugPrint('[TRANSFER] Ignoring duplicate metadata packet. Stream is already heavily active at offset $_receivedCount.');
             
             // IMPORTANT: We must still update the encryption IV/Key because if this is a mid-air resumption,
             // the sender generates a NEW IV for the stream. If we don't update it, decryption fails infinitely!
             if (data['key'] != null) encryptionKey = data['key'];
             if (data['iv'] != null) encryptionIv = data['iv'];
             if (data['batchId'] != null) batchId = data['batchId'];
             if (data['manifestHash'] != null) manifestHash = data['manifestHash'];
             if (data['fileId'] != null) {
               _currentBatchFile = BatchFile(id: data['fileId'], path: fileName ?? '', size: fileSize ?? 0, lastModified: 0);
             }
             
             // Send 'ready' with our current offset — Android's _metadataAckCompleter
             // is completed by 'ready', NOT 'metadata_ack'. The offset also tells Android
             // exactly where Mac is so it seeks the file to the right position.
             final ackMsg = json.encode({
               'type': 'ready',
               'offset': _receivedCount,
               'platform': 'macos',
             });
             // Respect relay lock: Android killed its TCP in the resume_request handler.
             if (!_isLockedToRelay && tcpTransport != null && tcpTransport!.isConnected) {
               tcpTransport!.sendText(ackMsg);
             } else {
               webrtc.sendSocketMessage(ackMsg, sessionId ?? 'global');
             }
             return; // Prevent breaking the active file lock
          }
          fileName = data['fileName'];
          fileSize = data['fileSize'];
          if (data['key'] != null) encryptionKey = data['key'];
          if (data['iv'] != null) encryptionIv = data['iv'];
          
          if (data['batchTotalBytes'] != null) {
            totalBatchBytes = data['batchTotalBytes'];
          }
          if (data['batchCompletedBytes'] != null) {
            _completedBatchBytes = data['batchCompletedBytes'];
          }

          if (data['batchId'] != null) batchId = data['batchId'];
          if (data['manifestHash'] != null) manifestHash = data['manifestHash'];
          if (data['fileId'] != null) {
            _currentBatchFile = BatchFile(id: data['fileId'], path: fileName ?? '', size: fileSize ?? 0, lastModified: 0);
          }
          String senderPlatform = data['platform'] ?? 'Unknown';
          TelemetryService().updatePlatforms(sender: senderPlatform, receiver: PlatformUtils.operatingSystem);
          state = TransferState.transferring;
          _endReceived = false;
          _chunkBuffer.clear();
          _receivedCount = 0; // IMPORTANT: Reset byte counter for new file!
          
            _isInitializingSink = true;
            try {
              debugPrint('[TRANSFER] Metadata received: $fileName ($fileSize bytes)');
              debugPrint('[TRANSFER] Syncing keys: KeyLen=${encryptionKey.length}, IvLen=${encryptionIv.length}');
              
              _receivedCount = await _fileHandler.open(fileName!, fileSize ?? 0);
              progress = _receivedCount / (fileSize == null || fileSize == 0 ? 1 : fileSize!);
              progressController.add(progress);
              
              // Note: Remote resumption is now active. The sender will receive this offset 
              // and seek their stream to the correct byte.
            } catch (e) {
              debugPrint('[TRANSFER] Error opening file handler: $e');
              state = TransferState.failed;
            } finally {
              _isInitializingSink = false;
            }
          
          // Process any chunks that arrived while awaiting directory
          for (var i = 0; i < _chunkBuffer.length; i++) {
            await _processChunk(_chunkBuffer[i]);
            // Yield to the event loop every 10 chunks to allow the UI progress circle to render
            if (i % 10 == 0) await Future.delayed(Duration.zero);
          }
          _chunkBuffer.clear();

          final ackMsg = json.encode({
            'type': 'ready',
            'offset': _receivedCount,
            'platform': PlatformUtils.operatingSystem,
          });

          if (tcpTransport != null && tcpTransport!.isConnected) {
            tcpTransport!.sendText(ackMsg);
          } else {
            webrtc.sendAdaptiveMessage(ackMsg, sessionId ?? 'global');
          }
          
          _resetReceiverWatchdog();

          // Proactively poll the relay in case relay-ready arrived while sink was initializing
          // or was missed entirely due to timing. The relay-ready event is unreliable for
          // tiny files where the single chunk may land in the queue at any moment.
          if (!_isSender) {
            Future.delayed(const Duration(milliseconds: 300), _handleRelayReady);
          }

          // If the transfer finished while initializing AND all bytes were received.
          // IMPORTANT: For relay transfers, end_file arrives via fast signaling BEFORE the
          // relay chunk is fetched via HTTP GET. If we finalize here with _receivedCount=0,
          // the file is corrupted (0 bytes) and the relay chunk arrives to a null sink.
          // Only finalize now if we actually have all the data; otherwise _processChunk
          // will call _finalizeTransfer once the relay chunk is fetched and written.
          if (_endReceived && _receivedCount >= (fileSize ?? 1)) {
            await _finalizeTransfer();
          }

        } else if (data['type'] == 'ready') {
          if (data['offset'] != null) {
            _lastAckOffset = data['offset'];
            debugPrint('[TRANSFER] Peer notified resumption offset: $_lastAckOffset');
          }
          String receiverPlatform = data['platform'] ?? 'Unknown';
          TelemetryService().updatePlatforms(sender: PlatformUtils.operatingSystem, receiver: receiverPlatform);
          if (_metadataAckCompleter != null && !_metadataAckCompleter!.isCompleted) {
            _metadataAckCompleter!.complete();
          }
        } else if (data['type'] == 'resume_request') {
          // Accept from any active state, EVEN completed, because the receiver might have dropped chunks
          if (_isSender && state != TransferState.idle) {
            final now = DateTime.now().millisecondsSinceEpoch;
            if (now - _lastResumeRequestTime < 12000) {
              debugPrint('[TRANSFER] Ignoring duplicate resume_request (debounced 12s).');
              return;
            }
            _lastResumeRequestTime = now;
            
            final reqBatchId = data['batchId'];
            final reqHash = data['manifestHash'];
            String? reqFileId = data['fileId'];
            final reqLastCompletedFileId = data['lastCompletedFileId'];
            final resumeOffset = data['offset'] as int;

            // If receiver lost state (e.g., app restarted), it will send null identifiers.
            // We assume it's requesting resumption of the currently active file.
            if (reqFileId == null && reqLastCompletedFileId == null && _currentBatchFile?.id != null) {
              debugPrint('[TRANSFER] Receiver lost state. Assuming resumption of current file: ${_currentBatchFile!.id}');
              reqFileId = _currentBatchFile!.id;
            }

            if (batchId != null && reqHash != null && reqHash != manifestHash) {
              debugPrint('[TRANSFER] CRITICAL: Manifest hash mismatch on resume. reqHash: $reqHash, local: $manifestHash. Aborting.');
              streamAborted = true;
              return;
            }

            debugPrint('[TRANSFER] Strict Resume vector received at offset $resumeOffset. Rebuilding stream from that point!');
            _lastAckOffset = resumeOffset;
            _unackedChunks = 0; // Reset the sliding window to prevent deadlock on lost chunks
            
            if (!fromTcp) {
              // resume_request arrived via signaling — the receiver's TCP is dead.
              // Unconditionally lock to relay. Do NOT check isConnected after disconnect()
              // because disconnect() may not be synchronous — isConnected can still return
              // true briefly, leaving _isLockedToRelay=false and routing everything into
              // the dead TCP pipe that Mac already closed in onReconnected.
              if (tcpTransport != null && tcpTransport!.isConnected) {
                debugPrint('[TRANSFER] Receiver sent resume_request over Signaling! Killing TCP, locking to relay.');
                tcpTransport!.disconnect();
              }
              _isLockedToRelay = true;
              _isLockedToTcp = false;
            } else if (tcpTransport == null || !tcpTransport!.isConnected) {
              _isLockedToRelay = true;
              _isLockedToTcp = false;
            }
            
             if (reqFileId != null && _originalBatchFiles.isNotEmpty && _indexMap.containsKey(reqFileId)) {
                int targetIndex = _indexMap[reqFileId]!;
                
                // currentFileIndex is 1-based (file 0 in progress => currentFileIndex=1).
                // A file is truly stale only when fully past it: targetIndex < currentFileIndex - 1.
                if (targetIndex < currentFileIndex - 1) {
                  debugPrint('[TRANSFER] Ignoring stale resume_request for completed file index $targetIndex (current file: ${currentFileIndex - 1}).');
                  return;
                }
                
                debugPrint('[TRANSFER] Resuming Batch from fileId: $reqFileId');
                streamAborted = true;
                _sendGeneration++;
                
                Future.delayed(const Duration(milliseconds: 100), () {
                  streamAborted = false;
                  startBatchTransfer(List.from(_originalBatchFiles), customBatchId: batchId, startFromIndex: targetIndex, fileStartOffset: resumeOffset);
                });
             } else if (reqLastCompletedFileId != null && _originalBatchFiles.isNotEmpty && _indexMap.containsKey(reqLastCompletedFileId)) {
                int targetIndex = _indexMap[reqLastCompletedFileId]! + 1;
                
                // currentFileIndex is 1-based (file 0 in progress => currentFileIndex=1).
                // A file is truly stale only when fully past it: targetIndex < currentFileIndex - 1.
                if (targetIndex < currentFileIndex - 1) {
                  debugPrint('[TRANSFER] Ignoring stale resume_request for completed file index $targetIndex (current file: ${currentFileIndex - 1}).');
                  return;
                }
                
                if (targetIndex < _originalBatchFiles.length) {
                  debugPrint('[TRANSFER] Resuming Batch from next file index: $targetIndex');
                  streamAborted = true;
                  _sendGeneration++;
                  
                  Future.delayed(const Duration(milliseconds: 100), () {
                    streamAborted = false;
                    startBatchTransfer(List.from(_originalBatchFiles), customBatchId: batchId, startFromIndex: targetIndex, fileStartOffset: 0);
                  });
                } else {
                 debugPrint('[TRANSFER] Batch already fully completed. Ignoring resume request.');
               }
            } else if (_currentFileSource != null) {
              debugPrint('[TRANSFER] Resuming single legacy stream from $resumeOffset');
              streamAborted = true;
              _sendGeneration++;
              
              Future.delayed(const Duration(milliseconds: 100), () {
                streamAborted = false;
                _processCurrentFileInQueue(BatchFile(id: 'legacy-resume', path: fileName ?? 'web_upload', size: fileSize ?? 0, lastModified: 0, source: _currentFileSource), startOffset: resumeOffset);
              });
            }
          }
        } else if (data['type'] == 'ack_buffer') {
          final count = data['count'] ?? 8;
          _unackedChunks -= (count as int);
          if (_unackedChunks < 0) _unackedChunks = 0;
          _consecutiveTimeouts = 0; // Receiver is alive!
          if (_bufferCompleter != null && !_bufferCompleter!.isCompleted) {
             _bufferCompleter!.complete();
          }
        } else if (data['type'] == 'end_ack') {
          if (_endAckCompleter != null && !_endAckCompleter!.isCompleted) {
             _endAckCompleter!.complete();
          }
        } else if (data['type'] == 'end') {
          _endReceived = true;
          if (!_isInitializingSink && _receivedCount >= (fileSize ?? 0)) {
            await _finalizeTransfer();
          }
        } else if (data['type'] == 'end_batch') {
          final int expectedFiles = data['totalFiles'] ?? 0;
          int completedFilesCount = 0;
          if (_lastCompletedFileId != null && _indexMap.containsKey(_lastCompletedFileId)) {
             completedFilesCount = _indexMap[_lastCompletedFileId]! + 1;
          }
          if (completedFilesCount < expectedFiles) {
             debugPrint('[TRANSFER] ERROR: Batch finished but we only completed $completedFilesCount / $expectedFiles files!');
             state = TransferState.failed;
          } else {
             debugPrint('[TRANSFER] SUCCESS: Batch verified. $completedFilesCount / $expectedFiles files completed.');
             state = TransferState.completed;
          }
        }
    } catch (e) {
      debugPrint('[TRANSFER] Error handling metadata/signaling: $e');
    }
  }

  Future<void> _processChunk(Uint8List encryptedChunk) async {
    if (state == TransferState.paused) {
      debugPrint('[TRANSFER] Received chunk while paused. Force unpausing!');
      state = TransferState.transferring;
    }
    if (state != TransferState.transferring) return;
    
    try {
      final decryptedChunk = EncryptionService.decryptChunk(
        encryptedChunk, 
        encryptionKey, 
        encryptionIv, 
        _receivedCount // Synchronize with receiver's current file position
      );
      _fileHandler.addChunk(decryptedChunk);
      _receivedCount += decryptedChunk.length;
      _lastChunkReceivedAt = DateTime.now().millisecondsSinceEpoch;
      
      _resetReceiverWatchdog();
      
      if (fileSize != null) {
        if (_receivedCount - decryptedChunk.length == 0) {
          TelemetryService().markFirstByte();
        }
        TelemetryService().trackProgress(decryptedChunk.length);
        if (batchId != null && totalBatchBytes > 0) {
          progress = globalProgress;
        } else {
          progress = _receivedCount / fileSize!;
        }
        progressController.add(progress);
        
        _receiverChunksProcessed++;
        if (_receiverChunksProcessed >= 1) { // Send ack EVERY chunk to maintain smooth relay pacing
          _receiverChunksProcessed = 0;
          final jsonAck = json.encode({'type': 'ack_buffer', 'count': 1});
          if (tcpTransport != null && tcpTransport!.isConnected) {
            tcpTransport!.sendText(jsonAck);
          } else {
            webrtc.sendSocketMessage(jsonAck, sessionId ?? 'global');
          }
        }
        
        if (_receivedCount >= fileSize! && _endReceived) {
          await _finalizeTransfer();
        }
      }
    } catch (e) {
      debugPrint('[TRANSFER] Decryption Error (likely mid-air chunk corruption): $e');
      
      final now = DateTime.now().millisecondsSinceEpoch;
      if (now - _lastResumeRequestTime < 3000) {
        debugPrint('[TRANSFER] Debouncing duplicate resume request from corruption burst.');
        return;
      }
      _lastResumeRequestTime = now;
      
      // Do NOT finalize the transfer. A corrupted chunk should trigger a resumption.
      final resumeMsg = json.encode({
        'type': 'resume_request',
        'batchId': batchId,
        'manifestHash': manifestHash,
        'fileId': _currentBatchFile?.id,
        'lastCompletedFileId': _lastCompletedFileId,
        'offset': _receivedCount
      });
      if (tcpTransport != null && tcpTransport!.isConnected) {
        tcpTransport!.sendText(resumeMsg);
      } else {
        webrtc.sendSocketMessage(resumeMsg, sessionId ?? 'global');
      }
    }
  }


  Future<void> _finalizeTransfer() async {
    _receiverWatchdog?.cancel();
    lastSavedPath = await _fileHandler.finalize();
    
    // Add the completed file's size to the batch total
    if (batchId != null && fileSize != null) {
      _completedBatchBytes += fileSize!;
    }
    
    if (_currentBatchFile != null) {
      _lastCompletedFileId = _currentBatchFile!.id;
    }
    _currentBatchFile = null;
    
    if (batchId == null) {
      state = TransferState.completed;
      TelemetryService().finish(true);
      debugPrint('[TRANSFER] File finalized successfully');
    } else {
      debugPrint('[TRANSFER] File finalized. Waiting for next batch file...');
      if (totalBatchBytes > 0 && _completedBatchBytes >= totalBatchBytes) {
         state = TransferState.completed;
         TelemetryService().finish(true);
         debugPrint('[TRANSFER] BATCH finalized successfully! All files received.');
      }
    }
    
    // Safety pause: Allows Android OS MediaScanner to properly flush DB transactions
    // and physically write the file handle to disk before blasting the next batch file.
    await Future.delayed(const Duration(milliseconds: 500));
    
    // Notify sender that we are completely done writing this file to disk
    final ackMsg = json.encode({'type': 'end_ack', 'platform': PlatformUtils.operatingSystem});
    if (tcpTransport != null && tcpTransport!.isConnected) {
      tcpTransport!.sendText(ackMsg);
    } else {
      webrtc.sendSocketMessage(ackMsg, sessionId ?? 'global');
    }
    if (!kIsWeb && lastSavedPath != null && batchId == null) {
      try {
        await OpenFile.open(lastSavedPath);
      } catch (e) {
        debugPrint('[TRANSFER] Could not auto-open file: $e');
      }
    }
  }

  void dispose() {
    progressController.close();
  }
}
