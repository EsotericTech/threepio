/// A small client for Qdrant's REST API: the calls the Qdrant indexer and
/// retriever make.
///
/// eino-ext's `indexer/qdrant` and `retriever/qdrant` talk to Qdrant over
/// gRPC through `github.com/qdrant/go-client`. Qdrant serves the same
/// operations over REST (port 6333) with JSON bodies, which needs nothing but
/// `package:http` and works on every platform. Each method here is the REST
/// counterpart of the go-client call of the same name.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:meta/meta.dart';

import '../../core/interrupt_signal.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../internal/provider_http.dart';
import '../model/cancel_token.dart';

/// The distance metric of the vectors of a Qdrant collection.
///
/// Port of go-client `qdrant.Distance` (`Distance_Cosine`, `Distance_Euclid`,
/// `Distance_Dot`, `Distance_Manhattan`). [wireValue] is the name the REST API
/// uses. Go's zero value `UnknownDistance` has no member: where a distance is
/// optional, `null` stands for it.
enum QdrantDistance {
  /// Cosine similarity (`Cosine`).
  cosine('Cosine'),

  /// Euclidean distance (`Euclid`).
  euclid('Euclid'),

  /// Dot product (`Dot`).
  dot('Dot'),

  /// Manhattan distance (`Manhattan`).
  manhattan('Manhattan');

  const QdrantDistance(this.wireValue);

  /// The name of the metric in the REST API.
  final String wireValue;
}

/// A point to store in a collection: an id, a dense vector and a payload.
///
/// Port of go-client `qdrant.PointStruct` as the Qdrant indexer fills it:
/// the id is a UUID (`qdrant.NewID`), the vector is the collection's one
/// unnamed dense vector (`qdrant.NewVectors`) and the payload is a JSON object
/// (`qdrant.NewValueMap`).
@immutable
final class QdrantPoint {
  /// A point with [id] (a UUID), [vector] and [payload].
  const QdrantPoint({
    required this.id,
    required this.vector,
    this.payload = const {},
  });

  /// The id of the point, a UUID. Qdrant rejects other strings.
  final String id;

  /// The dense vector of the point.
  final List<double> vector;

  /// The payload of the point.
  ///
  /// The values may be what `qdrant.NewValueMap` accepts: `null`, [bool],
  /// [int], [double], [String], [Uint8List] (sent base64-encoded, like Go's
  /// `[]byte`), a [Map] with [String] keys and a [List] of such values.
  final Map<String, Object?> payload;

  @override
  String toString() => 'QdrantPoint(id: $id, vector: ${vector.length} '
      'dimensions, payload: ${payload.keys.toList()})';
}

/// A point found by a query, with its score.
///
/// Port of go-client `qdrant.ScoredPoint` (the fields the Qdrant retriever
/// reads).
@immutable
final class QdrantScoredPoint {
  /// A point with [id] and [score].
  const QdrantScoredPoint({
    required this.id,
    required this.score,
    this.payload,
    this.version,
  });

  /// The id of the point: a [String] (a UUID) or an [int].
  final Object id;

  /// How close the point is to the query, by the metric of the collection.
  final double score;

  /// The payload of the point, or `null` when the query did not ask for it.
  final Map<String, Object?>? payload;

  /// The version of the point, when Qdrant reports it.
  final int? version;

  @override
  String toString() =>
      'QdrantScoredPoint(id: $id, score: $score, payload: $payload)';
}

/// The state of a write operation when Qdrant answered.
///
/// Port of go-client `qdrant.UpdateStatus`. [wireValue] is the name the REST
/// API uses.
enum QdrantUpdateStatus {
  /// Received but not applied yet: the answer to a write that did not wait
  /// (`acknowledged`, Go `UpdateStatus_Acknowledged`).
  acknowledged('acknowledged'),

  /// Applied and ready for search: the answer to a write that waited
  /// (`completed`, Go `UpdateStatus_Completed`).
  completed('completed'),

  /// Rejected because of an outdated clock, which Qdrant uses internally
  /// (`clock_rejected`, Go `UpdateStatus_ClockRejected`).
  clockRejected('clock_rejected'),

  /// A status this client does not know (Go
  /// `UpdateStatus_UnknownUpdateStatus`).
  unknown(null);

