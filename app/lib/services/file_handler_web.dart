import 'dart:html' as html;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'file_handler.dart';

class WebFileHandler implements FileHandler {
  List<int> _buffer = [];
  String? _fileName;

  @override
  Future<int> open(String fileName, int size, {int chunkSize = 65536}) async {
    if (_fileName == fileName && _buffer.isNotEmpty) {
      debugPrint('[WEB-FILE] Resuming existing buffer for: $fileName (${_buffer.length} bytes)');
      int safeSize = _buffer.length - (_buffer.length % chunkSize);
      if (safeSize < _buffer.length) {
        _buffer.removeRange(safeSize, _buffer.length);
        debugPrint('[WEB-FILE] Truncated buffer to $safeSize bytes for chunk alignment.');
      }
      return _buffer.length;
    }
    _fileName = fileName;
    _buffer = [];
    debugPrint('[WEB-FILE] Prepared buffer for receiving: $fileName');
    return 0;
  }

  @override
  void addChunk(Uint8List chunk) {
    _buffer.addAll(chunk);
  }

  @override
  Future<String?> finalize() async {
    if (_fileName == null) return null;
    
    final blob = html.Blob([_buffer]);
    final url = html.Url.createObjectUrlFromBlob(blob);
    final anchor = html.document.createElement('a') as html.AnchorElement
      ..href = url
      ..style.display = 'none'
      ..download = _fileName!;
    
    html.document.body?.children.add(anchor);
    anchor.click();
    html.document.body?.children.remove(anchor);
    html.Url.revokeObjectUrl(url);
    
    _buffer = [];
    debugPrint('[WEB-FILE] Triggered browser download for: $_fileName');
    return null;
  }
}

FileHandler getFileHandler() => WebFileHandler();
