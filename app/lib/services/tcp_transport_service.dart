import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

class TcpMessage {
  final bool isBinary;
  final dynamic data; // String text or Uint8List binary

  TcpMessage({required this.isBinary, required this.data});
}

class TcpTransportService {
  ServerSocket? _serverSocket;
  Socket? _activeSocket;
  bool isServer = false;

  final StreamController<TcpMessage> _onData = StreamController<TcpMessage>.broadcast();
  final StreamController<String> _onStatus = StreamController<String>.broadcast();

  Stream<TcpMessage> get onData => _onData.stream;
  Stream<String> get onStatus => _onStatus.stream;
  bool get isConnected => _activeSocket != null;
  int get port => _serverSocket?.port ?? 0;

  /// Starts the server on a random port and returns the bound port.
  Future<int> startServer() async {
    isServer = true;
    _serverSocket = await ServerSocket.bind(InternetAddress.anyIPv4, 0);
    _onStatus.add('listening');

    _serverSocket!.listen((clientSocket) {
      debugPrint('[TCP] Incoming connection from ${clientSocket.remoteAddress.address}');
      
      // If we already have a connection, reject new ones to maintain 1-to-1 pairing
      if (_activeSocket != null) {
        debugPrint('[TCP] Rejected duplicate connection.');
        clientSocket.close();
        return;
      }

      _activeSocket = clientSocket;
      _onStatus.add('connected');
      _listenToSocket();
    });

    debugPrint('[TCP] Server bound on port ${_serverSocket!.port}');
    return _serverSocket!.port;
  }

  /// Connects to a remote server.
  Future<void> connect(String ip, int port) async {
    isServer = false;
    _onStatus.add('connecting');
    try {
      _activeSocket = await Socket.connect(ip, port, timeout: const Duration(seconds: 5));
      debugPrint('[TCP] Connected to Server at $ip:$port');
      _onStatus.add('connected');
      _listenToSocket();
    } catch (e) {
      debugPrint('[TCP] Connection failed: $e');
      _onStatus.add('failed');
    }
  }

  /// Directly attaches an already-connected socket (used for IP probing)
  void attachSocket(Socket socket) {
    isServer = false;
    _activeSocket = socket;
    _onStatus.add('connected');
    _listenToSocket();
  }

  // A chunk header format is needed because TCP is a stream. We need to split
  // chunks manually. Format: [4 bytes length][N bytes payload]
  List<int> _readBuffer = [];


  void _listenToSocket() {
    _activeSocket!.listen((List<int> data) {
      _readBuffer.addAll(data);
      _processBuffer();
    }, 
    onDone: () {
      debugPrint('[TCP] Socket done');
      _activeSocket?.close();
      _activeSocket = null;
      _onStatus.add('disconnected');
    }, 
    onError: (e) {
      debugPrint('[TCP] Socket error: $e');
      _activeSocket?.close();
      _activeSocket = null;
      _onStatus.add('disconnected');
    });
  }

  void _processBuffer() {
    while (_readBuffer.length >= 5) {
      // Read 4-byte length header + 1-byte type flag
      final lengthBytes = Uint8List.fromList(_readBuffer.sublist(0, 4));
      final payloadLength = ByteData.sublistView(lengthBytes).getUint32(0, Endian.big);

      // If we don't have the full payload yet, wait (4 bytes len + 1 byte flag + payload length)
      if (_readBuffer.length < 5 + payloadLength) {
        break;
      }

      final int typeFlag = _readBuffer[4];
      final bool isBinary = typeFlag == 1;

      // Extract the payload
      final payload = Uint8List.fromList(_readBuffer.sublist(5, 5 + payloadLength));
      _readBuffer.removeRange(0, 5 + payloadLength);

      if (!isBinary) {
        _onData.add(TcpMessage(isBinary: false, data: utf8.decode(payload)));
      } else {
        _onData.add(TcpMessage(isBinary: true, data: payload));
      }
    }
  }

  /// Sends binary data (file chunks)
  Future<void> sendBinary(Uint8List data) async {
    await _sendPacket(data, 1);
  }

  /// Sends text data (metadata json)
  Future<void> sendText(String text) async {
    await _sendPacket(utf8.encode(text) as Uint8List, 0);
  }

  Future<void> _sendPacket(Uint8List data, int typeFlag) async {
    if (_activeSocket != null) {
      try {
        final header = ByteData(4);
        header.setUint32(0, data.length, Endian.big);
        
        final packet = BytesBuilder();
        packet.add(header.buffer.asUint8List());
        packet.addByte(typeFlag);
        packet.add(data);
        
        _activeSocket!.add(packet.toBytes());
        // CRITICAL FIX: If the physical network drops without a TCP FIN packet (like Airplane mode),
        // flush() can hang indefinitely on Android, deadlocking the entire stream loop.
        // We MUST enforce a strict timeout so the fallback engine can engage!
        await _activeSocket!.flush().timeout(const Duration(seconds: 3));
      } catch (e) {
        debugPrint('[TCP] Send error (socket dead): $e');
        disconnect(); // Force internal cleanup on timeout/error
      }
    }
  }

  void disconnect() {
    if (_activeSocket != null) {
      debugPrint('[TCP] Forcibly disconnecting active socket.');
      _activeSocket!.close();
      _activeSocket!.destroy();
      _activeSocket = null;
      _onStatus.add('disconnected');
    }
  }

  void dispose() {
    _activeSocket?.close();
    _activeSocket = null;
    _serverSocket?.close();
    _serverSocket = null;
    _onData.close();
    _onStatus.close();
    debugPrint('[TCP] Service disposed.');
  }
}
