import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import 'platform_utils.dart';
import '../config.dart';

class DiscoveredDevice {
  final String id;
  final String name;
  final String ip;
  final int tcpPort;
  final String platform;
  DateTime lastSeen;

  DiscoveredDevice({
    required this.id,
    required this.name,
    required this.ip,
    required this.tcpPort,
    required this.platform,
    required this.lastSeen,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'ip': ip,
    'tcpPort': tcpPort,
    'platform': platform,
  };
}

class DiscoveryService {
  static final DiscoveryService _instance = DiscoveryService._internal();
  factory DiscoveryService() => _instance;
  DiscoveryService._internal();

  static const int _broadcastPort = 48880;
  static const String _multicastAddress = "224.0.0.1";

  RawDatagramSocket? _socket;
  Timer? _broadcastTimer;
  Timer? _cleanupTimer;
  Timer? _subnetScanTimer;
  bool _running = false;

  final String _deviceId = const Uuid().v4();
  int _tcpPort = 0;

  final ValueNotifier<List<DiscoveredDevice>> discoveredDevices = ValueNotifier([]);

  Future<void> start(int localTcpPort) async {
    if (kIsWeb) return;
    if (_running) {
      // Just update the TCP port if already running
      _tcpPort = localTcpPort;
      return;
    }
    _running = true;
    _tcpPort = localTcpPort;

    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, 
        _broadcastPort, 
        reuseAddress: true, 
        reusePort: true,
      );
      
      try {
        _socket!.joinMulticast(InternetAddress(_multicastAddress));
      } catch (e) {
        debugPrint('[DISCOVERY] Multicast join failed (may be blocked by hotspot): $e');
      }
      _socket!.broadcastEnabled = true;

      _socket!.listen((RawSocketEvent event) {
        if (event == RawSocketEvent.read) {
          final datagram = _socket?.receive();
          if (datagram != null) _handleIncoming(datagram);
        }
      });

      _startBroadcasting();
      _cleanupTimer = Timer.periodic(const Duration(seconds: 5), (_) => _cleanupStaleDevices());
      
      // HOTSPOT FALLBACK: Scan the subnet directly every 10 seconds
      // This works even when the iPhone hotspot blocks multicast UDP
      _startSubnetScan();