  const QdrantUpdateStatus(this.wireValue);

  /// The name of the status in the REST API; `null` for [unknown].
  final String? wireValue;

  /// The status named [wireValue] in the REST API, or [unknown].
  static QdrantUpdateStatus fromWire(String wireValue) {
    for (final status in values) {
      if (status.wireValue == wireValue) return status;
    }
    return unknown;
  }
}

/// The result of a write operation.
///
/// Port of go-client `qdrant.UpdateResult`.
@immutable
final class QdrantUpdateResult {
  /// A result with [status].
  const QdrantUpdateResult({required this.status, this.operationId});

  /// The number of the operation, when Qdrant reports it.
  final int? operationId;

  /// Whether the write is applied ([QdrantUpdateStatus.completed], the
  /// answer to a write that waited) or only accepted
  /// ([QdrantUpdateStatus.acknowledged]).
  final QdrantUpdateStatus status;

  @override
  String toString() =>
      'QdrantUpdateResult(operationId: $operationId, status: ${status.name})';
}

/// A Qdrant call that failed: an error answer of the server, a request that
/// did not get through, or an answer that could not be read.
///
/// Port of go-client `qdrant.QdrantError`. The [message] is shaped like Go's
/// (`Upsert() failed: my_collection: …`), with the HTTP status and Qdrant's
/// own error text (`status.error` of the answer) in place of the gRPC status.
class QdrantException extends ThreepioException {
  /// The failure of [operation] on [collectionName].
  const QdrantException(
    super.message, {
    required this.operation,
    required this.collectionName,
    this.statusCode,
    this.qdrantError,
    super.cause,
  });

  /// The go-client name of the call that failed: `CollectionExists`,
  /// `CreateCollection`, `Upsert` or `Query`.
  final String operation;

  /// The collection the call was about.
  final String collectionName;

  /// The HTTP status of the answer, or `null` when there was no answer (the
  /// connection failed or the call timed out).
  final int? statusCode;

  /// The error text of Qdrant's answer (its `status.error`), or `null` when
  /// the answer had none.
  final String? qdrantError;

  @override
  String toString() {
    final cause = this.cause;
    return cause == null
        ? 'QdrantException: $message'
        : 'QdrantException: $message\nCaused by: $cause';
  }
}

/// A client for Qdrant's REST API, with the calls the Qdrant indexer and
/// retriever need.
///
/// The REST counterpart of go-client `qdrant.Client` (which speaks gRPC):
///
/// | go-client            | REST                                          |
/// |----------------------|-----------------------------------------------|
/// | `CollectionExists`   | `GET /collections/{name}/exists`              |
/// | `CreateCollection`   | `PUT /collections/{name}`                     |
/// | `Upsert`             | `PUT /collections/{name}/points`              |
/// | `Query`              | `POST /collections/{name}/points/query`       |
///
/// `exists` needs Qdrant 1.8 or later and `query` 1.10 or later, as the gRPC
/// calls do.
///
/// ```dart
/// final client = QdrantClient(apiKey: myKey); // http://localhost:6333
/// try {
///   final exists = await client.collectionExists(ctx, 'docs');
/// } finally {
///   client.close();
/// }
/// ```
///
/// Every call takes the [RunContext] of the work it belongs to: cancelling
/// its token abandons the call with a [CancelledException]. A failed call
/// throws a [QdrantException].
final class QdrantClient {
  /// A client for the Qdrant server at [baseUrl].
  ///
  /// [apiKey] is sent in the `api-key` header when it is set (Go
  /// `qdrant.Config.APIKey`). [httpClient] sends the requests; the caller owns
  /// it and closes it. Without one, the client creates its own on first use
  /// and [close] closes it. [timeout] limits each call, from sending the
  /// request to having read the answer.
  ///
  /// A [baseUrl] that is not an `http` or `https` URL with a host throws an
  /// [ArgumentError].
  QdrantClient({
    String baseUrl = defaultBaseUrl,
    String? apiKey,
    http.Client? httpClient,
    this.timeout = defaultTimeout,
  })  : baseUrl = _parseBaseUrl(baseUrl),
        _apiKey = apiKey,
        _injected = httpClient;

