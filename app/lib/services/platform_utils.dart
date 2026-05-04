import 'package:flutter/foundation.dart';
import 'dart:io' as io;

class PlatformUtils {
  static bool get isWeb => kIsWeb;
  
  static String get operatingSystem {
    if (kIsWeb) return 'web';
    try {
      return io.Platform.operatingSystem;
    } catch (_) {
      return defaultTargetPlatform.toString().split('.').last;
    }
  }

  static bool get isMobile {
    if (kIsWeb) return false;
    try {
      return io.Platform.isAndroid || io.Platform.isIOS;
    } catch (_) {
      return false;
    }
  }

  static Stream<List<int>> getFileStream(String path, int start, [int? end]) {
    if (kIsWeb) throw UnsupportedError('Not supported on web');
    return io.File(path).openRead(start, end);
  }
}
