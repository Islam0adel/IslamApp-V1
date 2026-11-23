import 'dart:convert';
import 'package:http/http.dart' as http;

/// Upgrade legacy synthetic list responses to the new protocol. Production
/// never interprets a bare list as a revisioned checkpoint.
http.Response treasuryProtocol(http.Request request, http.Response response) {
  if (!request.url.path.contains('/treasury-transfers/changes/') ||
      response.statusCode != 200) return response;
  final raw = jsonDecode(response.body);
  if (raw is! List) return response;
  final company = request.url.pathSegments.last;
  final items = <Map<String, dynamic>>[];
  for (var i = 0; i < raw.length; i++) {
    final row = Map<String, dynamic>.from(raw[i] as Map);
    if (row['company_code'] != company) continue;
    items.add({
      ...row,
      'id': row['id'] ?? 'fixture-$i',
      'revision': i + 1,
      'is_deleted': row['is_deleted'] ?? false
    });
  }
  return http.Response(
      jsonEncode({
        'protocol': 2,
        'mode': 'records',
        'company_code': company,
        'scope': 'fixture',
        'cursor': raw.length,
        'reset': true,
        'items': items
      }),
      200,
      headers: {'content-type': 'application/json; charset=utf-8'});
}
