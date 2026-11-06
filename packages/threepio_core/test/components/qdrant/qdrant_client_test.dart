// Tests for `QdrantClient`, the REST counterpart of the go-client calls that
// eino-ext's Qdrant indexer and retriever make (`CollectionExists`,
// `CreateCollection`, `Upsert`, `Query`). There is no Go test of the client
// itself (go-client is a dependency); these are written for the port: the
// requests each call sends (method, path, query, headers, JSON body), the
// answers it reads, the payload conversion of go-client `qdrant.NewValue`,
// the errors (shaped like go-client's `QdrantError`), timeouts,
// cancellation and the HTTP client lifecycle. Requests go to a fake server
// (`fake_qdrant.dart`) or, for the client created by `QdrantClient` itself, to
// a loopback `HttpServer`.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/components/qdrant/qdrant_client.dart';
import 'package:threepio_core/threepio_core.dart';

import 'fake_qdrant.dart';

final _ctx = RunContext.background();

/// An `http.Client` that records whether it was closed.
final class _ClosingClient extends http.BaseClient {
  _ClosingClient(this._inner);

  final http.Client _inner;
  var closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      _inner.send(request);

  @override
  void close() {
    closed = true;
    _inner.close();
  }
}

void main() {
  group('QdrantDistance', () {
    test('has the wire names of the REST API', () {
      expect(
        {for (final d in QdrantDistance.values) d.name: d.wireValue},
        {
          'cosine': 'Cosine',
          'euclid': 'Euclid',
          'dot': 'Dot',
          'manhattan': 'Manhattan',
        },
      );
    });
  });

  group('QdrantUpdateStatus', () {
    test('has the wire names of the REST API; any other name is unknown', () {
      expect(
        {for (final s in QdrantUpdateStatus.values) s.name: s.wireValue},
        {
          'acknowledged': 'acknowledged',
          'completed': 'completed',
          'clockRejected': 'clock_rejected',
          'unknown': null,
        },
      );
      for (final status in QdrantUpdateStatus.values) {
        if (status.wireValue case final wire?) {
          expect(QdrantUpdateStatus.fromWire(wire), status);
        }
      }
      expect(QdrantUpdateStatus.fromWire('wait_timeout'),
          QdrantUpdateStatus.unknown);
      expect(QdrantUpdateStatus.fromWire(''), QdrantUpdateStatus.unknown);
    });

    test('an upsert answered with a status the client does not know',
        () async {
      final fake = FakeQdrant()
        ..override = (_) async =>
            qdrantOk({'operation_id': 5, 'status': 'wait_timeout'});
      final client = QdrantClient(httpClient: fake.client);

      final result = await client.upsert(_ctx, 'docs', const []);

      expect(result.status, QdrantUpdateStatus.unknown);
      expect(result.operationId, 5);
    });
  });

  group('collectionExists', () {
    test('asks GET /collections/{name}/exists and reads the flag', () async {
      final fake = FakeQdrant(collections: ['present']);
      final client = QdrantClient(httpClient: fake.client);

      expect(await client.collectionExists(_ctx, 'present'), isTrue);
      expect(await client.collectionExists(_ctx, 'absent'), isFalse);

      final request = fake.requests.first;
      expect(request.method, 'GET');
      expect(
        request.url.toString(),
        'http://localhost:6333/collections/present/exists',
      );
      expect(request.body, isNull);
      expect(request.headers.containsKey('content-type'), isFalse);
    });

    test('an answer without the flag is an unexpected answer', () async {
      final fake = FakeQdrant()
        ..override = (_) async => qdrantOk({'present': true});
      final client = QdrantClient(httpClient: fake.client);

      await expectLater(
        client.collectionExists(_ctx, 'c'),
        throwsA(
          isA<QdrantException>()
              .having((e) => e.message, 'message',
                  'CollectionExists() failed: c: unexpected answer: no '
                      '"exists" flag')
              .having((e) => e.statusCode, 'statusCode', 200)
              .having((e) => e.operation, 'operation', 'CollectionExists')
              .having((e) => e.collectionName, 'collectionName', 'c'),
        ),
      );
    });
  });

  group('createCollection', () {
    test('sends PUT /collections/{name} with the vectors config', () async {
      final fake = FakeQdrant();
      final client = QdrantClient(httpClient: fake.client);

      await client.createCollection(
        _ctx,
        'docs',
        vectorSize: 4,
        distance: QdrantDistance.dot,
      );

      final request = fake.requests.single;
      expect(request.method, 'PUT');
      expect(request.url.path, '/collections/docs');
      expect(request.body, {
        'vectors': {'size': 4, 'distance': 'Dot'},
      });
      expect(request.headers['content-type'], startsWith('application/json'));
      expect(fake.points.keys, ['docs']);
    });

    test('without a distance none is sent', () async {
      final fake = FakeQdrant();
      final client = QdrantClient(httpClient: fake.client);

      await client.createCollection(_ctx, 'docs', vectorSize: 8);

      expect(fake.requests.single.body, {
        'vectors': {'size': 8},
      });
    });

    test("Qdrant's refusal is a QdrantException with its text", () async {
      final fake = FakeQdrant(collections: ['docs']);
      final client = QdrantClient(httpClient: fake.client);

      await expectLater(
        client.createCollection(_ctx, 'docs', vectorSize: 4),
        throwsA(
          isA<QdrantException>()
              .having((e) => e.statusCode, 'statusCode', 409)
              .having((e) => e.qdrantError, 'qdrantError',
                  'Wrong input: Collection `docs` already exists!')
              .having((e) => e.message, 'message',
                  'CreateCollection() failed: docs: HTTP 409: Wrong input: '
                      'Collection `docs` already exists!'),
        ),
      );
    });
  });

  group('upsert', () {
    test('sends the points with ids, vectors and payloads; no wait by '
        'default', () async {
      final fake = FakeQdrant(collections: ['docs']);
      final client = QdrantClient(httpClient: fake.client);

      final result = await client.upsert(_ctx, 'docs', const [
        QdrantPoint(
          id: 'c60df334-dbbe-49b8-82d8-a2bd668602f6',
          vector: [0.1, 0.2],
          payload: {'content': 'asd', 'metadata': <String, Object?>{}},
        ),
        QdrantPoint(id: '7b83aca0-5f6c-4491-8dd4-22e15e9d582e', vector: [1, 2]),
      ]);

      final request = fake.requests.single;
      expect(request.method, 'PUT');
      expect(request.url.path, '/collections/docs/points');
      expect(request.url.hasQuery, isFalse);
      expect(request.body, {
        'points': [
          {
            'id': 'c60df334-dbbe-49b8-82d8-a2bd668602f6',
            'vector': [0.1, 0.2],
            'payload': {'content': 'asd', 'metadata': <String, Object?>{}},
          },
          {
            'id': '7b83aca0-5f6c-4491-8dd4-22e15e9d582e',
            'vector': [1.0, 2.0],
            'payload': <String, Object?>{},
          },
        ],
      });
      expect(result.status, QdrantUpdateStatus.acknowledged);
      expect(result.operationId, 0);
    });

    test('wait is sent as the query parameter when set', () async {
      final fake = FakeQdrant(collections: ['docs']);
      final client = QdrantClient(httpClient: fake.client);
      const point = QdrantPoint(
        id: 'c60df334-dbbe-49b8-82d8-a2bd668602f6',
        vector: [1],
      );

      final waited = await client.upsert(_ctx, 'docs', [point], wait: true);
      await client.upsert(_ctx, 'docs', [point], wait: false);

      expect(fake.requests[0].url.query, 'wait=true');
      expect(fake.requests[1].url.query, 'wait=false');
      expect(waited.status, QdrantUpdateStatus.completed);
      expect(waited.operationId, 0);
    });

    test('payload values are converted as go-client NewValue converts them',
        () async {
      final fake = FakeQdrant(collections: ['docs']);
      final client = QdrantClient(httpClient: fake.client);

      await client.upsert(_ctx, 'docs', [
        QdrantPoint(
          id: 'c60df334-dbbe-49b8-82d8-a2bd668602f6',
          vector: const [1],
          payload: {
            'some_null': null,
            'some_bool': true,
            'some_int': 42,
            'some_float': 3.14,
            'some_string': 'hello',
            'some_bytes': Uint8List.fromList(utf8.encode('world')),
            'some_nested': {'key': 'value'},
            'some_list': ['foo', 32],
            'typed_list': <String>['a', 'b'],
          },
        ),
      ]);

      final points = (fake.requests.single.body! as Map)['points'] as List;
      expect((points.single as Map)['payload'], {
        'some_null': null,
        'some_bool': true,
        'some_int': 42,
        'some_float': 3.14,
        'some_string': 'hello',
        'some_bytes': 'd29ybGQ=',
        'some_nested': {'key': 'value'},
        'some_list': ['foo', 32],
        'typed_list': ['a', 'b'],
      });
    });

    test('a payload value of another type is refused and nothing is sent',
        () async {
      final fake = FakeQdrant(collections: ['docs']);
      final client = QdrantClient(httpClient: fake.client);

      await expectLater(
        client.upsert(_ctx, 'docs', [
          QdrantPoint(
            id: 'c60df334-dbbe-49b8-82d8-a2bd668602f6',
            vector: const [1],
            payload: {
              'when': {'at': DateTime.utc(2025)},
            },
          ),
        ]),
        throwsA(
          isA<ThreepioFormatException>()
              .having((e) => e.message, 'message', 'invalid type: DateTime'),
        ),
      );
      await expectLater(
        client.upsert(_ctx, 'docs', [
          const QdrantPoint(
            id: 'c60df334-dbbe-49b8-82d8-a2bd668602f6',
            vector: [1],
            payload: {
              'nested': {1: 'one'},
            },
          ),
        ]),
        throwsA(
          isA<ThreepioFormatException>().having((e) => e.message, 'message',
              'invalid type: a payload key is a int, not a String'),
        ),
      );
      expect(fake.requests, isEmpty);
    });

    test('a vector that is not finite cannot be sent', () async {
      final fake = FakeQdrant(collections: ['docs']);
      final client = QdrantClient(httpClient: fake.client);

      await expectLater(
        client.upsert(_ctx, 'docs', const [
          QdrantPoint(
            id: 'c60df334-dbbe-49b8-82d8-a2bd668602f6',
            vector: [double.nan],
          ),
        ]),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            'Upsert() failed: docs: the request cannot be written as JSON: '
                'NaN',
          ),
        ),
      );
      expect(fake.requests, isEmpty);
    });

    test('an answer without a status is an unexpected answer', () async {
      final fake = FakeQdrant()..override = (_) async => qdrantOk(true);
      final client = QdrantClient(httpClient: fake.client);

      await expectLater(
        client.upsert(_ctx, 'docs', const []),
        throwsA(
          isA<QdrantException>().having((e) => e.message, 'message',
              'Upsert() failed: docs: unexpected answer: no update status'),
        ),
      );
    });
  });

  group('query', () {
    test('sends the dense query with limit, threshold, filter and payload',
        () async {
      final fake = FakeQdrant(collections: ['docs'])..queryAnswer = [];
      final client = QdrantClient(httpClient: fake.client);
      const filter = {
        'must': [
          {
            'key': 'metadata.lang',
            'match': {'value': 'en'},
          },
        ],
      };

      await client.query(
        _ctx,
        'docs',
        query: const [0.5, 0.25],
        limit: 3,
        scoreThreshold: 0.7,
        filter: filter,
      );

      final request = fake.requests.single;
      expect(request.method, 'POST');
      expect(request.url.path, '/collections/docs/points/query');
      expect(request.body, {
        'query': [0.5, 0.25],
        'limit': 3,
        'score_threshold': 0.7,
        'filter': filter,
        'with_payload': true,
      });
    });

    test('leaves out what is not set', () async {
      final fake = FakeQdrant(collections: ['docs'])..queryAnswer = [];
      final client = QdrantClient(httpClient: fake.client);

      await client.query(_ctx, 'docs', query: const [1], withPayload: false);

      expect(fake.requests.single.body, {
        'query': [1.0],
        'with_payload': false,
      });
    });

    test('reads the scored points: UUID and numeric ids, payloads, versions',
        () async {
      final fake = FakeQdrant(collections: ['docs'])
        ..queryAnswer = [
          {
            'id': 'fba95545-ef38-4880-bf4a-b98174554103',
            'version': 3,
            'score': 0.95,
            'payload': {'content': 'Test content 1'},
          },
          {'id': 42, 'version': 0, 'score': 1, 'payload': null},
        ];
      final client = QdrantClient(httpClient: fake.client);

      final points = await client.query(_ctx, 'docs', query: const [1]);

      expect(points, hasLength(2));
      expect(points[0].id, 'fba95545-ef38-4880-bf4a-b98174554103');
      expect(points[0].score, 0.95);
      expect(points[0].payload, {'content': 'Test content 1'});
      expect(points[0].version, 3);
      expect(points[1].id, 42);
      expect(points[1].score, 1.0);
      expect(points[1].payload, isNull);
      expect(points[1].toString(), contains('id: 42'));
    });

    test('a point that is not a scored point is an unexpected answer',
        () async {
      for (final bad in [
        {'id': 'x', 'payload': <String, Object?>{}},
        {'score': 0.5},
        {'id': true, 'score': 0.5},
        {'id': 'x', 'score': 0.5, 'payload': 'text'},
        'not a point',
      ]) {
        final fake = FakeQdrant(collections: ['docs'])..queryAnswer = null;
        fake.override = (_) async => qdrantOk({
              'points': [bad],
            });
        final client = QdrantClient(httpClient: fake.client);
        await expectLater(
          client.query(_ctx, 'docs', query: const [1]),
          throwsA(
            isA<QdrantException>().having((e) => e.message, 'message',
                startsWith('Query() failed: docs: unexpected answer: a point')),
          ),
          reason: '$bad',
        );
      }
    });

    test('an answer without points is an unexpected answer', () async {
      final fake = FakeQdrant()..override = (_) async => qdrantOk([]);
      final client = QdrantClient(httpClient: fake.client);

      await expectLater(
        client.query(_ctx, 'docs', query: const [1]),
        throwsA(
          isA<QdrantException>().having((e) => e.message, 'message',
              'Query() failed: docs: unexpected answer: no "points" list'),
        ),
      );
    });
  });

  group('errors', () {
    test("an error answer carries the HTTP status and Qdrant's text",
        () async {
      final fake = FakeQdrant();
      final client = QdrantClient(httpClient: fake.client);

      final error = await client
          .query(_ctx, 'missing', query: const [1])
          .then<Object>((_) => fail('no error'), onError: (Object e) => e);

      expect(
        error,
        isA<QdrantException>()
            .having((e) => e.statusCode, 'statusCode', 404)
            .having((e) => e.qdrantError, 'qdrantError',
                "Not found: Collection `missing` doesn't exist!")
            .having((e) => e.operation, 'operation', 'Query')
            .having((e) => e.collectionName, 'collectionName', 'missing')
            .having((e) => e.cause, 'cause', isNull)
            .having((e) => e.message, 'message',
                'Query() failed: missing: HTTP 404: Not found: Collection '
                    "`missing` doesn't exist!"),
      );
      expect(error, isA<ThreepioException>());
      expect(
        error.toString(),
        'QdrantException: Query() failed: missing: HTTP 404: Not found: '
        "Collection `missing` doesn't exist!",
      );
    });

    test('an error answer that is not JSON shows its body', () async {
      final fake = FakeQdrant()
        ..override = (_) async => http.Response('Invalid api-key', 401);
      final client = QdrantClient(httpClient: fake.client);

      await expectLater(
        client.collectionExists(_ctx, 'c'),
        throwsA(
          isA<QdrantException>()
              .having((e) => e.statusCode, 'statusCode', 401)
              .having((e) => e.qdrantError, 'qdrantError', isNull)
              .having((e) => e.message, 'message',
                  'CollectionExists() failed: c: HTTP 401: Invalid api-key'),
        ),
      );
    });

    test('an error body that is not valid UTF-8, or has a Content-Type that '
        'cannot be read, is still a QdrantException', () async {
      final fake = FakeQdrant()
        ..override = (request) async => request.url.path.endsWith('exists')
            ? http.Response.bytes(
                [0x62, 0x61, 0x64, 0x20, 0xff, 0xfe],
                502,
                headers: {'content-type': 'text/plain; charset=utf-8'},
              )
            : http.Response.bytes(
                utf8.encode('gateway down'),
                502,
                headers: {'content-type': '/// not a media type'},
              );
      final client = QdrantClient(httpClient: fake.client);

      await expectLater(
        client.collectionExists(_ctx, 'c'),
        throwsA(
          isA<QdrantException>()
              .having((e) => e.statusCode, 'statusCode', 502)
              .having((e) => e.message, 'message',
                  startsWith('CollectionExists() failed: c: HTTP 502: bad ')),
        ),
      );
      await expectLater(
        client.createCollection(_ctx, 'c', vectorSize: 1),
        throwsA(isA<QdrantException>().having((e) => e.message, 'message',
            'CreateCollection() failed: c: HTTP 502: gateway down')),
      );
    });

    test('a long error body is shortened; an empty one gives the reason',
        () async {
      final long = 'x' * 600;
      final fake = FakeQdrant()
        ..override = (request) async => request.url.path.endsWith('exists')
            ? http.Response(long, 502)
            : http.Response('', 503, reasonPhrase: 'Service Unavailable');
      final client = QdrantClient(httpClient: fake.client);

      await expectLater(
        client.collectionExists(_ctx, 'c'),
        throwsA(isA<QdrantException>().having((e) => e.message, 'message',
            'CollectionExists() failed: c: HTTP 502: ${'x' * 500}…')),
      );
      await expectLater(
        client.createCollection(_ctx, 'c', vectorSize: 1),
        throwsA(isA<QdrantException>().having((e) => e.message, 'message',
            'CreateCollection() failed: c: HTTP 503: Service Unavailable')),
      );
    });

    test('a success answer that is not JSON, or has no result', () async {
      final fake = FakeQdrant()
        ..override = (request) async => request.url.path.endsWith('exists')
            ? http.Response('<html>proxy</html>', 200)
            : http.Response(jsonEncode({'status': 'ok'}), 200);
      final client = QdrantClient(httpClient: fake.client);

      await expectLater(
        client.collectionExists(_ctx, 'c'),
        throwsA(
          isA<QdrantException>()
              .having((e) => e.message, 'message',
                  'CollectionExists() failed: c: unexpected answer: not JSON')
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
      await expectLater(
        client.query(_ctx, 'c', query: const [1]),
        throwsA(isA<QdrantException>().having((e) => e.message, 'message',
            'Query() failed: c: unexpected answer: no "result"')),
      );
    });

    test('a request that does not get through', () async {
      final failure = http.ClientException('Connection refused');
      final client = QdrantClient(
        httpClient: MockClient((_) async => throw failure),
      );

      await expectLater(
        client.collectionExists(_ctx, 'c'),
        throwsA(
          isA<QdrantException>()
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having((e) => e.cause, 'cause', same(failure))
              .having((e) => e.message, 'message',
                  'CollectionExists() failed: c: ClientException: '
                      'Connection refused'),
        ),
      );
    });

    test('a call that takes longer than the timeout', () async {
      final client = QdrantClient(
        httpClient: MockClient((_) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 5),
      );

      await expectLater(
        client.collectionExists(_ctx, 'c'),
        throwsA(
          isA<QdrantException>()
              .having((e) => e.cause, 'cause', isA<TimeoutException>())
              .having((e) => e.message, 'message',
                  'CollectionExists() failed: c: no answer within '
                      '0:00:00.005000'),
        ),
      );
    });
  });

  group('requests', () {
    test('the API key goes in the api-key header, only when set', () async {
      final fake = FakeQdrant();
      await QdrantClient(httpClient: fake.client, apiKey: 'test-key')
          .collectionExists(_ctx, 'c');
      await QdrantClient(httpClient: fake.client, apiKey: '')
          .collectionExists(_ctx, 'c');
      await QdrantClient(httpClient: fake.client).collectionExists(_ctx, 'c');

      expect(fake.requests[0].headers['api-key'], 'test-key');
      expect(fake.requests[1].headers.containsKey('api-key'), isFalse);
      expect(fake.requests[2].headers.containsKey('api-key'), isFalse);
    });

    test('a path in the base URL is kept; names are encoded', () async {
      final fake = FakeQdrant()
        ..override = (_) async => qdrantOk({'exists': true});
      final client = QdrantClient(
        baseUrl: 'https://qdrant.example.com:8443/proxy/qdrant/',
        httpClient: fake.client,
      );

      await client.collectionExists(_ctx, 'my docs/v1');

      expect(
        fake.requests.single.url.toString(),
        'https://qdrant.example.com:8443/proxy/qdrant/collections/'
        'my%20docs%2Fv1/exists',
      );
      expect(client.baseUrl.host, 'qdrant.example.com');
      expect(client.timeout, QdrantClient.defaultTimeout);
    });
  });

  group('base URL', () {
    test('defaults to a local Qdrant', () {
      final client = QdrantClient();
      addTearDown(client.close);
      expect(client.baseUrl.toString(), 'http://localhost:6333');
      expect(QdrantClient.defaultBaseUrl, 'http://localhost:6333');
    });

    test('anything but an http or https URL with a host is refused', () {
      for (final bad in ['localhost:6333', 'qdrant', 'ftp://host', 'http://', '::']) {
        expect(
          () => QdrantClient(baseUrl: bad),
          throwsA(isA<ArgumentError>()
              .having((e) => e.name, 'name', 'baseUrl')
              .having((e) => e.invalidValue, 'invalidValue', bad)),
          reason: bad,
        );
      }
    });
  });

  group('cancellation', () {
    test('a cancelled run context sends nothing', () async {
      final fake = FakeQdrant();
      final client = QdrantClient(httpClient: fake.client);

      await expectLater(
        client.collectionExists(
          RunContext.background(cancelToken: CancelToken()..cancel('stop')),
          'c',
        ),
        throwsA(isA<CancelledException>()
            .having((e) => e.reason, 'reason', 'stop')),
      );
      expect(fake.requests, isEmpty);
    });

    test('cancelling while the answer is awaited abandons the call',
        () async {
      final sent = Completer<void>();
      final token = CancelToken();
      final client = QdrantClient(
        httpClient: MockClient((_) {
          sent.complete();
          return Completer<http.Response>().future; // never answers
        }),
      );

      final call = client.query(
        RunContext.background(cancelToken: token),
        'c',
        query: const [1],
      );
      await sent.future;
      token.cancel('user');

      await expectLater(call, throwsA(isA<CancelledException>()));
    });
  });

  group('lifecycle', () {
    test('an injected client is not closed; a closed QdrantClient refuses '
        'calls', () async {
      final fake = FakeQdrant();
      final injected = _ClosingClient(fake.client);
      final client = QdrantClient(httpClient: injected)
        ..close()
        ..close();

      expect(injected.closed, isFalse);
      await expectLater(
        client.collectionExists(_ctx, 'c'),
        throwsA(isA<StateError>().having((e) => e.message, 'message',
            'QdrantClient was used after close()')),
      );
      expect(fake.requests, isEmpty);
    });

    test('without an injected client it makes its own, over real HTTP',
        () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final seen = <({String method, String path, String? key, Object? body})>[];
      server.listen((request) async {
        final text = await utf8.decodeStream(request);
        seen.add((
          method: request.method,
          path: request.uri.toString(),
          key: request.headers.value('api-key'),
          body: text.isEmpty ? null : jsonDecode(text),
        ));
        request.response
          ..statusCode = 200
          ..headers.contentType = ContentType.json
          ..write(jsonEncode({
            'result': {'operation_id': 7, 'status': 'completed'},
            'status': 'ok',
            'time': 0.001,
          }));
        await request.response.close();
      });

      final client = QdrantClient(
        baseUrl: 'http://${server.address.host}:${server.port}',
        apiKey: 'test-key',
      );
      addTearDown(client.close);

      final result = await client.upsert(
        _ctx,
        'docs',
        const [
          QdrantPoint(
            id: 'c60df334-dbbe-49b8-82d8-a2bd668602f6',
            vector: [0.5],
            payload: {'content': 'héllo'},
          ),
        ],
        wait: true,
      );

      expect(result.operationId, 7);
      expect(result.status, QdrantUpdateStatus.completed);
      expect(seen.single.method, 'PUT');
      expect(seen.single.path, '/collections/docs/points?wait=true');
      expect(seen.single.key, 'test-key');
      expect(seen.single.body, {
        'points': [
          {
            'id': 'c60df334-dbbe-49b8-82d8-a2bd668602f6',
            'vector': [0.5],
            'payload': {'content': 'héllo'},
          },
        ],
      });

      client.close();
      await expectLater(
        client.collectionExists(_ctx, 'docs'),
        throwsStateError,
      );
    });
  });

  test('the value types print what they hold', () {
    expect(
      const QdrantPoint(
        id: 'a',
        vector: [1, 2],
        payload: {'content': 'x'},
      ).toString(),
      'QdrantPoint(id: a, vector: 2 dimensions, payload: [content])',
    );
    expect(
      const QdrantUpdateResult(
        status: QdrantUpdateStatus.completed,
        operationId: 1,
      ).toString(),
      'QdrantUpdateResult(operationId: 1, status: completed)',
    );
    expect(
      const QdrantException(
        'Upsert() failed: c: boom',
        operation: 'Upsert',
        collectionName: 'c',
        cause: 'inner',
      ).toString(),
      'QdrantException: Upsert() failed: c: boom\nCaused by: inner',
    );
  });
}
