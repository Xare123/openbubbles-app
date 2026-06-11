import 'dart:io';
import 'package:bluebubbles/services/network/http_overrides.dart';
import 'package:bluebubbles/services/network/user_certificates.dart';
import 'package:socket_io_client/socket_io_client.dart';

class WebsocketAdapter implements HttpClientAdapter {
  @override
  Future<WebSocket?> connect(String uri, {Map<String, dynamic>? headers}) async {
    // Get context with system certs + user certs (Android only)
    final context = await UserCertificates().getContext();
    final client = HttpClient(context: context);

    // Add custom certificate validation for self-signed certs and hostname mismatches
    client.badCertificateCallback = shouldAcceptCertificate;

    return WebSocket.connect(
      uri,
      headers: headers?.map((key, value) => MapEntry(key, value.toString())) ?? {},
      customClient: client,
    );
  }
}
