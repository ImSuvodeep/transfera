import 'dart:io';
import 'package:flutter/foundation.dart';

class WindowsRegistryService {
  /// Registers the transfera:// custom protocol for Windows.
  static Future<void> registerProtocol() async {
    if (kIsWeb || !Platform.isWindows) return;

    try {
      // Get the path of the current executable
      final exePath = Platform.resolvedExecutable;
      
      // We use PowerShell to add the registry keys as it's cleaner than FFI for simple tasks
      // Protocol key: HKEY_CURRENT_USER\Software\Classes\transfera
      final script = '''
        \$Path = "HKCU:\\Software\\Classes\\transfera"
        if (-not (Test-Path \$Path)) { New-Item -Path \$Path -Force }
        New-ItemProperty -Path \$Path -Name "(Default)" -Value "URL:Transfera Protocol" -PropertyType String -Force
        New-ItemProperty -Path \$Path -Name "URL Protocol" -Value "" -PropertyType String -Force
        
        \$CommandPath = "HKCU:\\Software\\Classes\\transfera\\shell\\open\\command"
        if (-not (Test-Path \$CommandPath)) { New-Item -Path \$CommandPath -Force }
        New-ItemProperty -Path \$CommandPath -Name "(Default)" -Value '"$exePath" "%1"' -PropertyType String -Force
      ''';

      await Process.run('powershell', ['-Command', script]);
      print('Windows Protocol Registered Successfully');
    } catch (e) {
      print('Failed to register Windows protocol: $e');
    }
  }
}
