import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:socket_io_client/socket_io_client.dart' as IO;
import 'package:flutter/foundation.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../config.dart';
import 'fallback_helper.dart';
import 'network_service.dart';
import 'telemetry_service.dart';

class WebRTCService {
  IO.Socket? _socket;
  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  
  Function(String)? onCodeGenerated;
  Function(String, String)? onKeysReceived;
  Function(RTCDataChannelMessage)? onMessage;
  Function(double)? onProgress;
  Function(int)? onBufferedAmountLow;
  Function(RTCPeerConnectionState)? onConnectionState;
  Function()? onReceiverJoined;
  Function()? onDisconnected;
  Function()? onReconnected;
  Function()? onRelayReady;
  /// WARM FALLBACK: fires once per session when WebRTC fails and relay should take over.
  /// Wired in TransferManager to set _isLockedToRelay = true. No-op if not set.
  Function()? onFallbackSwap;
  Function(String)? onError;
  bool _wasConnectedBefore = false;

  final Completer<void> _dataChannelOpenCompleter = Completer<void>();
  Future<void> get onDataChannelOpen => _dataChannelOpenCompleter.future;
  
  final ValueNotifier<bool> isSocketConnected = ValueNotifier<bool>(false);
  final ValueNotifier<String> currentRoute = ValueNotifier<String>('Relay');
  bool _webRtcBroken = false; // Detection for MissingPluginException
  final NetworkService _network = NetworkService();
  bool _isReconnecting = false;
  String _discoveredNatType = 'Unknown';

  String? signalingUrl;
  bool _isSender = false;
  bool _isRelayMetricSent = false;
  String? _currentSessionId;
  bool _transferHandshakeDone = false; // Guard: onReceiverJoined fires only ONCE per session

  WebRTCService({this.signalingUrl}) {
    if (FEATURES.remoteContinuation && !kIsWeb) {
      _network.onNetworkChanged = _handleNetworkChange;
      _network.start();
    }
  }

