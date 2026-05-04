import 'dart:io';

void main() {
  String baseUrl = 'https://afraid-dryers-smell.loca.lt';
  if (!baseUrl.contains(':', baseUrl.indexOf('://') + 3)) {
    baseUrl = '$baseUrl:443';
  }
  print(baseUrl);
  var uri = Uri.parse(baseUrl);
  print(uri);
  print(uri.port);
}