  static Uri _parseBaseUrl(String baseUrl) {
    final url = Uri.tryParse(baseUrl);
    if (url == null ||
        !(url.isScheme('http') || url.isScheme('https')) ||
        url.host.isEmpty) {
      throw ArgumentError.value(
        baseUrl,
        'baseUrl',
        'must be an http or https URL with a host, such as '
            '$defaultBaseUrl',
      );
    }
    return url;
  }

  /// Where a local Qdrant serves its REST API.
  static const defaultBaseUrl = 'http://localhost:6333';

  /// How long a call may take by default.
  ///
  /// go-client sets no deadline of its own (a Go call lasts as long as its
  /// `ctx` allows); this client has one so that an answer that never comes
  /// does not hold the call forever.
  static const defaultTimeout = Duration(seconds: 60);

  /// The address of the Qdrant server. A path in it (a server behind a
  /// proxy) is kept in front of the API paths.
  final Uri baseUrl;

  /// How long a call may take, from sending the request to having read the
  /// answer.
  final Duration timeout;

  final String? _apiKey;
  final http.Client? _injected;
  http.Client? _created;
  var _isClosed = false;

  http.Client get _client {
    if (_isClosed) throw StateError('QdrantClient was used after close()');
    return _injected ?? (_created ??= http.Client());
  }

  /// Closes the HTTP client this client created for itself, if any. A client
  /// passed as `httpClient` is left open. Using this client afterwards throws
  /// a [StateError]. Safe to call more than once.
  void close() {
    _isClosed = true;
    _created?.close();
    _created = null;
  }

  /// Whether the collection [collectionName] exists.
  ///
  /// Port of go-client `Client.CollectionExists`.
  Future<bool> collectionExists(RunContext ctx, String collectionName) async {
    const operation = 'CollectionExists';
    final result = await _call(
      ctx,
      'GET',
      operation,
      collectionName,
      ['collections', collectionName, 'exists'],
    );
    final exists = result is Map ? result['exists'] : null;
    if (exists is! bool) {
      throw _invalidAnswer(operation, collectionName, 'no "exists" flag');
    }
    return exists;
  }

  /// Creates the collection [collectionName] for vectors of [vectorSize]
  /// dimensions compared by [distance].
  ///
  /// Port of go-client `Client.CreateCollection` with the vectors config of
  /// `qdrant.NewVectorsConfig(&qdrant.VectorParams{Size, Distance})`. Without
  /// a [distance] none is sent and Qdrant refuses the request, as it refuses
  /// Go's `UnknownDistance`.
  Future<void> createCollection(
    RunContext ctx,
    String collectionName, {
    required int vectorSize,
    QdrantDistance? distance,
  }) async {
    await _call(
      ctx,
      'PUT',
      'CreateCollection',
      collectionName,
      ['collections', collectionName],
      body: {
        'vectors': {
          'size': vectorSize,
          if (distance != null) 'distance': distance.wireValue,
        },
      },
    );
  }

  /// Inserts [points] into the collection [collectionName], replacing points
  /// with the same ids.
  ///
  /// Port of go-client `Client.Upsert`. [wait] is `UpsertPoints.Wait`: `true`
  /// answers once the points are applied, `false` once they are accepted;
  /// `null` (Go: not set) leaves it to the server, which does not wait.
  ///
  /// A payload value that is not one of the types [QdrantPoint.payload]
  /// lists, or a number that is not finite, throws a
  /// [ThreepioFormatException] and nothing is sent.
  Future<QdrantUpdateResult> upsert(
    RunContext ctx,
    String collectionName,
    List<QdrantPoint> points, {
    bool? wait,
  }) async {
    const operation = 'Upsert';
    final body = {
      'points': [
        for (final point in points)
          {
            'id': point.id,
            'vector': point.vector,
            'payload': _payloadMap(point.payload),
          },
      ],
    };
    final result = await _call(
      ctx,
      'PUT',
      operation,
      collectionName,
      ['collections', collectionName, 'points'],
      query: wait == null ? null : {'wait': '$wait'},
      body: body,
    );
    final status = result is Map ? result['status'] : null;
    if (status is! String) {
      throw _invalidAnswer(operation, collectionName, 'no update status');
    }
    final operationId = result is Map ? result['operation_id'] : null;
    return QdrantUpdateResult(
      status: QdrantUpdateStatus.fromWire(status),
      operationId: operationId is num ? operationId.toInt() : null,
    );
  }

