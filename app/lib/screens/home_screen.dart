import 'package:flutter/material.dart';
import '../widgets/premium_widgets.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:google_fonts/google_fonts.dart';
import '../widgets/debug_panel.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:file_picker/file_picker.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'sender_screen.dart';
import 'receiver_screen.dart';
import 'history_screen.dart';
import '../services/transfer_manager.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late StreamSubscription _intentDataStreamSubscription;
  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;

  @override
  void initState() {
    super.initState();
    _initDeepLinks();
    
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      _intentDataStreamSubscription = ReceiveSharingIntent.instance.getMediaStream().listen((value) {
        if (value.isNotEmpty) {
          _handleSharedMedia(value);
        }
      }, onError: (err) {
        debugPrint("getIntentDataStream error: $err");
      });

      ReceiveSharingIntent.instance.getInitialMedia().then((value) {
        if (value.isNotEmpty) {
          _handleSharedMedia(value);
        }
      });
    }
  }

  void _initDeepLinks() {
    _appLinks = AppLinks();

    _appLinks.getInitialLink().then((uri) {
      if (uri != null) _handleDeepLink(uri);
    });

    _linkSubscription = _appLinks.uriLinkStream.listen((uri) {
      _handleDeepLink(uri);
    });
  }

  void _handleDeepLink(Uri uri) {
    if (uri.scheme == 'transfera' || (uri.host == 'transfera.app' && uri.path.contains('receive'))) {
      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => ReceiverScreen(initialUri: uri),
        ),
      );
    }
  }

  void _handleSharedMedia(List<SharedMediaFile> media) {
    if (media.isNotEmpty) {
      final file = File(media.first.path);
      final bf = BatchFile(
        id: 'single-${DateTime.now().millisecondsSinceEpoch}',
        path: file.path.split('/').last,
        size: file.lengthSync(),
        lastModified: file.lastModifiedSync().millisecondsSinceEpoch,
        source: file,
      );
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => SenderScreen(files: [bf], rootName: file.path.split('/').last),
        ),
      );
    }
  }

  Future<void> _pickFile() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
    );

    if (result != null && result.files.isNotEmpty) {
      if (!mounted) return;
      final batchFiles = result.files.map((f) {
        final file = File(f.path!);
        return BatchFile(
          id: 'multi-${DateTime.now().millisecondsSinceEpoch}-${f.name}',
          path: f.name,
          size: f.size,
          lastModified: file.lastModifiedSync().millisecondsSinceEpoch,
          source: file,
        );
      }).toList();
      final rootName = result.files.length == 1
          ? result.files.first.name
          : '${result.files.length} files';
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => SenderScreen(files: batchFiles, rootName: rootName),
        ),
      );
    }
  }

  Future<void> _pickFolder() async {
    String? directoryPath = await FilePicker.platform.getDirectoryPath();

    if (directoryPath != null) {
      final dir = Directory(directoryPath);
      final rootName = dir.path.split('/').last;
      final List<BatchFile> batchFiles = [];
      
      // Recursively list all files
      final entities = dir.listSync(recursive: true);
      for (var entity in entities) {
        if (entity is File) {
          final relativePath = entity.path.substring(dir.path.length + 1);
          batchFiles.add(BatchFile(
            id: 'batch-${DateTime.now().millisecondsSinceEpoch}-${batchFiles.length}',
            path: relativePath,
            size: entity.lengthSync(),
            lastModified: entity.lastModifiedSync().millisecondsSinceEpoch,
            source: entity,
          ));
        }
      }

      if (batchFiles.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Selected folder is empty.')),
          );
        }
        return;
      }

      if (!mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (context) => SenderScreen(files: batchFiles, rootName: rootName),
        ),
      );
    }
  }

  @override
  void dispose() {
    if (!kIsWeb && (Platform.isAndroid || Platform.isIOS)) {
      _intentDataStreamSubscription.cancel();
    }
    _linkSubscription?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bool isDesktop = !kIsWeb && (Platform.isMacOS || Platform.isWindows);

    return Scaffold(
      body: Stack(
        children: [
          const AnimatedMeshGradient(),
          SafeArea(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // History button row
                  Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8.0),
                      child: IconButton(
                        icon: const Icon(Icons.history_rounded, color: Colors.white54),
                        tooltip: 'Transfer History',
                        onPressed: () {
                          Navigator.of(context).push(
                            MaterialPageRoute(builder: (_) => const HistoryScreen()),
                          );
                        },
                      ),
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onLongPress: () => DebugPanel.show(context),
                    child: Hero(
                      tag: 'app_logo',
                      child: Container(
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFBB86FC).withOpacity(0.3),
                              blurRadius: 40,
                              spreadRadius: 10,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.swap_horizontal_circle_outlined,
                          size: 100,
                          color: Color(0xFFBB86FC),
                        ),
                      ),
                    ).animate().scale(delay: 200.ms, duration: 600.ms, curve: Curves.easeOutBack),
                  ),
                  const SizedBox(height: 32),
                  Text(
                    'Transfera',
                    style: GoogleFonts.outfit(
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                      letterSpacing: -1.0,
                    ),
                  ).animate().fadeIn(delay: 400.ms).slideY(begin: 0.2, end: 0),
                  const SizedBox(height: 8),
                  Text(
                    'Secure. Fast. Effortless.',
                    style: TextStyle(
                      color: Colors.white.withOpacity(0.6),
                      fontSize: 18,
                      letterSpacing: 0.5,
                    ),
                  ).animate().fadeIn(delay: 600.ms),
                  const Spacer(),
                  GlassCard(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Column(
                        children: [
                          ElevatedButton.icon(
                            onPressed: () {
                              Navigator.of(context).push(
                                MaterialPageRoute(builder: (context) => const ReceiverScreen()),
                              );
                            },
                            icon: const Icon(Icons.qr_code_scanner),
                            label: const Text('Receive File'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white,
                              foregroundColor: Colors.black,
                              elevation: 0,
                            ),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: _pickFile,
                            icon: const Icon(Icons.file_upload_outlined),
                            label: const Text('Send Files'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white.withOpacity(0.05),
                              foregroundColor: Colors.white,
                              elevation: 0,
                            ),
                          ),
                          const SizedBox(height: 16),
                          ElevatedButton.icon(
                            onPressed: _pickFolder,
                            icon: const Icon(Icons.folder_open_outlined),
                            label: const Text('Send a Folder'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.white.withOpacity(0.05),
                              foregroundColor: Colors.white,
                              elevation: 0,
                            ),
                          ),
                          const SizedBox(height: 16),
                          if (isDesktop)
                            Text(
                              'Drop files to begin',
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.3),
                                fontSize: 13,
                              ),
                            )
                          else
                            Text(
                              'Or share a file from another app',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: Colors.white.withOpacity(0.3),
                                fontSize: 13,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ).animate().fadeIn(delay: 800.ms).slideY(begin: 0.1, end: 0),
                  const SizedBox(height: 48),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