  void connect({
    required String sessionId,
    bool isSender = false,
    String? code,
    String? encryptionKey,
    String? encryptionIv,
  }) {
    _isSender = isSender;
    _currentSessionId = sessionId;
    // Cleanup URL aggressively to avoid ":0" or malformed port issues
    String baseUrl = (signalingUrl ?? AppConfig.signalingUrl).trim();
    
    // Remove any trailing colon or slash
    while (baseUrl.endsWith(':') || baseUrl.endsWith('/')) {
      baseUrl = baseUrl.substring(0, baseUrl.length - 1);
    }
    
    if (baseUrl.contains('serveousercontent.com') || baseUrl.contains('loca.lt')) {
      // Force HTTPS and ensure explicit 443 port to prevent Dart WebSocket port 0 bug
      baseUrl = baseUrl.replaceAll('http://', 'https://');
      if (baseUrl.contains(':0')) {
        baseUrl = baseUrl.split(':0').first;
      }
      
    }

    final String finalUrl = baseUrl;
    debugPrint('[WEBRTC] Connecting to signaling at: $finalUrl');
    TelemetryService().startSession(sessionId);

    if (_socket != null && _socket!.connected) {
      debugPrint('[WEBRTC] Socket already connected. Reusing...');
      return;
    }

    if (_socket != null) {
      _socket!.dispose();
    }
    _isRelayMetricSent = false;

    // Optimization: If it's a local network IP, use a raw socket without the bypass header 
    // (which Serveo/Localtunnel need) to reduce overhead.
    final bool isLocal = finalUrl.contains('192.168.') || finalUrl.contains('10.') || finalUrl.contains('localhost');

    _socket = IO.io(finalUrl, IO.OptionBuilder()
      .setTransports(['websocket', 'polling'])
      .enableForceNew()
      .setReconnectionAttempts(999999) // Infinite retry
      .setReconnectionDelay(2000)
      .build());

    _socket!.onConnect((_) {
      debugPrint('[WEBRTC] SUCCESSFULLY CONNECTED to signaling server');
      isSocketConnected.value = true;
      if (_wasConnectedBefore) {
        onReconnected?.call();
      }
      _wasConnectedBefore = true;

      if (isSender) {
        _socket!.emit('create-session', {
          'sessionId': _currentSessionId,
          'encryptionKey': encryptionKey,
          'encryptionIv': encryptionIv,
        });
      } else {
        _socket!.emit('join-session', {
          'sessionId': _currentSessionId,
          'code': code,
        });
      }
    });

    _socket!.on('relay-ready', (_) {
      onRelayReady?.call();
    });

    _socket!.onDisconnect((_) {
      debugPrint('[WEBRTC] Socket disconnected (Network Drop). Retrying...');
      isSocketConnected.value = false;
      onDisconnected?.call();
    });

    // RELAY TRANSPORT: Listen for data — filter by sessionId to prevent stale cross-session data
    _socket!.on('on-data', (data) {
      // Only filter when we have a real sessionId AND incoming has one AND they don't match
      final incomingSession = data['sessionId'] as String?;
      if (_currentSessionId != null && _currentSessionId!.isNotEmpty && incomingSession != null && incomingSession.isNotEmpty && incomingSession != _currentSessionId) {
        debugPrint('[WEBRTC] Dropped stale chunk from session $incomingSession');
        return;
      }
      
      debugPrint('[WEBRTC] Data received via Socket-Pipe Fallback');
      currentRoute.value = 'Relay';
      if (!_isRelayMetricSent) {
        TelemetryService().markConnected(
          'Relay', 
          _networkResultsToString(),
          natType: _discoveredNatType,
          senderPlatform: _isSender ? _getOsName() : null,
          receiverPlatform: !_isSender ? _getOsName() : null,
        );
        _isRelayMetricSent = true;
      }
      if (data['text'] != null) {
        onMessage?.call(RTCDataChannelMessage(data['text']));
      } else if (data['binary'] != null) {
        try {
          final raw = data['binary'];
          Uint8List binary;
          if (raw is Uint8List) {
            binary = raw;
          } else if (raw is String) {
            // Socket.IO XHR Polling automatically base64 encodes binary payloads!
            binary = base64Decode(raw);
          } else {
            // Standard Socket.IO JSON array of bytes
            binary = Uint8List.fromList(List<int>.from(raw as Iterable));
          }
          onMessage?.call(RTCDataChannelMessage.fromBinary(binary));
        } catch (e) {
          debugPrint('[WEBRTC] Error parsing socket binary chunk: $e');
        }
      }
    });

    // Resume trigger: when peer drops, pause. When they reconnect, join-success re-fires.
    _socket!.on('peer-disconnected', (_) {
      debugPrint('[WEBRTC] Peer disconnected. Pausing for resume...');
      onDisconnected?.call();
    });

    _socket!.on('peer-joined', (_) {
      debugPrint('[WEBRTC] Peer joined room.');
      if (_transferHandshakeDone) {
        debugPrint('[WEBRTC] Peer re-joined mid-transfer. Triggering resume logic.');
        onReconnected?.call();
      } else if (_isSender) {
        onReceiverJoined?.call();
      }
    });

    _socket!.on('join-success', (data) async {
      if (data['sessionId'] != null) {
        _currentSessionId = data['sessionId']; // Convert PIN to true UUID
      }
      debugPrint('[WEBRTC] Join success received for session: $_currentSessionId (handshakeDone: $_transferHandshakeDone)');

      if (!_isSender && data['encryptionKey'] != null) {
        onKeysReceived?.call(data['encryptionKey'], data['encryptionIv']);
      }

      if (!_transferHandshakeDone) {
        _transferHandshakeDone = true;
        if (_isSender) {
          debugPrint('[WEBRTC] First join — starting transfer.');
          onReceiverJoined?.call();
        } else {
          debugPrint('[WEBRTC] Receiver first join — waiting for data.');
        }
      } else {
        debugPrint('[WEBRTC] Reconnect join — triggering resume.');
        onReconnected?.call();
      }

      // Re-establish WebRTC peer connection on reconnect
      if (!_webRtcBroken) {
        try {
          // Reset so a fresh P2P channel can be created after network switch
          if (_peerConnection != null) {
            await _peerConnection?.close();
            await _peerConnection?.dispose();
          }
          _peerConnection = null;
          await _createPeerConnection(sessionId);
        } catch (e) {
          debugPrint('[WEBRTC] WebRTC Init failed (falling back to socket): $e');
          if (e.toString().contains('MissingPluginException')) {
            _webRtcBroken = true;
          }
        }
      }
    });

    _socket!.on('offer', (data) async {
      debugPrint('[WEBRTC] Offer received. Processing...');
      try {
        if (_peerConnection == null) await _createPeerConnection(sessionId);
        await _peerConnection?.setRemoteDescription(
          RTCSessionDescription(data['sdp'], data['type']),
        );
        var answer = await _peerConnection?.createAnswer();
        await _peerConnection?.setLocalDescription(answer!);
        _socket!.emit('answer', {
          'sessionId': sessionId,
          'sdp': answer!.sdp,
          'type': answer.type,
        });
      } catch (e) {
        debugPrint('[WEBRTC] Offer processing error: $e');
      }
    });

    _socket!.on('answer', (data) async {
      debugPrint('[WEBRTC] Answer received.');
      try {
        if (_isSender) {
          await _peerConnection?.setRemoteDescription(
            RTCSessionDescription(data['sdp'], data['type']),
          );
        }
      } catch (e) {
        debugPrint('[WEBRTC] Answer processing error: $e');
      }
    });

    _socket!.on('ice-candidate', (data) {
      try {
        _peerConnection?.addCandidate(
          RTCIceCandidate(data['candidate'], data['sdpMid'], data['sdpMLineIndex']),
        );
      } catch (e) {
        debugPrint('[WEBRTC] ICE Candidate error: $e');
      }
    });

    _socket!.on('session-created', (data) {
      if (_isSender) onCodeGenerated?.call(data['code']);
    });

    _socket!.onConnectError((err) {
      debugPrint('[WEBRTC] Connection Error: $err');
      isSocketConnected.value = false;
      // We NEVER abort the session on a connection error! 
      // Socket.IO is set to infinitely retry. If a local TCP transfer is running, 
      // throwing an error here would violently destroy the active transfer UI!
    });

    _socket!.on('error', (data) {
      final msg = data['message'] ?? 'Unknown Error';
      debugPrint('[WEBRTC] Server explicitly rejected: $msg');
      onError?.call(msg);
      // Clean up to prevent hanging
      isSocketConnected.value = false;
    });
  }

