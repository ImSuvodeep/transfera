import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:flutter/foundation.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/webrtc_service.dart';
import '../services/transfer_manager.dart';
import '../widgets/premium_widgets.dart';
import '../widgets/route_indicator.dart';
import 'package:open_file_plus/open_file_plus.dart';
import '../config.dart';
import '../services/discovery_service.dart';
import '../services/tcp_transport_service.dart';

class ReceiverScreen extends StatefulWidget {
  final Uri? initialUri;
  const ReceiverScreen({super.key, this.initialUri});

  @override
  State<ReceiverScreen> createState() => _ReceiverScreenState();
}

class _ReceiverScreenState extends State<ReceiverScreen> {
  bool isScanned = false;
  bool isConnected = false;
  String statusMessage = 'Initializing...';
  double progress = 0.0;
  String? fileName;

  // Services are nullable so we can safely guard against double-dispose
  WebRTCService? _webrtc;
  TransferManager? _transferManager;
  late TcpTransportService tcpTransport;
  final List<TextEditingController> _digitControllers = List.generate(6, (_) => TextEditingController());
  final List<FocusNode> _focusNodes = List.generate(6, (_) => FocusNode());
  bool isEnteringCode = false;
  bool _servicesInitialized = false; // Guard: only tear down if we started them

  // Convenience getters that throw if not yet initialized
  WebRTCService get webrtc => _webrtc!;
  set webrtc(WebRTCService v) => _webrtc = v;
  TransferManager get transferManager => _transferManager!;
  set transferManager(TransferManager v) => _transferManager = v;

