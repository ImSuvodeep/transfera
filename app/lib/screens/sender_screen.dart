import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:qr_flutter/qr_flutter.dart';
import 'package:uuid/uuid.dart';
import 'package:flutter/foundation.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:cross_file/cross_file.dart';
import '../services/webrtc_service.dart';
import '../services/encryption_service.dart';
import '../services/transfer_manager.dart';
import '../services/share_link_service.dart';
import '../widgets/premium_widgets.dart';
import '../widgets/route_indicator.dart';
import '../config.dart';
import 'package:flutter_animate/flutter_animate.dart';
import '../services/discovery_service.dart';
import '../services/tcp_transport_service.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

class SenderScreen extends StatefulWidget {
  final List<BatchFile> files;
  final String rootName;
  const SenderScreen({super.key, required this.files, required this.rootName});

  @override
  State<SenderScreen> createState() => _SenderScreenState();
}

class _SenderScreenState extends State<SenderScreen> {
  late String sessionId;
  late String encryptionKey;
  late String encryptionIv;
  late WebRTCService webrtc;
  late TransferManager transferManager;
  late TcpTransportService tcpTransport;
  
  bool isReceiverJoined = false;
  bool isEncrypted = false;
  bool showQr = false;
  bool isScanning = false;
  bool _sendFileStarted = false; // Guard: prevents double sendFile from TCP + WebRTC both firing
  String connectionStatus = 'Connecting to server...';
  double progress = 0.0;
  String? transferCode;

  // ── Share Link state ──
  bool _isUploadingShare = false;
  double _shareUploadProgress = 0.0;
  String? _shareUrl;
  String? _shareError;

  String _localIps = "";

  @override
  void initState() {
    super.initState();
    // CRITICAL: All synchronous service objects must be created BEFORE calling
    // _initTransfer() which is async and references them immediately.
    sessionId = const Uuid().v4();
    encryptionKey = EncryptionService.generateRandomKey();
    encryptionIv = EncryptionService.generateRandomIV();

    // Use centralized configuration for signaling
    final signalingUrl = AppConfig.signalingUrl;
    webrtc = WebRTCService(signalingUrl: signalingUrl);
    tcpTransport = TcpTransportService();

    transferManager = TransferManager(
      webrtc: webrtc,
      tcpTransport: tcpTransport,
      encryptionKey: encryptionKey,
      encryptionIv: encryptionIv,
      sessionId: sessionId,
    );

    // Now safe to call — tcpTransport is the correct instance
    _initTransfer();
  }

  Future<void> _initTransfer() async {
    await _gatherLocalIps();
    final port = await tcpTransport.startServer();
    DiscoveryService().updateTcpPort(port);
    DiscoveryService().start(port);
    debugPrint('[SENDER] TCP Server started on port $port, Discovery beacon updated.');
    
    if (mounted) {
      setState(() {}); // Render QR code with complete payload
    }

    // Register for signaling immediately for remote transfer
    debugPrint('[SENDER] Registering for remote transfer.');
    webrtc.start(
      sessionId, 
      true, 
      encryptionKey: encryptionKey, 
      encryptionIv: encryptionIv
    );

    tcpTransport.onStatus.listen((status) async {
      if (status == 'connected' && !_sendFileStarted) {
        _sendFileStarted = true;
        debugPrint('[SENDER] TCP Direct Link established — using Local path (no relay).');
        if (mounted) {
          setState(() {
            isReceiverJoined = true;
            connectionStatus = 'Local Direct Link Active...';
          });
        }
        try {
          await transferManager.startBatchTransfer(widget.files);
        } catch (e) {
          debugPrint('[SENDER] TCP Error: $e');
        }
      }
    });

    webrtc.onCodeGenerated = (code) {
      if (mounted) setState(() => transferCode = code);
    };

    webrtc.onReceiverJoined = () async {
      debugPrint('[SENDER] Receiver joined via signaling.');
      if (mounted) {
        setState(() {
          isReceiverJoined = true;
          connectionStatus = 'Receiver connected — starting...';
        });
      }
      // Wait briefly to see if local TCP connects first (faster path)
      await Future.delayed(const Duration(milliseconds: 2500));
      if (_sendFileStarted) {
        debugPrint('[SENDER] TCP already handling transfer. Relay standby.');
        return;
      }
      _sendFileStarted = true;
      try {
        if (mounted) setState(() => connectionStatus = 'Sending via Relay...');
        await transferManager.startBatchTransfer(widget.files);
      } catch (e) {
        debugPrint('[SENDER] Relay send error: $e');
        if (mounted) setState(() => connectionStatus = 'Link failed. Retrying...');
      }
    };

    transferManager.progressController.stream.listen((val) {
      if (mounted) setState(() => progress = val);
    });

    // (WebRTC started in _initTransfer)

    // Initial animation sequence
    Future.delayed(1500.ms, () {
      if (mounted) setState(() => isEncrypted = true);
    });
    Future.delayed(2500.ms, () {
      if (mounted) setState(() => showQr = true);
    });
  }

