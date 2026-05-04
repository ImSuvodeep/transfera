import 'dart:convert';
import 'dart:typed_data';
import 'package:encrypt/encrypt.dart';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

class EncryptionService {
  /// Encrypts a chunk of data using AES-256-CBC.
  /// [keyString] should be 64 hex characters (32 bytes).
  /// [ivString] should be 32 hex characters (16 bytes).
  static Uint8List encryptChunk(Uint8List data, String keyString, String ivString, [int offset = 0]) {
    try {
      final key = Key(_parseHex(keyString));
      final baseIv = _parseHex(ivString);
      
      // Synchronize CTR counter by shifting the IV based on byte offset
      final shiftedIv = _shiftIv(baseIv, offset);
      final encrypter = Encrypter(AES(key, mode: AESMode.ctr));

      // Address sub-block misalignment for chunks that don't start cleanly on 16-byte boundaries
      int remainder = offset % 16;
      if (remainder != 0) {
        final paddedData = Uint8List(remainder + data.length);
        // Fill the dummy prefix with zeroes (they will be encrypted and then thrown away)
        paddedData.setRange(remainder, paddedData.length, data);
        
        final encrypted = encrypter.encryptBytes(paddedData, iv: IV(shiftedIv));
        // Strip the dummy prefix to return the perfectly aligned actual data
        return encrypted.bytes.sublist(remainder);
      } else {
        final encrypted = encrypter.encryptBytes(data, iv: IV(shiftedIv));
        return encrypted.bytes;
      }
    } catch (e) {
      throw Exception('Encryption failed: $e (Key len: ${keyString.length}, IV len: ${ivString.length})');
    }
  }

  /// Decrypts a chunk of data using AES-256-CBC.
  static Uint8List decryptChunk(Uint8List encryptedData, String keyString, String ivString, [int offset = 0]) {
    try {
      final key = Key(_parseHex(keyString));
      final baseIv = _parseHex(ivString);
      
      final shiftedIv = _shiftIv(baseIv, offset);
      final encrypter = Encrypter(AES(key, mode: AESMode.ctr));

      int remainder = offset % 16;
      if (remainder != 0) {
        final paddedData = Uint8List(remainder + encryptedData.length);
        paddedData.setRange(remainder, paddedData.length, encryptedData);
        
        final decrypted = encrypter.decryptBytes(Encrypted(paddedData), iv: IV(shiftedIv));
        return Uint8List.fromList(decrypted.sublist(remainder));
      } else {
        final decrypted = encrypter.decryptBytes(Encrypted(encryptedData), iv: IV(shiftedIv));
        return Uint8List.fromList(decrypted);
      }
    } catch (e) {
      throw Exception('Decryption failed: $e (Key len: ${keyString.length}, IV len: ${ivString.length})');
    }
  }

  /// Generates a random 64-character hex string (32 bytes).
  static String generateRandomKey() {
    final bytes = sha256.convert(utf8.encode(DateTime.now().toIso8601String() + (const Uuid().v4()))).bytes;
    return _convertBytesToHex(Uint8List.fromList(bytes));
  }

  /// Generates a random 32-character hex string (16 bytes).
  static String generateRandomIV() {
    final bytes = md5.convert(utf8.encode(DateTime.now().toIso8601String() + (const Uuid().v4()))).bytes;
    return _convertBytesToHex(Uint8List.fromList(bytes));
  }

  static String _convertBytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List _parseHex(String hex) {
    if (hex.length % 2 != 0) throw Exception('Invalid hex string');
    return Uint8List.fromList(List.generate(hex.length ~/ 2, (i) => int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16)));
  }

  /// Shallows copy and increments the IV bytes by the offset (in 16-byte blocks)
  static Uint8List _shiftIv(Uint8List baseIv, int offsetBytes) {
    final Uint8List shifted = Uint8List.fromList(baseIv);
    int blocks = offsetBytes ~/ 16;
    
    // Add blocks to the 16-byte BigEndian counter (last bytes of IV)
    for (int i = 15; i >= 0 && blocks > 0; i--) {
      int sum = shifted[i] + blocks;
      shifted[i] = sum & 0xFF;
      blocks = sum >> 8;
    }
    return shifted;
  }
}