  /// The points of the collection [collectionName] nearest to the dense
  /// vector [query], best first.
  ///
  /// Port of go-client `Client.Query` with `qdrant.NewQueryDense(query)`:
  /// [limit] is the most points returned (Qdrant's default is 10),
  /// [scoreThreshold] the worst score a returned point may have, [filter] a
  /// condition on the payload, and [withPayload] whether the points come
  /// with their payloads.
  ///
  /// [filter] is a filter in Qdrant's REST form
  /// (https://qdrant.tech/documentation/concepts/filtering/). For example,
  /// the points whose payload field `metadata.lang` is `en` and whose
  /// `metadata.year` is 2020 or later:
  ///
  /// ```dart
  /// const filter = {
  ///   'must': [
  ///     {'key': 'metadata.lang', 'match': {'value': 'en'}},
  ///     {'key': 'metadata.year', 'range': {'gte': 2020}},
  ///   ],
  /// };
  /// ```
  Future<List<QdrantScoredPoint>> query(
    RunContext ctx,
    String collectionName, {
    required List<double> query,
    int? limit,
    double? scoreThreshold,
    Map<String, Object?>? filter,
    bool withPayload = true,
  }) async {
    const operation = 'Query';
    final result = await _call(
      ctx,
      'POST',
      operation,
      collectionName,
      ['collections', collectionName, 'points', 'query'],
      body: {
        'query': query,
        if (limit != null) 'limit': limit,
        if (scoreThreshold != null) 'score_threshold': scoreThreshold,
        if (filter != null) 'filter': filter,
        'with_payload': withPayload,
      },
    );
    final points = result is Map ? result['points'] : null;
    if (points is! List) {
      throw _invalidAnswer(operation, collectionName, 'no "points" list');
    }
    return [
      for (final point in points)
        _scoredPoint(point) ??
            (throw _invalidAnswer(
              operation,
              collectionName,
              'a point is not a scored point: $point',
            )),
    ];
  }

  static QdrantScoredPoint? _scoredPoint(Object? raw) {
    if (raw is! Map) return null;
    final id = switch (raw['id']) {
      final String uuid => uuid,
      final num number => number.toInt(),
      _ => null,
    };
    final score = raw['score'];
    final payload = raw['payload'];
    final version = raw['version'];
    if (id == null || score is! num) return null;
    if (payload != null && payload is! Map) return null;
    return QdrantScoredPoint(
      id: id,
      score: score.toDouble(),
      payload: payload == null
          ? null
          : Map<String, Object?>.from(payload as Map),
      version: version is num ? version.toInt() : null,
    );
  }

  /// Sends one request and returns the `result` of the answer.
  Future<Object?> _call(
    RunContext ctx,
    String method,
    String operation,
    String collectionName,
    List<String> path, {
    Map<String, String>? query,
    Map<String, Object?>? body,
  }) async {
    // Outside the try: a closed client is a programming error, and a body
    // that is not JSON is bad input; neither is a failed call.
    final client = _client;
    final encoded = body == null ? null : _encode(operation, collectionName, body);
    final url = _url(path, query);
    final headers = {
      if (encoded != null) 'content-type': 'application/json',
      if (_apiKey case final key? when key.isNotEmpty) 'api-key': key,
    };

    final http.Response response;
    try {
      response = await sendRequest(
        client,
        url,
        method: method,
        headers: headers,
        body: encoded,
        timeout: timeout,
        cancelToken: ctx.cancelToken,
      );
    } on CancelledException {
      rethrow;
    } on TimeoutException catch (error) {
      throw QdrantException(
        '$operation() failed: $collectionName: no answer within $timeout',
        operation: operation,
        collectionName: collectionName,
        cause: error,
      );
    } on Exception catch (error) {
      if (isInterrupt(error)) rethrow;
      throw QdrantException(
        '$operation() failed: $collectionName: $error',
        operation: operation,
        collectionName: collectionName,
        cause: error,
      );
    }

    final status = response.statusCode;
    // Decoded once, leniently: `response.body` would throw on malformed
    // UTF-8 or a Content-Type it cannot read.
    final text = utf8.decode(response.bodyBytes, allowMalformed: true);
    Object? decoded;
    FormatException? decodeError;
    try {
      decoded = text.isEmpty ? null : jsonDecode(text);
    } on FormatException catch (error) {
      decodeError = error;
    }

    if (status < 200 || status >= 300) {
      final qdrantError = _errorText(decoded);
      final detail = qdrantError ?? _bodyText(text, response.reasonPhrase);
      throw QdrantException(
        '$operation() failed: $collectionName: HTTP $status: $detail',
        operation: operation,
        collectionName: collectionName,
        statusCode: status,
        qdrantError: qdrantError,
      );
    }
    if (decoded is! Map || !decoded.containsKey('result')) {
      throw _invalidAnswer(
        operation,
        collectionName,
        decodeError == null ? 'no "result"' : 'not JSON',
        statusCode: status,
        cause: decodeError,
      );
    }
    return decoded['result'];
  }

