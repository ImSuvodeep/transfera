import 'dart:io';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';
import 'file_handler.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';

class NativeFileHandler implements FileHandler {
  IOSink? _sink;
  String? _path;

  @override
  Future<int> open(String fileName, int size, {int chunkSize = 65536}) async {
    if (_sink != null) {
      debugPrint('[NATIVE-FILE] Sink already open. Flushing and closing before resume check.');
      await _sink!.flush();
      await _sink!.close();
      _sink = null;
    }

    final directory = await _getDownloadDirectory();
    _path = '${directory.path}/$fileName';
    final file = File(_path!);
    
    // Create parent directories if they don't exist
    final parentDir = file.parent;
    if (!(await parentDir.exists())) {
      await parentDir.create(recursive: true);
    }
    
    if (await file.exists()) {
      final existingSize = await file.length();
      if (existingSize < size) {
        // Safe Rewind: Truncate to the nearest confirmed chunk boundary to erase OS write-buffer garbage
        int safeSize = existingSize - (existingSize % chunkSize);
        if (safeSize < existingSize) {
           debugPrint('[NATIVE-FILE] Truncating ${existingSize - safeSize} garbage bytes for safe chunk alignment.');
           final randomAccess = await file.open(mode: FileMode.append);
           await randomAccess.truncate(safeSize);
           await randomAccess.close();
        }
        debugPrint('[NATIVE-FILE] Found existing file. Resuming from $safeSize bytes.');
        _sink = file.openWrite(mode: FileMode.append);
        return safeSize;
      } else {
        debugPrint('[NATIVE-FILE] Existing file is full size. Deleting for fresh transfer.');
        await file.delete();
      }
    }

    _sink = file.openWrite(mode: FileMode.write);
    return 0;
  }

  @override
  void addChunk(Uint8List chunk) {
    _sink?.add(chunk);
  }

  @override
  Future<String?> finalize() async {
    await _sink?.flush();
    await _sink?.close();
    _sink = null;
    debugPrint('[NATIVE-FILE] Finalized file: $_path');

    if (_path != null && (Platform.isAndroid || Platform.isIOS)) {
      final ext = _path!.split('.').last.toLowerCase();
      final isImage = ['jpg', 'jpeg', 'png', 'gif', 'heic', 'webp'].contains(ext);
      final isVideo = ['mp4', 'mov', 'avi', 'mkv', 'webm'].contains(ext);
      
      if (isImage || isVideo) {
        try {
          final nameWithoutExt = _path!.split('/').last.split('.').first;
          if (Platform.isAndroid) {
            // image_gallery_saver will actually copy the file. For very large videos, this is slow.
            // But it's the most reliable way to make it show in Android Gallery.
            final result = await ImageGallerySaver.saveFile(_path!, name: nameWithoutExt);
            if (result['isSuccess'] == true) {
               debugPrint('[NATIVE-FILE] Auto-saved directly to Photos/Gallery via image_gallery_saver!');
            } else {
               debugPrint('[NATIVE-FILE] Failed to save to gallery: $result');
            }
          } else if (Platform.isIOS) {
            final result = await ImageGallerySaver.saveFile(_path!, name: nameWithoutExt);
            if (result['isSuccess'] == true) {
               debugPrint('[NATIVE-FILE] Auto-saved directly to Photos/Gallery via image_gallery_saver!');
            }
          }
        } catch (e) {
          debugPrint('[NATIVE-FILE] Failed to save to gallery exception: $e');
        }
      }
    }
    
    return _path;
  }

  Future<Directory> _getDownloadDirectory() async {
    Directory? directory;
    if (Platform.isMacOS) {
      directory = await getDownloadsDirectory();
    } else if (Platform.isWindows || Platform.isLinux) {
      directory = await getDownloadsDirectory();
    } else if (Platform.isAndroid) {
      // Ensure we have permissions before attempting public storage writes
      await Permission.storage.request();
      if (await Permission.manageExternalStorage.status.isDenied) {
        await Permission.manageExternalStorage.request();
      }
      if (await Permission.photos.status.isDenied) await Permission.photos.request();
      if (await Permission.videos.status.isDenied) await Permission.videos.request();

      // First choice: External Downloads folder (standard)
      try {
        directory = Directory('/storage/emulated/0/Download/Transfera');
        if (!await directory.exists()) {
          await directory.create(recursive: true);
        }
        // Test write access to catch Android 13+ permission issues early
        final testFile = File('${directory!.path}/.write_test');
        await testFile.writeAsString('test');
        await testFile.delete();
      } catch (e) {
        debugPrint('[NATIVE-FILE] Downloads folder not writable ($e). Using app storage.');
        directory = await getExternalStorageDirectory();
      }
    }
    directory ??= await getApplicationDocumentsDirectory();
    if (!await directory.exists()) await directory.create(recursive: true);
    return directory;
  }
}

FileHandler getFileHandler() => NativeFileHandler();