  void _onDetect(BarcodeCapture capture) {
    if (!isScanning) return;
    
    final List<Barcode> barcodes = capture.barcodes;
    for (final barcode in barcodes) {
      final code = barcode.rawValue;
      if (code != null && (code.startsWith('https://transfera.app/receive?d=') || code.startsWith('transfera://receive?d='))) {
        if (mounted) setState(() => isScanning = false);
        try {
          final uri = Uri.parse(code);
          final base64Data = uri.queryParameters['d'];
          if (base64Data != null) {
            final jsonStr = utf8.decode(base64Url.decode(base64Data));
            final data = json.decode(jsonStr);
            final newUrl = data['url'];
            if (newUrl != null && newUrl.toString().isNotEmpty) {
              AppConfig.updateRemoteUrl(newUrl);
              webrtc.signalingUrl = newUrl;
              webrtc.start(
                sessionId, 
                true, 
                encryptionKey: encryptionKey, 
                encryptionIv: encryptionIv
              );
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Found Pairing Code! Connecting...')),
              );
            }
          }
        } catch (_) {}
        break;
      }
    }
  }

  // ── Share Link generation ───────────────────────────────────────────────────
  Future<void> _generateShareLink() async {
    if (_isUploadingShare) return;
    setState(() {
      _isUploadingShare = true;
      _shareUploadProgress = 0.0;
      _shareUrl = null;
      _shareError = null;
    });

    try {
      final service = ShareLinkService();
      // BatchFile.path is just the transfer filename — use .source for the real filesystem path
      final xFiles = widget.files
          .where((bf) => bf.source != null)
          .map((bf) => XFile((bf.source as File).path))
          .toList();

      if (xFiles.isEmpty) {
        throw Exception('No accessible files to upload.');
      }

      String shareUrl;
      if (xFiles.length == 1) {
        final result = await service.uploadFile(
          xFiles.first,
          onProgress: (p) {
            if (mounted) setState(() => _shareUploadProgress = p);
          },
        );
        shareUrl = service.buildSharePageUrl(
          directLink: result.directLink,
          fileName: result.fileName,
          fileSizeBytes: result.fileSizeBytes,
        );
      } else {
        shareUrl = await service.uploadBatchAndGetShareUrl(
          files: xFiles,
          folderName: widget.rootName,
          onProgress: (p) {
            if (mounted) setState(() => _shareUploadProgress = p);
          },
        );
      }


      if (mounted) setState(() => _shareUrl = shareUrl);
    } catch (e) {
      debugPrint('[SHARE] Upload error: $e');
      if (mounted) setState(() => _shareError = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _isUploadingShare = false);
    }
  }

  @override
  void dispose() {
    webrtc.dispose();
    transferManager.dispose();
    tcpTransport.dispose();
    DiscoveryService().stop();
    super.dispose();
  }

  String get _qrData {
    final tunnelUrl = AppConfig.remoteUrl;
    final data = {
      'sid': sessionId,
      'key': encryptionKey,
      'iv': encryptionIv,
      'url': tunnelUrl,
      'tcpP': tcpTransport.isServer ? tcpTransport.port : 0,
      'ips': _localIps,
    };
    final jsonStr = json.encode(data);
    final base64Data = base64Url.encode(utf8.encode(jsonStr));
    return 'https://transfera.app/receive?d=$base64Data';
  }

  Future<void> _gatherLocalIps() async {
    try {
      final interfaces = await NetworkInterface.list();
      final ips = interfaces
          .expand((i) => i.addresses)
          .where((a) => a.type == InternetAddressType.IPv4)
          .map((a) => a.address)
          .toList();
      _localIps = ips.join(',');
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: Text(isReceiverJoined ? 'Sending...' : 'Ready to Send'),
      ),
      body: Stack(
        children: [
          const AnimatedMeshGradient(),
          SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(32, 100, 32, 48),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (isScanning)
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 40),
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
                                  controller: MobileScannerController(facing: CameraFacing.back, torchEnabled: false),
                                  onDetect: _onDetect,
                                ),
                                const Center(
                                  child: Icon(Icons.qr_code_scanner, size: 100, color: Colors.white12),
                                ).animate(onPlay: (c) => c.repeat()).shimmer(duration: 2.seconds),
                                Positioned(
                                  top: 16, left: 16,
                                  child: IconButton(
                                    icon: const Icon(Icons.close, color: Colors.white),
                                    onPressed: () => setState(() => isScanning = false),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    )
                  else if (!isReceiverJoined) ...[
                    Stack(
                      alignment: Alignment.center,
                      children: [
                        // Encryption Ring
                        if (isEncrypted)
                          Container(
                            width: 240,
                            height: 240,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: const Color(0xFFBB86FC).withOpacity(0.5),
                                width: 2,
                              ),
                            ),
                          )
                          .animate()
                          .scale(duration: 400.ms, curve: Curves.easeOut)
                          .custom(
                            duration: 2.seconds,
                            builder: (context, value, child) => RotationTransition(
                              turns: AlwaysStoppedAnimation(value),
                              child: child,
                            ),
                          )
                          .then()
                          .fadeOut(),

                        // File Icon / Thumbnail
                        if (!showQr)
                          Column(
                            children: [
                              Container(
                                width: 120,
                                height: 120,
                                decoration: BoxDecoration(
                                  color: Colors.white.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(24),
                                ),
                                child: Icon(
                                  widget.files.length == 1 ? Icons.insert_drive_file_outlined : Icons.folder_open_outlined, 
                                  size: 48, 
                                  color: Colors.white
                                ),
                              )
                              .animate()
                              .scale(duration: 600.ms, curve: Curves.easeOutBack)
                              .shimmer(delay: 800.ms, colors: [Colors.transparent, Colors.white24, Colors.transparent])
                              .blur(begin: const Offset(0, 0), end: isEncrypted ? const Offset(10, 10) : const Offset(0, 0), delay: 1000.ms),
                              const SizedBox(height: 24),
                              Text(
                                widget.files.length == 1 ? widget.rootName : 'Sending Folder: ${widget.rootName} (${widget.files.length} files)',
                                style: const TextStyle(fontWeight: FontWeight.w600, color: Colors.white70),
                              ).animate().fadeIn(delay: 400.ms),
                            ],
                          ).animate(target: showQr ? 1 : 0).fadeOut(duration: 400.ms),

                        // QR Code & Code Expansion
                        if (showQr)
                          Column(
                            children: [
                              GlassCard(
                                opacity: 0.2,
                                borderRadius: 32,
                                child: Padding(
                                  padding: const EdgeInsets.all(24.0),
                                  child: QrImageView(
                                    data: _qrData,
                                    version: QrVersions.auto,
                                    size: 240.0,
                                    gapless: false,
                                    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.circle, color: Colors.white),
                                    dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.circle, color: Colors.white),
                                  ),
                                ),
                              ).animate().scale(duration: 600.ms, curve: Curves.elasticOut),
                              
                              if (transferCode != null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 24.0),
                                  child: Column(
                                    children: [
                                      Text(
                                        'TRANSFER KEY',
                                        style: GoogleFonts.outfit(
                                          fontSize: 12,
                                          fontWeight: FontWeight.bold,
                                          color: Colors.white24,
                                          letterSpacing: 2,
                                        ),
                                      ),
                                      const SizedBox(height: 12),
                                      Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: transferCode!.split('').map((digit) {
                                          return Container(
                                            margin: const EdgeInsets.symmetric(horizontal: 4),
                                            width: 36,
                                            height: 48,
                                            decoration: BoxDecoration(
                                              color: Colors.white.withOpacity(0.05),
                                              borderRadius: BorderRadius.circular(8),
                                              border: Border.all(color: Colors.white10),
                                            ),
                                            alignment: Alignment.center,
                                            child: Text(
                                              digit,
                                              style: GoogleFonts.outfit(
                                                fontSize: 24,
                                                fontWeight: FontWeight.bold,
                                                color: const Color(0xFFBB86FC),
                                              ),
                                            ),
                                          ).animate().fadeIn(delay: 200.ms).slideY(begin: 0.2, end: 0);
                                        }).toList(),
                                      ),
                                      // ── Share via Link ───────────────────
                                      const SizedBox(height: 24),
                                      Row(
                                        children: [
                                          Expanded(child: Divider(color: Colors.white12)),
                                          Padding(
                                            padding: const EdgeInsets.symmetric(horizontal: 12),
                                            child: Text(
                                              'OR SHARE A LINK',
                                              style: GoogleFonts.outfit(
                                                fontSize: 10,
                                                color: Colors.white24,
                                                letterSpacing: 1.5,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          Expanded(child: Divider(color: Colors.white12)),
                                        ],
                                      ),
                                      const SizedBox(height: 16),

                                      // Upload progress / button / result
                                      if (_shareUrl != null) ..._buildShareResult()
                                      else if (_isUploadingShare) _buildShareProgress()
                                      else if (_shareError != null) _buildShareError()
                                      else _buildShareButton(),
                                    ],
                                  ),
                                )
                              else
                                ValueListenableBuilder<bool>(
                                  valueListenable: webrtc.isSocketConnected,
                                  builder: (context, isConnected, _) {
                                    return Padding(
                                      padding: const EdgeInsets.only(top: 24.0),
                                      child: Text(
                                        isConnected ? 'Generating Key...' : 'Connecting to Server...',
                                        style: TextStyle(color: Colors.white.withOpacity(0.3), letterSpacing: 1.2),
                                      ),
                                    );
                                  },
                                ),
                            ],
                          ).animate().shimmer(delay: 1000.ms, duration: 2.seconds),
                      ],
                    ),
                    // Status Text
              ValueListenableBuilder<bool>(
                valueListenable: webrtc.isSocketConnected,
                builder: (context, isConnected, _) {
                  String status = isConnected ? connectionStatus : 'Syncing with Signaling Tunnel...';
                  if (status == 'Connecting to server...') status = 'Ready for Pairing';
                  
                  return Text(
                    status,
                    style: TextStyle(
                      color: isConnected ? const Color(0xFFBB86FC) : Colors.white.withOpacity(0.7),
                      fontSize: 14,
                      fontWeight: isConnected ? FontWeight.bold : FontWeight.normal,
                    ),
                  );
                },
              ),
              const SizedBox(height: 48),
                  ] else ...[
                    // Transferring State
                    ValueListenableBuilder<String>(
                      valueListenable: transferManager.route,
                      builder: (context, currentRoute, _) {
                        if (currentRoute == 'Relay') {
                          return Container(
                            margin: const EdgeInsets.only(bottom: 24),
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                            decoration: BoxDecoration(
                              color: Colors.orange.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(color: Colors.orange.withOpacity(0.2)),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(Icons.speed, color: Colors.orange, size: 16),
                                const SizedBox(width: 8),
                                Text(
                                  'Slow Mode Active: WiFi is weak or firewalled',
                                  style: GoogleFonts.outfit(color: Colors.orange, fontSize: 12),
                                ),
                              ],
                            ),
                          ).animate().fadeIn().shake();
                        }
                        return const SizedBox.shrink();
                      },
                    ),
                    GlassCard(
                      child: Padding(
                        padding: const EdgeInsets.all(40.0),
                        child: Column(
                          children: [
                            Stack(
                              alignment: Alignment.center,
                              children: [
                                SizedBox(
                                  width: 140,
                                  height: 140,
                                  child: CircularProgressIndicator(
                                    value: progress,
                                    strokeWidth: 4,
                                    backgroundColor: Colors.white10,
                                    color: const Color(0xFFBB86FC),
                                  ),
                                ),
                                const Icon(Icons.rocket_launch_outlined, size: 48, color: Color(0xFFBB86FC))
                                  .animate(onPlay: (c) => c.repeat())
                                  .shimmer(duration: 2.seconds),
                              ],
                            ),
                            const SizedBox(height: 32),
                            Text(
                              '${(progress * 100).toInt()}%',
                              style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
                            ),
                            const SizedBox(height: 12),
                            RouteIndicator(routeNotifier: transferManager.route),
                            const SizedBox(height: 8),
                            if (transferManager.totalFiles > 1)
                              Text('File ${transferManager.currentFileIndex} of ${transferManager.totalFiles}\n${transferManager.currentFileName}', 
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.grey, fontSize: 12))
                            else
                              const Text('Encrypting & Sending', style: TextStyle(color: Colors.grey)),
                          ],
                        ),
                      ),
                    ).animate().fadeIn().scale(curve: Curves.easeOutBack),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Share Link helper widgets ──────────────────────────────────────────────

  Widget _buildShareButton() {
    return GestureDetector(
      onTap: _generateShareLink,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            colors: [
              const Color(0xFFBB86FC).withOpacity(0.12),
              const Color(0xFF03DAC6).withOpacity(0.08),
            ],
          ),
          border: Border.all(color: const Color(0xFFBB86FC).withOpacity(0.25)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.link_rounded, color: Color(0xFFBB86FC), size: 18),
            const SizedBox(width: 10),
            Text(
              'Generate Share Link',
              style: GoogleFonts.outfit(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: const Color(0xFFBB86FC),
              ),
            ),
          ],
        ),
      ),
    ).animate().fadeIn(delay: 300.ms);
  }

  Widget _buildShareProgress() {
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: _shareUploadProgress,
            minHeight: 4,
            backgroundColor: Colors.white10,
            color: const Color(0xFF03DAC6),
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Uploading… ${(_shareUploadProgress * 100).toInt()}%',
          style: GoogleFonts.outfit(
            fontSize: 12,
            color: Colors.white38,
          ),
        ),
      ],
    );
  }

  Widget _buildShareError() {
    return Column(
      children: [
        Text(
          _shareError ?? 'Upload failed.',
          style: GoogleFonts.outfit(fontSize: 12, color: Colors.redAccent),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        GestureDetector(
          onTap: _generateShareLink,
          child: Text(
            'Retry',
            style: GoogleFonts.outfit(
              fontSize: 12,
              color: const Color(0xFFBB86FC),
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ],
    );
  }

  List<Widget> _buildShareResult() {
    final url = _shareUrl!;
    return [
      // URL display box
      Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withOpacity(0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white10),
        ),
        child: SelectableText(
          url,
          style: GoogleFonts.outfit(
            fontSize: 11,
            color: const Color(0xFF03DAC6),
          ),
          maxLines: 3,
        ),
      ),
      const SizedBox(height: 10),
      Row(
        children: [
          // Copy button
          Expanded(
            child: GestureDetector(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: url));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Link copied to clipboard!'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFFBB86FC).withOpacity(0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFFBB86FC).withOpacity(0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.copy_rounded, size: 15, color: Color(0xFFBB86FC)),
                    const SizedBox(width: 6),
                    Text(
                      'Copy',
                      style: GoogleFonts.outfit(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFFBB86FC),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          // Share via OS sheet
          Expanded(
            child: GestureDetector(
              onTap: () {
                // Use share_plus if added; for now fall back to clipboard
                Clipboard.setData(ClipboardData(text: url));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Link ready to paste & share!'),
                      duration: Duration(seconds: 2),
                    ),
                  );
                }
              },
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: const Color(0xFF03DAC6).withOpacity(0.10),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF03DAC6).withOpacity(0.2)),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const Icon(Icons.ios_share_rounded, size: 15, color: Color(0xFF03DAC6)),
                    const SizedBox(width: 6),
                    Text(
                      'Share',
                      style: GoogleFonts.outfit(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: const Color(0xFF03DAC6),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    ];
  }
}

