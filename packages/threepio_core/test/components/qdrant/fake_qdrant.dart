// A fake Qdrant REST server for the tests of the Qdrant client, indexer and
// retriever: a `MockClient` that records every request and answers with the
// JSON shapes Qdrant's REST API sends (`{"result": …, "status": "ok",
// "time": …}`, errors as `{"status": {"error": …}, "time": …}`).
//
// It keeps collections and their points in memory, so that what the indexer
// stores the retriever can find again: a query scores the stored points by
// cosine similarity, applies the score threshold and the limit, and returns
// them best first. Set [FakeQdrant.queryAnswer] to answer queries with fixed
// points instead, and [FakeQdrant.override] to answer any request yourself.
import 'dart:convert';
import 'dart:math' as math;

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// One request the fake received.
typedef QdrantRequest = ({
  String method,
  Uri url,
  Map<String, String> headers,
  Object? body,
});

/// An answer in Qdrant's success envelope.
http.Response qdrantOk(Object? result, {int status = 200}) => http.Response(
      jsonEncode({'result': result, 'status': 'ok', 'time': 0.000123}),
      status,
      headers: {'content-type': 'application/json'},
    );

/// An answer in Qdrant's error envelope.
http.Response qdrantError(int status, String error) => http.Response(
      jsonEncode({
        'status': {'error': error},
        'time': 0.000045,
      }),
      status,
      headers: {'content-type': 'application/json'},
    );

/// The fake server; [client] is the `http.Client` to give the `QdrantClient`.
final class FakeQdrant {
  /// A server that has the collections [collections], all empty.
  FakeQdrant({Iterable<String> collections = const []}) {
    for (final name in collections) {
      points[name] = {};
    }
  }

  /// Every request, in order.
  final List<QdrantRequest> requests = [];

  /// The points of each collection, by id, as they were sent.
  final Map<String, Map<Object, Map<String, Object?>>> points = {};

  /// The parameters each collection was created with (`vectors` of the
  /// create body).
  final Map<String, Object?> created = {};

  /// When set, queries answer these scored points (JSON) instead of scoring
  /// the stored ones.
  List<Map<String, Object?>>? queryAnswer;

  /// When set and it returns an answer, that answer is sent instead.
  Future<http.Response?> Function(http.Request request)? override;

  var _operationId = 0;

  /// The client that talks to this fake.
  late final MockClient client = MockClient(_handle);

  /// The requests whose path ends with [suffix] (and with [method], when
  /// given).
  List<QdrantRequest> requestsTo(String suffix, {String? method}) => [
        for (final request in requests)
          if (request.url.path.endsWith(suffix) &&
              (method == null || request.method == method))
            request,
      ];

  /// The bodies of the upserts, in order.
  List<Map<String, Object?>> get upsertBodies => [
        for (final request in requests)
          if (request.method == 'PUT' && request.url.path.endsWith('/points'))
            request.body! as Map<String, Object?>,
      ];

  /// The bodies of the queries, in order.
  List<Map<String, Object?>> get queryBodies => [
        for (final request in requests)
          if (request.url.path.endsWith('/points/query'))
            request.body! as Map<String, Object?>,
      ];

  Future<http.Response> _handle(http.Request request) async {
    requests.add((
      method: request.method,
      url: request.url,
      headers: request.headers,
      body: request.body.isEmpty ? null : jsonDecode(request.body),
    ));
    final custom = await override?.call(request);
    if (custom != null) return custom;

    final segments = request.url.pathSegments;
    final at = segments.indexOf('collections');
    if (at < 0 || at + 1 >= segments.length) {
      return qdrantError(404, 'Not found');
    }
    final name = segments[at + 1];
    final rest = segments.sublist(at + 2).join('/');
    final body = requests.last.body as Map<String, Object?>?;
    final exists = points.containsKey(name);
    String missing() => "Not found: Collection `$name` doesn't exist!";

    switch ((request.method, rest)) {
      case ('GET', 'exists'):
        return qdrantOk({'exists': exists});
      case ('PUT', ''):
        if (exists) {
          return qdrantError(
            409,
            'Wrong input: Collection `$name` already exists!',
          );
        }
        points[name] = {};
        created[name] = body!['vectors'];
        return qdrantOk(true);
      case ('PUT', 'points'):
        if (!exists) return qdrantError(404, missing());
        for (final point in body!['points']! as List<Object?>) {
          final map = point! as Map<String, Object?>;
          points[name]![map['id']!] = map;
        }
        final wait = request.url.queryParameters['wait'] == 'true';
        return qdrantOk({
          'operation_id': _operationId++,
          'status': wait ? 'completed' : 'acknowledged',
        });
      case ('POST', 'points/query'):
        if (!exists) return qdrantError(404, missing());
        return qdrantOk({
          'points': queryAnswer ?? _score(name, body!),
        });
      default:
        return qdrantError(404, 'Not found');
    }
  }

  List<Map<String, Object?>> _score(String name, Map<String, Object?> body) {
    final query = [
      for (final value in body['query']! as List<Object?>)
        (value! as num).toDouble(),
    ];
    final limit = (body['limit'] as int?) ?? 10;
    final threshold = (body['score_threshold'] as num?)?.toDouble();
    final withPayload = body['with_payload'] == true;
    final scored = <Map<String, Object?>>[];
    for (final point in points[name]!.values) {
      final vector = [
        for (final value in point['vector']! as List<Object?>)
          (value! as num).toDouble(),
      ];
      final score = _cosine(query, vector);
      if (threshold != null && score < threshold) continue;
      scored.add({
        'id': point['id'],
        'version': 0,
        'score': score,
        'payload': withPayload ? point['payload'] : null,
      });
    }
    scored.sort(
      (a, b) => (b['score']! as double).compareTo(a['score']! as double),
    );
    return scored.take(limit).toList();
  }

  static double _cosine(List<double> a, List<double> b) {
    var dot = 0.0;
    var normA = 0.0;
    var normB = 0.0;
    for (var i = 0; i < a.length && i < b.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0 || normB == 0) return 0;
    return dot / (math.sqrt(normA) * math.sqrt(normB));
  }
}
