import 'dart:io';

void main() async {
  File f = File('test.txt');
  await f.writeAsString('hello world this is a test');
  final stream = f.openRead(0, 5);
  final bytes = <int>[];
  await for (final part in stream) {
    bytes.addAll(part);
  }
  print('Read bytes: ${bytes.length}');
  print('Content: ${String.fromCharCodes(bytes)}');
}
