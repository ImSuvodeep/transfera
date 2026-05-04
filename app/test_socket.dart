import 'package:socket_io_client/socket_io_client.dart' as IO;
void main() {
  print(IO.OptionBuilder().setTransports(['polling']).build());
}