  Uri _url(List<String> path, Map<String, String>? query) {
    final segments = [
      for (final segment in baseUrl.pathSegments)
        if (segment.isNotEmpty) segment,
      ...path,
    ];
    return query == null
        ? baseUrl.replace(pathSegments: segments)
        : baseUrl.replace(pathSegments: segments, queryParameters: query);
  }

  static String _encode(
    String operation,
    String collectionName,
    Map<String, Object?> body,
  ) {
    try {
      return jsonEncode(body);
      // jsonEncode reports a value it cannot write (NaN, an object) as an
      // Error; here it is bad input, not a bug.
      // ignore: avoid_catching_errors
    } on JsonUnsupportedObjectError catch (error) {
      throw ThreepioFormatException(
        '$operation() failed: $collectionName: the request cannot be '
        'written as JSON: ${error.unsupportedObject}',
        cause: error,
      );
    }
  }

  /// Qdrant's error text in an error answer: `{"status": {"error": "…"}}`.
  static String? _errorText(Object? decoded) {
    if (decoded is! Map) return null;
    final status = decoded['status'];
    if (status is Map && status['error'] is String) {
      return status['error'] as String;
    }
    return null;
  }

  /// The [body] of an error answer that is not Qdrant's JSON, shortened, or
  /// the [reasonPhrase] when the body is empty.
  static String _bodyText(String body, String? reasonPhrase) {
    final text = body.trim();
    if (text.isEmpty) return reasonPhrase ?? 'no details';
    return text.length <= _maxBodyText
        ? text
        : '${text.substring(0, _maxBodyText)}…';
  }

  static const _maxBodyText = 500;

  static QdrantException _invalidAnswer(
    String operation,
    String collectionName,
    String what, {
    int? statusCode = 200,
    Object? cause,
  }) =>
      QdrantException(
        '$operation() failed: $collectionName: unexpected answer: $what',
        operation: operation,
        collectionName: collectionName,
        statusCode: statusCode,
        cause: cause,
      );
}

/// [payload] as the JSON object Qdrant stores, converted value by value as
/// go-client `qdrant.TryValueMap` converts it.
Map<String, Object?> _payloadMap(Map<Object?, Object?> payload) {
  final result = <String, Object?>{};
  for (final MapEntry(:key, :value) in payload.entries) {
    if (key is! String) {
      throw ThreepioFormatException(
        'invalid type: a payload key is a ${key.runtimeType}, not a String',
      );
    }
    result[key] = _payloadValue(value);
  }
  return result;
}

/// Port of go-client `qdrant.NewValue`: the JSON form of one payload value.
/// Go returns an error for any other type ("invalid type: %T"); so does this,
/// as a [ThreepioFormatException]. Go accepts only `[]any` as a list; any
/// Dart [List] is accepted here, since a Dart list of a narrower type is
/// still a list of values.
Object? _payloadValue(Object? value) => switch (value) {
      null || bool() || int() || double() || String() => value,
      Uint8List() => base64.encode(value),
      Map() => _payloadMap(value),
      List() => [for (final item in value) _payloadValue(item)],
      _ => throw ThreepioFormatException('invalid type: ${value.runtimeType}'),
    };
