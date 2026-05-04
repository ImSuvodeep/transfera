import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:cross_file/cross_file.dart';
import '../config.dart';

/// Result of a successful upload.
class ShareUploadResult {
  /// True direct download URL from litterbox.
  final String directLink;
  final String fileName;
  final int fileSizeBytes;

  ShareUploadResult({
    required this.directLink,
    required this.fileName,
    required this.fileSizeBytes,
  });
}

/// Uploads files to litterbox.catbox.moe and generates a Transfera share link.
///
/// Key behaviours:
///   • Single file  → uploaded as-is, direct link returned.
///   • Multiple files (folder) → zipped in memory first → single zip uploaded.
///   • The landing page's "Download File" button is routed through the server's
///     /proxy endpoint so the browser forces a download instead of previewing.
class ShareLinkService {
  static const String _uploadUrl =
      'https://litterbox.catbox.moe/resources/internals/api.php';
  static const String _expiry = '72h';

  // ---------------------------------------------------------------------------
  // Upload a single file — returns a direct download URL from litterbox
  // ---------------------------------------------------------------------------
  Future<ShareUploadResult> uploadFile(
    XFile file, {
    void Function(double progress)? onProgress,
  }) async {
    final fileName = file.path.split('/').last.split('\\').last;
    debugPrint('[SHARE] Uploading "$fileName" to litterbox ...');

    onProgress?.call(0.05);
    final fileBytes = await file.readAsBytes();
    onProgress?.call(0.30);

    final directUrl = await _uploadBytes(fileBytes, fileName, onProgress);

    return ShareUploadResult(
      directLink: directUrl,
      fileName: fileName,
      fileSizeBytes: fileBytes.length,
    );
  }

  // ---------------------------------------------------------------------------
  // Upload a folder — zips all files in memory, then uploads one zip
  // ---------------------------------------------------------------------------
  Future<String> uploadBatchAndGetShareUrl({
    required List<XFile> files,
    required String folderName,
    void Function(double totalProgress)? onProgress,
  }) async {
    debugPrint('[SHARE] Zipping ${files.length} files into "$folderName.zip" ...');
    onProgress?.call(0.05);

    // ── Build zip in memory ──────────────────────────────────────────────────
    final archive = Archive();
    int totalBytes = 0;
    int readBytes  = 0;

    // Pre-read all files
    final List<({String name, Uint8List bytes})> fileData = [];
    for (final f in files) {
      final name  = f.path.split('/').last.split('\\').last;
      final bytes = await f.readAsBytes();
      totalBytes += bytes.length;
      fileData.add((name: name, bytes: bytes));
    }

    for (final fd in fileData) {
      archive.addFile(ArchiveFile(fd.name, fd.bytes.length, fd.bytes));
      readBytes += fd.bytes.length;
      // Progress 5% → 40% for zipping phase
      onProgress?.call(0.05 + (readBytes / totalBytes) * 0.35);
    }

    // Encode to zip bytes
    final zipBytes = Uint8List.fromList(ZipEncoder().encode(archive)!);
    final zipName  = '${folderName.replaceAll(RegExp(r'[^a-zA-Z0-9._-]'), '_')}.zip';
    debugPrint('[SHARE] Zip ready: ${zipBytes.length} bytes → $zipName');

    // ── Upload the zip ───────────────────────────────────────────────────────
    final directUrl = await _uploadBytes(
      zipBytes,
      zipName,
      (p) => onProgress?.call(0.40 + p * 0.60), // Progress 40% → 100%
    );

    return buildSharePageUrl(
      directLink: directUrl,
      fileName: '$folderName (${files.length} files)',
      fileSizeBytes: zipBytes.length,
      fileCount: files.length,
    );
  }

  // ---------------------------------------------------------------------------
  // Internal: upload raw bytes to litterbox, return direct URL
  // ---------------------------------------------------------------------------
  Future<String> _uploadBytes(
    Uint8List bytes,
    String fileName,
    void Function(double)? onProgress,
  ) async {
    final request = http.MultipartRequest('POST', Uri.parse(_uploadUrl))
      ..fields['reqtype'] = 'fileupload'
      ..fields['time']    = _expiry
      ..files.add(
        http.MultipartFile.fromBytes(
          'fileToUpload',
          bytes,
          filename: fileName,
        ),
      );

    onProgress?.call(0.50);
    final streamed = await request.send().timeout(const Duration(minutes: 30));
    final url = (await streamed.stream.bytesToString()).trim();

    if (streamed.statusCode != 200 || !url.startsWith('http')) {
      throw Exception('Upload failed (${streamed.statusCode}): $url');
    }

    onProgress?.call(1.0);
    debugPrint('[SHARE] ✓ Uploaded → $url');
    return url;
  }

  // ---------------------------------------------------------------------------
  // Build the Transfera landing page URL
  // The `dl` param is routed through /proxy on our server so browsers
  // force-download instead of previewing images/videos inline.
  // ---------------------------------------------------------------------------
  String buildSharePageUrl({
    required String directLink,
    required String fileName,
    required int fileSizeBytes,
    int fileCount = 1,
  }) {
    final base = AppConfig.remoteUrl.isNotEmpty
        ? AppConfig.remoteUrl
        : AppConfig.signalingUrl;

    // Route download through our proxy endpoint (forces Content-Disposition: attachment)
    final proxyUrl = '$base/proxy?url=${Uri.encodeComponent(directLink)}&name=${Uri.encodeComponent(fileName)}';

    final params = Uri(queryParameters: {
      'dl':    proxyUrl,
      'name':  fileName,
      'size':  fileSizeBytes.toString(),
      'count': fileCount.toString(),
    });

    return '$base/share?${params.query}';
  }
}