      debugPrint('[DISCOVERY] Radar Active on port $_broadcastPort');
    } catch (e) {
      debugPrint('[DISCOVERY] Failed to start: $e');
      _running = false;
    }
  }

  void updateTcpPort(int port) {
    _tcpPort = port;
    debugPrint('[DISCOVERY] TCP port updated to $port');
  }

  void _handleIncoming(Datagram datagram) {
    try {
      final jsonStr = utf8.decode(datagram.data);
      final map = json.decode(jsonStr);

      if (map['id'] == _deviceId) return; // Ignore our own beacon

      if (map.containsKey('tunnelUrl')) {
        final url = map['tunnelUrl'] as String?;
        if (url != null && url.isNotEmpty) {
          AppConfig.updateRemoteUrl(url);
        }
      }

      final device = DiscoveredDevice(
        id: map['id'],
        name: map['name'] ?? 'Unknown Device',
        ip: datagram.address.address,
        tcpPort: map['tcpPort'] ?? 0,
        platform: map['platform'] ?? 'Unknown',
        lastSeen: DateTime.now(),
      );

      _addOrUpdateDevice(device);
    } catch (e) {
      // Not a valid beacon
    }
  }

  void _addOrUpdateDevice(DiscoveredDevice device) {
    if (device.tcpPort == 0) return; // Skip devices with no TCP port yet
    final list = List<DiscoveredDevice>.from(discoveredDevices.value);
    final existingIndex = list.indexWhere((d) => d.id == device.id);

    if (existingIndex >= 0) {
      list[existingIndex] = device;
    } else {
      list.add(device);
      debugPrint('[DISCOVERY] ✅ Found peer: ${device.name} @ ${device.ip}:${device.tcpPort}');
    }
    discoveredDevices.value = list;
  }

  void _startBroadcasting() async {
    String deviceName = PlatformUtils.operatingSystem;
    try { deviceName = Platform.localHostname; } catch (_) {}

    _broadcastTimer?.cancel();
    _broadcastTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (_socket == null) return;
      // Refresh beacon every time so tcpPort is always current
      final beacon = json.encode({
        'id': _deviceId,
        'name': deviceName,
        'tcpPort': _tcpPort,
        'platform': PlatformUtils.operatingSystem,
        'tunnelUrl': AppConfig.remoteUrl,
      });
      final payload = utf8.encode(beacon);
      
      try {
        // 1. Multicast (standard networks)
        _socket!.send(payload, InternetAddress(_multicastAddress), _broadcastPort);
        
        // 2. Global broadcast
        _socket!.send(payload, InternetAddress('255.255.255.255'), _broadcastPort);
        
        // 3. Subnet-directed broadcast per interface
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        for (var iface in interfaces) {
          for (var addr in iface.addresses) {
            final ipBytes = List<int>.from(addr.rawAddress);
            ipBytes[3] = 255; // /24 broadcast
            _socket!.send(
              payload,
              InternetAddress.fromRawAddress(Uint8List.fromList(ipBytes)),
              _broadcastPort,
            );
          }
        }
      } catch (e) {
        // Silently ignore send errors
      }
    });
  }

  /// Hotspot/WiFi Subnet Scanner: Scans /24 subnet for peers
  /// Works even when multicast is blocked by iPhone hotspot or restricted WiFi
  void _startSubnetScan() {
    _subnetScanTimer?.cancel();
    _subnetScanTimer = Timer.periodic(const Duration(seconds: 4), (_) async {
      try {
        final interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
        for (var iface in interfaces) {
          for (var addr in iface.addresses) {
            final ip = addr.address;
            final parts = ip.split('.');
            if (parts.length != 4) continue;

            // Skip invalid/non-LAN ranges
            if (ip.startsWith('127.')) continue;      // loopback
            if (ip.startsWith('169.254.')) continue;  // link-local
            if (ip.startsWith('192.0.0.')) continue;  // Apple captive portal
            if (ip == '0.0.0.0') continue;

            // Only scan private LAN ranges
            final isPrivate = ip.startsWith('10.') ||
                ip.startsWith('172.') ||
                ip.startsWith('192.168.');
            if (!isPrivate) continue;

            final subnet = '${parts[0]}.${parts[1]}.${parts[2]}';
            debugPrint('[DISCOVERY] Scanning $subnet.0/24 on ${iface.name}...');

            final futures = <Future>[];
            for (int i = 1; i < 255; i++) {
              final targetIp = '$subnet.$i';
              if (targetIp == ip) continue; // skip self
              futures.add(_probePeer(targetIp));
            }
            // Run all probes concurrently
            await Future.wait(futures, eagerError: false);
          }
        }
      } catch (e) {
        debugPrint('[DISCOVERY] Subnet scan error: $e');
      }
    });
  }

  Future<void> _probePeer(String ip) async {
    try {
      final beacon = json.encode({
        'id': _deviceId,
        'name': PlatformUtils.operatingSystem,
        'tcpPort': _tcpPort,
        'platform': PlatformUtils.operatingSystem,
        'tunnelUrl': AppConfig.remoteUrl,
      });
      final payload = utf8.encode(beacon);
      _socket?.send(payload, InternetAddress(ip), _broadcastPort);
    } catch (_) {}
  }

  void _cleanupStaleDevices() {
    final now = DateTime.now();
    final list = List<DiscoveredDevice>.from(discoveredDevices.value)
      ..removeWhere((d) => now.difference(d.lastSeen).inSeconds > 15);

    if (list.length != discoveredDevices.value.length) {
      discoveredDevices.value = list;
    }
  }

  void stop() {
    _running = false;
    _broadcastTimer?.cancel();
    _cleanupTimer?.cancel();
    _subnetScanTimer?.cancel();
    _socket?.close();
    _socket = null;
    discoveredDevices.value = [];
    debugPrint('[DISCOVERY] Stopped.');
  }
}
