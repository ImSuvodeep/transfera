import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'file_handler_stub.dart'
    if (dart.library.io) 'file_handler_native.dart'
    if (dart.library.html) 'file_handler_web.dart';

abstract class FileHandler {
  Future<int> open(String fileName, int size, {int chunkSize = 65536});
  void addChunk(Uint8List chunk);
  Future<String?> finalize();
  
  factory FileHandler() => getFileHandler();
}