  @override
  void initState() {
    super.initState();
    tcpTransport = TcpTransportService();
    _initDiscovery();

    if (widget.initialUri != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _handleDeepLink(widget.initialUri!);
      });
    }
  }

  Future<void> _initDiscovery() async {
    // Start a TCP server so this device has a real port to advertise in the Radar beacon
    final port = await tcpTransport.startServer();
    DiscoveryService().start(port);
    _servicesInitialized = true;
    debugPrint('[RECEIVER] Discovery started with TCP port: $port');
  }

  String get _pairingCodeData {
    final tunnelUrl = AppConfig.remoteUrl;
    final data = { 'url': tunnelUrl };
    final jsonStr = json.encode(data);
    final base64Data = base64Url.encode(utf8.encode(jsonStr));
    return 'https://transfera.app/receive?d=$base64Data';
  }

  void _handleDeepLink(Uri uri) {
    if (mounted) setState(() => isScanned = true);
    _handleQrData(uri.toString());
  }

  void _onDetect(BarcodeCapture capture) {
    if (isScanned) return;
    
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final code = barcode.rawValue;
      if (code != null && (code.startsWith('https://transfera.app/receive?d=') || code.startsWith('transfera://receive?d='))) {
        _handleQrData(code);
        break;
      }
    }
  }

  void _handleCodeEntry() async {
    final code = _digitControllers.map((e) => e.text).join();
    if (code.length == 6) {
      if (mounted) {
        setState(() {
          isScanned = true;
          statusMessage = 'Connecting to server...';
        });
      }

      // Use centralized configuration for signaling
      final signalingUrl = AppConfig.signalingUrl;
      webrtc = WebRTCService(signalingUrl: signalingUrl);
      
      // Note: Encryption keys will be negotiated after connection 
      // or we can prompt for them. For now, we assume a default or 
      // pass them via the signaling message if the user wants "easy" transfers.
      // THE USER SAID: "6 digit random number with transfer links"
      // So the code represents the session.
      
      transferManager = TransferManager(
        webrtc: webrtc,
        encryptionKey: '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff', // 32 bytes
        encryptionIv: '00112233445566778899aabbccddeeff', // 16 bytes
        sessionId: code,
      );

      _setupServiceListeners();
      webrtc.start('', false, code: code);
    }
  }

  void _setupServiceListeners() {
    webrtc.onConnectionState = (state) {
      debugPrint('[RECEIVER] Peer Connection State: $state');
      if (mounted) {
        setState(() {
          if (state.toString().toLowerCase().contains('connected')) {
            isConnected = true;
            statusMessage = 'Link established! Receiving...';
          } else if (state.toString().toLowerCase().contains('failed') || 
                     state.toString().toLowerCase().contains('disconnected')) {
            statusMessage = 'Connection failed. Retrying...';
          }
        });
      }
    };

    webrtc.onError = (errorMsg) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(errorMsg)));
        setState(() {
          isScanned = false;
          statusMessage = 'Pairing Failed.';
        });
      }
    };

    webrtc.onReceiverJoined = () {
      if (mounted) setState(() => statusMessage = 'Joined session. Awaiting sender...');
    };

    webrtc.onKeysReceived = (key, iv) {
      debugPrint('[RECEIVER] Updating encryption keys from server');
      if (mounted) {
        setState(() {
          statusMessage = 'Keys exchanged! Ready for transfer.';
          transferManager.updateEncryption(key, iv);
        });
      }
    };

    transferManager.progressController.stream.listen((val) {
      if (mounted) {
        setState(() {
          progress = val;
          fileName = transferManager.fileName;
        });
      }
      if (val >= 1.0) {
        _showSuccess();
      }
    });
  }

  void _handleQrData(String url) async {
    try {
      final uri = Uri.parse(url);
      final base64Part = uri.queryParameters['d'] ?? url.split('d=')[1];
      final jsonStr = utf8.decode(base64Url.decode(base64Part));
      final data = json.decode(jsonStr);

      final sid = data['sid'];
      final key = data['key'];
      final iv = data['iv'];
      String signalingUrl = data['url'] ?? AppConfig.signalingUrl;
      final int tcpPort = data['tcpP'] ?? 0;
      final String ipsStr = data['ips'] ?? '';

      // Sanitization: If we are on Mac/Web and the QR code says 10.0.2.2 (Android-only),
      // we must translate it to 127.0.0.1 so the receiver can reach the server.
      if (!Platform.isAndroid && signalingUrl.contains('10.0.2.2')) {
        signalingUrl = signalingUrl.replaceAll('10.0.2.2', '127.0.0.1');
        debugPrint('[RECEIVER] Sanitized signaling URL for non-android peer: $signalingUrl');
      }
      
      // Ensure protocol is http for Socket.IO
      signalingUrl = signalingUrl.replaceAll('ws://', 'http://').replaceAll('wss://', 'https://');
      
      // Sync the global config so HTTP Relay fetch uses the correct tunnel!
      AppConfig.updateRemoteUrl(signalingUrl);

      // 1. Initialize synchronous objects immediately to prevent UI crash
      if (_webrtc != null) {
        _webrtc!.dispose();
      }
      if (_transferManager != null) {
        _transferManager!.dispose();
      }
      
      webrtc = WebRTCService(signalingUrl: signalingUrl);
      transferManager = TransferManager(
        webrtc: webrtc,
        tcpTransport: tcpTransport,
        encryptionKey: key,
        encryptionIv: iv,
        sessionId: sid,
      );

      // 2. Safe to update UI now that transferManager exists
      if (mounted) {
        setState(() {
          isScanned = true;
          statusMessage = 'Connecting...';
        });
      }

      tcpTransport.onStatus.listen((status) {
        if (status == 'connected') {
          if (mounted) {
            setState(() {
              statusMessage = 'Connected to Local Radar...';
            });
          }
        }
      });

      _setupServiceListeners();
      webrtc.start(sid, false);

      // Try all sender IPs IN PARALLEL to find the fastest local route
      if (tcpPort > 0 && ipsStr.isNotEmpty) {
        final ips = ipsStr.split(',').where((ip) {
          if (ip.isEmpty) return false;
          if (ip.startsWith('127.')) return false;
          if (ip.startsWith('192.0.0.')) return false; // Apple captive portal
          if (ip == '0.0.0.0') return false;
          return true;
        }).toList();

        debugPrint('[RECEIVER] Probing ${ips.length} IPs for direct TCP...');
        
        // Race all IPs at once — first to connect wins
        bool tcpConnected = false;
        final probes = ips.map((ip) async {
          try {
            final s = await Socket.connect(ip, tcpPort, timeout: const Duration(milliseconds: 2000));
            if (!tcpConnected) {
              tcpConnected = true;
              debugPrint('[RECEIVER] Direct TCP reachable at $ip! Latching pipe...');
              tcpTransport.attachSocket(s);
            } else {
              s.destroy(); // Destroy losers of the race
            }
          } catch (_) {}
        });
        // Wait up to 2.5s total for any probe to succeed
        await Future.wait(probes, eagerError: false)
            .timeout(const Duration(milliseconds: 2500), onTimeout: () => []);
        
        if (tcpTransport.isConnected) {
          debugPrint('[RECEIVER] ⚡ Local Gigabit active! Bypassing relay entirely.');
        } else {
          debugPrint('[RECEIVER] No direct path found — relay will be used.');
        }
      }

    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Invalid Link Format')),
      );
      if (mounted) setState(() => isScanned = false);
    }
  }

  void _connectToNearby(DiscoveredDevice device) async {
    if (mounted) setState(() {
      isScanned = true;
      statusMessage = 'Connecting to ${device.name} via Local Radar...';
    });

    // Use the centralized signaling URL for key exchange
    final signalingUrl = AppConfig.signalingUrl;
    webrtc = WebRTCService(signalingUrl: signalingUrl);
    transferManager = TransferManager(
      webrtc: webrtc,
      tcpTransport: tcpTransport,
      encryptionKey: 'pending', // Will be overwritten when metadata arrives
      encryptionIv: 'pending',
    );
    _setupServiceListeners();

    // Connect directly via TCP — no internet needed for local transfers!
    await tcpTransport.connect(device.ip, device.tcpPort);
    if (tcpTransport.isConnected) {
      if (mounted) setState(() => statusMessage = 'Local Gigabit Link Active! Awaiting file...');
    } else {
      if (mounted) setState(() {
        isScanned = false;
        statusMessage = 'Could not reach ${device.name}. Try QR code.';
      });
    }
  }

  void _showSuccess() {
    Duration? transferDuration;
    if (transferManager.startTime != null && transferManager.endTime != null) {
      transferDuration = transferManager.endTime!.difference(transferManager.startTime!);
    }

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => PremiumSuccessPopup(
        fileName: fileName ?? 'File',
        transferDuration: transferDuration,
        onOpen: () async {
          if (transferManager.lastSavedPath != null) {
            try {
              final result = await OpenFile.open(transferManager.lastSavedPath);
              if (result.type != ResultType.done && mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not open file: ${result.message}')),
                );
              }
            } catch (e) {
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Could not open file: $e')),
                );
              }
            }
          }
          if (mounted) {
            Navigator.of(context).popUntil((route) => route.isFirst);
          }
        },
      ),
    );
  }

  @override
  void dispose() {
    // Only teardown WebRTC/TransferManager if they were initialized
    if (isScanned && _webrtc != null) {
      _webrtc!.dispose();
      _transferManager?.dispose();
    }
    // Only stop TCP/Discovery if the transfer fully completed or was never started.
    // If a transfer is still in progress (progress < 1.0 and > 0.0), keep the server alive
    // to avoid dropping the connection mid-transfer on navigation or hot-reload.
    final bool transferOngoing = progress > 0.0 && progress < 1.0;
    if (_servicesInitialized && !transferOngoing) {
      tcpTransport.dispose();
      DiscoveryService().stop();
    } else if (transferOngoing) {
      debugPrint('[RECEIVER] Skipping TCP/Discovery teardown — transfer in progress.');
    }
    for (var c in _digitControllers) {
      c.dispose();
    }
    for (var f in _focusNodes) {
      f.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isDesktop = !kIsWeb && Platform.isWindows;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(title: const Text('Receive File')),
      body: Stack(
        children: [
          const AnimatedMeshGradient(),
          isScanned 
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.all(32.0),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            statusMessage,
                            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFF03DAC6)),
                          ).animate().fadeIn().moveY(begin: 10, end: 0),
                          const SizedBox(height: 48),
                          Stack(
                            alignment: Alignment.center,
                            children: [
                              SizedBox(
                                width: 120,
                                height: 120,
                                child: CircularProgressIndicator(
                                  value: progress,
                                  strokeWidth: 4,
                                  backgroundColor: Colors.white10,
                                  color: const Color(0xFF03DAC6),
                                ),
                              ),
                              const Icon(Icons.download_for_offline_outlined, size: 48, color: Color(0xFF03DAC6))
                                .animate(onPlay: (c) => c.repeat())
                                .shimmer(duration: 2.seconds),
                            ],
                          ).animate().scale(curve: Curves.easeOutBack),
                          const SizedBox(height: 32),
                          Text(
                            '${(progress * 100).toInt()}%',
                            style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                          ),
                          const SizedBox(height: 12),
                          RouteIndicator(routeNotifier: transferManager.route),
                           if (progress >= 1.0 && transferManager.lastSavedPath != null) ...[
                            const SizedBox(height: 24),
                            ElevatedButton.icon(
                              onPressed: () async {
                                try {
                                  final result = await OpenFile.open(transferManager.lastSavedPath);
                                  if (result.type != ResultType.done && mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Could not open file: ${result.message}')),
                                    );
                                  }
                                } catch (e) {
                                  if (mounted) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text('Could not open file: $e')),
                                    );
                                  }
                                }
                              },
                              icon: const Icon(Icons.file_open),
                              label: const Text('OPEN FILE'),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF03DAC6),
                                foregroundColor: Colors.black,
                                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                              ),
                            ).animate().fadeIn().scale(),
                          ],
                        ],
                      ),
                    ),
                  ),
                ),
              )
            : Column(
                children: [
                  const Spacer(),
                  if (isDesktop) ...[
                    Expanded(
                      flex: 3,
                      child: Center(
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Text(
                              'Mac Pairing Code',
                              style: TextStyle(color: Colors.white70, fontSize: 16, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 16),
                            GlassCard(
                              opacity: 0.2,
                              borderRadius: 32,
                              child: Padding(
                                padding: const EdgeInsets.all(24.0),
                                child: QrImageView(
                                  data: _pairingCodeData,
                                  version: QrVersions.auto,
                                  size: 200.0,
                                  gapless: false,
                                  eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Colors.white),
                                  dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Colors.white),
                                ),
                              ),
                            ).animate().scale(duration: 600.ms, curve: Curves.elasticOut),
                            const SizedBox(height: 16),
                            const Text(
                              'Scan this from Android if Android is Sending',
                              style: TextStyle(color: Colors.white24, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16.0),
                      child: Text('OR', style: TextStyle(color: Colors.white24, fontWeight: FontWeight.bold)),
                    ),
                  ],
                  if (!isDesktop) ...[
                    Expanded(
                      flex: 3,
                      child: Center(
                        child: Container(
                          width: 280,
                          height: 280,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(40),
                            border: Border.all(color: Colors.white24, width: 2),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(40),
                            child: Stack(
                              children: [
                                MobileScanner(
                                  controller: MobileScannerController(
                                    facing: CameraFacing.back,
                                    torchEnabled: false,
                                  ),
                                  onDetect: _onDetect,
                                ),
                                // Radar Overlay
                                const Center(
                                  child: Icon(Icons.qr_code_scanner, size: 100, color: Colors.white12),
                                ).animate(onPlay: (c) => c.repeat())
                                 .shimmer(duration: 2.seconds),
                              ],
                            ),
                          ),
                        ).animate().scale(duration: 600.ms, curve: Curves.easeOutBack),
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32.0),
                      child: Text('OR', style: TextStyle(color: Colors.white24, fontWeight: FontWeight.bold)),
                    ),
                  ],
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 32.0, vertical: 40),
                    child: GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(24.0),
                        child: Column(
                          children: [
                            Text(
                              'Enter 6-Digit Code',
                              style: GoogleFonts.outfit(
                                fontSize: 18,
                                color: Colors.white70,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 24),
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: List.generate(6, (index) {
                                return SizedBox(
                                  width: 40,
                                  child: TextField(
                                    controller: _digitControllers[index],
                                    focusNode: _focusNodes[index],
                                    textAlign: TextAlign.center,
                                    keyboardType: TextInputType.number,
                                    maxLength: 1,
                                    style: const TextStyle(fontSize: 22, color: Color(0xFF03DAC6), fontWeight: FontWeight.bold),
                                    decoration: InputDecoration(
                                      counterText: '',
                                      enabledBorder: UnderlineInputBorder(borderSide: BorderSide(color: Colors.white24)),
                                      focusedBorder: UnderlineInputBorder(borderSide: BorderSide(color: Color(0xFF03DAC6))),
                                    ),
                                    onChanged: (value) {
                                      if (value.isNotEmpty && index < 5) {
                                        _focusNodes[index + 1].requestFocus();
                                      } else if (value.isEmpty && index > 0) {
                                        _focusNodes[index - 1].requestFocus();
                                      }
                                      if (_digitControllers.every((c) => c.text.isNotEmpty)) {
                                        _handleCodeEntry();
                                      }
                                    },
                                  ),
                                );
                              }),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.1, end: 0),
                  const SizedBox(height: 16),
                  
                  // Radar UI 
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 32.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Row(
                            children: [
                              Icon(Icons.radar, color: Colors.white54, size: 20),
                              SizedBox(width: 8),
                              Text('Nearby Radar', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.bold)),
                            ],
                          ).animate(onPlay: (c) => c.repeat(reverse: true)).shimmer(duration: 3.seconds),
                          const SizedBox(height: 16),
                          Expanded(
                            child: ValueListenableBuilder<List<DiscoveredDevice>>(
                              valueListenable: DiscoveryService().discoveredDevices,
                              builder: (context, devices, _) {
                                if (devices.isEmpty) {
                                  return const Center(child: Text('Scanning local network...', style: TextStyle(color: Colors.white24)));
                                }
                                return ListView.builder(
                                  itemCount: devices.length,
                                  itemBuilder: (context, index) {
                                    final device = devices[index];
                                    return Card(
                                      color: Colors.white.withOpacity(0.05),
                                      margin: const EdgeInsets.only(bottom: 8),
                                      child: ListTile(
                                        leading: Icon(device.platform == 'macos' ? Icons.laptop_mac : Icons.phone_android, color: const Color(0xFF03DAC6)),
                                        title: Text(device.name, style: const TextStyle(color: Colors.white)),
                                        subtitle: Text(device.ip, style: const TextStyle(color: Colors.white54)),
                                        trailing: const Icon(Icons.flash_on, color: Color(0xFF03DAC6)),
                                        onTap: () => _connectToNearby(device),
                                      ),
                                    ).animate().fadeIn().slideX();
                                  },
                                );
                              },
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                ],
              ),
        ],
      ),
    );
  }
}