  Future<void> start(String sessionId, bool isSender, {String? encryptionKey, String? encryptionIv, String? code}) async {
    connect(
      sessionId: sessionId, 
      isSender: isSender, 
      encryptionKey: encryptionKey, 
      encryptionIv: encryptionIv,
      code: code
    );
  }

  Future<void> _createPeerConnection(String sessionId) async {
    if (_peerConnection != null) return;

    debugPrint('[WEBRTC] Initializing Secure PeerConnection...');
    Map<String, dynamic> configuration = {
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {'urls': 'stun:stun1.l.google.com:19302'},
        {'urls': 'stun:stun2.l.google.com:19302'},
        // Only include TURN fallback if absolutely necessary for restricted networks
        {
          'urls': 'turn:openrelay.metered.ca:443',
          'username': 'openrelayproject',
          'password': 'openrelayproject'
        }
      ],
      'iceCandidatePoolSize': 4, // Reduced from 10 to speed up gathering start
    };

    try {
      _peerConnection = await createPeerConnection(configuration);

      _peerConnection!.onConnectionState = (state) {
        debugPrint('[WEBRTC] Connection: $state');
        if (state == RTCPeerConnectionState.RTCPeerConnectionStateFailed ||
            state == RTCPeerConnectionState.RTCPeerConnectionStateDisconnected) {
          if (FEATURES.warmFallbacks) {
            FallbackHelper.markFailed(sessionId);
            // querySwap returns true only once per session (one-shot guard in FallbackHelper)
            if (FallbackHelper.querySwap(sessionId)) {
              debugPrint('[WEBRTC] Warm fallback swap triggered for session $sessionId');
              onFallbackSwap?.call();
            }
          }
        }
        onConnectionState?.call(state);
      };

      _peerConnection!.onIceCandidate = (candidate) {
        if (candidate.candidate != null) {
          _updateNatType(candidate.candidate!);
          if (_socket != null && _socket!.connected) {
            _socket!.emit('ice-candidate', {
              'sessionId': sessionId,
              'candidate': candidate.candidate,
              'sdpMid': candidate.sdpMid,
              'sdpMLineIndex': candidate.sdpMLineIndex,
            });
          }
        }
      };

      if (_isSender) {
        _dataChannel = await _peerConnection!.createDataChannel(
          'fileTransfer',
          RTCDataChannelInit()..ordered = true,
        );
        _setupDataChannel();
        
        var offer = await _peerConnection!.createOffer();
        await _peerConnection!.setLocalDescription(offer);
        _socket!.emit('offer', {
          'sessionId': sessionId,
          'sdp': offer.sdp,
          'type': offer.type,
        });
      } else {
        _peerConnection!.onDataChannel = (channel) {
          debugPrint('[WEBRTC] Stream Channel Received!');
          _dataChannel = channel;
          _setupDataChannel();
        };
      }
    } catch (e) {
      debugPrint('[WEBRTC] Fatal PeerConnection Error: $e');
      rethrow;
    }
  }

  void _setupDataChannel() {
    if (_dataChannel == null) return;
    _dataChannel!.onDataChannelState = (state) {
      debugPrint('[WEBRTC] DataChannel: $state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        if (FEATURES.warmFallbacks && _currentSessionId != null) {
          FallbackHelper.preWarm(this, _currentSessionId!);
        }
        if (!_dataChannelOpenCompleter.isCompleted) {
          _dataChannelOpenCompleter.complete();
        }
        TelemetryService().markConnected(
          'Encrypted P2P', 
          _networkResultsToString(),
          natType: _discoveredNatType,
          senderPlatform: _isSender ? _getOsName() : null,
          receiverPlatform: !_isSender ? _getOsName() : null,
        );
      }
    };
    _dataChannel!.onMessage = (m) {
      currentRoute.value = 'Encrypted P2P';
      onMessage?.call(m);
    };
    _dataChannel!.onBufferedAmountLow = (a) => onBufferedAmountLow?.call(a);
  }

  void sendMessage(String text) => _dataChannel?.send(RTCDataChannelMessage(text));
  void sendBinary(Uint8List bytes) => _dataChannel?.send(RTCDataChannelMessage.fromBinary(bytes));
  
  Future<void> sendSocketData(Uint8List chunk, String sessionId, int offset) async {
    final url = Uri.parse('${AppConfig.signalingUrl}/relay/$sessionId');
    int retryDelayMs = 500;
    
    while (true) {
      try {
        final response = await http.post(
          url,
          body: chunk,
          headers: {
            'Content-Type': 'application/octet-stream',
            'x-chunk-offset': offset.toString()
          }
        ).timeout(const Duration(seconds: 60)); // 60s allows for very slow 8.5KB/s hotspots
        
        if (response.statusCode == 200) {
          return; // Successfully pushed to cloud queue
        } else {
          debugPrint('[WEBRTC] HTTP Relay Server Error: ${response.statusCode}. Retrying...');
        }
      } catch (e) {
        debugPrint('[WEBRTC] HTTP Relay Network Drop: $e. Retrying in ${retryDelayMs}ms...');
      }
      
      // Wait before retrying
      await Future.delayed(Duration(milliseconds: retryDelayMs));
      // Exponential backoff capped at 3 seconds
      retryDelayMs = (retryDelayMs * 1.5).toInt().clamp(500, 3000);
    }
  }

  void sendSocketMessage(String text, String sessionId) {
    if (_socket != null && _socket!.connected) {
      _socket!.emit('signal-data', {
        'sessionId': sessionId,
        'text': text,
      });
    }
  }

  void sendAdaptiveMessage(String text, String sessionId) {
    if (_dataChannel != null && _dataChannel!.state == RTCDataChannelState.RTCDataChannelOpen) {
      _dataChannel!.send(RTCDataChannelMessage(text));
    } else {
      sendSocketMessage(text, sessionId);
    }
  }

  int get bufferedAmount => _dataChannel?.bufferedAmount ?? 0;
  String get currentResultsString => _networkResultsToString();

  String _networkResultsToString() {
    return _networkCurrentResults.map((r) => r.toString().split('.').last).join('+');
  }

  List<ConnectivityResult> _networkCurrentResults = [];
  void _handleNetworkChange(List<ConnectivityResult> results) async {
    _networkCurrentResults = results;
    if (_isReconnecting || _currentSessionId == null) return;
    
    // If the network drops COMPLETELY (e.g., Airplane mode ON), do NOT attempt a soft reconnect!
    // socket_io_client will permanently crash if initialized without any network interface.
    if (results.isEmpty || results.contains(ConnectivityResult.none)) {
       debugPrint('[CONTINUATION] Device is completely offline. Pausing reconnect attempts.');
       return;
    }

    _isReconnecting = true;
    
    debugPrint('[CONTINUATION] Network change detected. Monitoring original reconnect flow...');
    
    // 1. Give Socket.IO's built-in reconnect logic a chance first (5s)
    await Future.delayed(const Duration(seconds: 5));
    
    if (isSocketConnected.value) {
      debugPrint('[CONTINUATION] Native reconnect successful. No action needed.');
      _isReconnecting = false;
      return;
    }
    
    debugPrint('[CONTINUATION] Reconnect timed out. Performing SOFT socket reconnect...');
    
    // 2. SOFT reconnect: only replace the broken socket, do NOT call full dispose().
    // Calling dispose() would kill the network monitor and reset _wasConnectedBefore,
    // causing the receiver to re-initialize instead of resume from the current offset.
    final sid = _currentSessionId!;
    
    // Mark as previously connected so onConnect triggers onReconnected (not onReceiverJoined)
    _wasConnectedBefore = true;
    
    // Dispose only the broken socket/peer, keep network monitor alive
    _socket?.dispose();
    _socket = null;
    try { _dataChannel?.close(); } catch (_) {}
    try { _peerConnection?.dispose(); } catch (_) {}
    _peerConnection = null;
    _dataChannel = null;
    
    // Reconnect the signaling socket to re-join the existing session
    connect(
      sessionId: sid,
      isSender: _isSender,
    );
    
    _isReconnecting = false;
  }

  void _updateNatType(String candidate) {
    if (candidate.contains('typ relay')) {
      _discoveredNatType = 'Relay (TURN)';
    } else if (candidate.contains('typ srflx') && _discoveredNatType != 'Relay (TURN)') {
      _discoveredNatType = 'NAT (STUN)';
    } else if (candidate.contains('typ host') && _discoveredNatType == 'Unknown') {
      _discoveredNatType = 'Direct (Host)';
    }
  }

  String _getOsName() {
    if (kIsWeb) return 'Web';
    return defaultTargetPlatform.toString().split('.').last;
  }

  void dispose() {
    _network.stop();
    _socket?.dispose();
    try {
      _dataChannel?.close();
      _peerConnection?.dispose(); 
    } catch (e) {
      debugPrint('[WEBRTC] Handled dispose exception (Native Plugin): $e');
    }
    _peerConnection = null;
    _dataChannel = null;
  }
}
