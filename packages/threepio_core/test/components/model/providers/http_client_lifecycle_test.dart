// Every provider used to create a new `http.Client` for each request and
// never closed it. A provider now creates one client, shares it with its
// `withTools` copies and closes it in `dispose()`.
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

/// A client that answers every provider's request and records its lifecycle.
class _RecordingClient extends http.BaseClient {
  final List<Uri> requests = [];
  bool isClosed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    expect(isClosed, isFalse, reason: 'request sent on a closed client');
    requests.add(request.url);

    final path = request.url.path;
    final Map<String, Object?> body;
    if (path.endsWith('/embeddings')) {
      body = {
        'data': [
          {'index': 0, 'embedding': [0.1, 0.2]},
        ],
      };
    } else if (path.contains(':generateContent')) {
      body = {
        'candidates': [
          {
            'content': {
              'role': 'model',
              'parts': [
                {'text': 'ok'},
              ],
            },
            'finishReason': 'STOP',
          },
        ],
      };
    } else {
      body = {
        'choices': [
          {
            'message': {'role': 'assistant', 'content': 'ok'},
            'finish_reason': 'stop',
          },
        ],
      };
    }

    return http.StreamedResponse(
      Stream.value(utf8.encode(jsonEncode(body))),
      200,
      request: request,
      headers: {'content-type': 'application/json'},
    );
  }

  @override
  void close() => isClosed = true;
}

/// A provider under test, reduced to what the lifecycle tests need.
class _Provider {
  _Provider({required this.call, required this.dispose, this.callWithTools});

  /// Sends one request.
  final Future<void> Function() call;

  /// Sends one request through a `withTools` copy; null for embedders.
  final Future<void> Function()? callWithTools;
  final void Function() dispose;
}

final _tools = [
  ToolInfo.simple(name: 'noop', description: 'does nothing', properties: {}),
];
final _messages = [Message.user('hi')];

_Provider _chatModel(
  ToolCallingChatModel model,
  void Function() dispose,
) =>
    _Provider(
      call: () => model.generate(_messages),
      callWithTools: () => model.withTools(_tools).generate(_messages),
      dispose: dispose,
    );

/// Builds each provider, with the injected client when one is given.
final Map<String, _Provider Function(http.Client? client)> _providers = {
  'OpenAIChatModel': (client) {
    final model = OpenAIChatModel(
      config: OpenAIConfig(apiKey: 'test-key'),
      httpClient: client,
    );
    return _chatModel(model, model.dispose);
  },
  'OpenRouterChatModel': (client) {
    final model = OpenRouterChatModel(
      config: OpenRouterConfig(apiKey: 'test-key'),
      httpClient: client,
    );
    return _chatModel(model, model.dispose);
  },
  'GeminiChatModel': (client) {
    final model = GeminiChatModel(
      config: GeminiConfig(apiKey: 'test-key'),
      httpClient: client,
    );
    return _chatModel(model, model.dispose);
  },
  'OpenAIEmbedder': (client) {
    final embedder = OpenAIEmbedder(
      config: OpenAIConfig(apiKey: 'test-key'),
      httpClient: client,
    );
    return _Provider(
      call: () => embedder.embedStrings(['hi']),
      dispose: embedder.dispose,
    );
  },
};

void main() {
  for (final MapEntry(key: name, value: create) in _providers.entries) {
    group(name, () {
      /// Runs [body] with `http.Client()` replaced by recording clients.
      Future<void> withRecordedClients(
        Future<void> Function(List<_RecordingClient> created) body,
      ) {
        final created = <_RecordingClient>[];
        return http.runWithClient(() => body(created), () {
          final client = _RecordingClient();
          created.add(client);
          return client;
        });
      }

      test('creates one client and reuses it for every request', () async {
        await withRecordedClients((created) async {
          final provider = create(null);
          expect(created, isEmpty, reason: 'the client is created on demand');

          await provider.call();
          await provider.call();
          await provider.callWithTools?.call();

          expect(created, hasLength(1));
          expect(
            created.single.requests,
            hasLength(provider.callWithTools == null ? 2 : 3),
          );
        });
      });

      test('dispose closes the client it created', () async {
        await withRecordedClients((created) async {
          final provider = create(null);
          await provider.call();

          provider.dispose();

          expect(created.single.isClosed, isTrue);
        });
      });

      test('throws a StateError when used after dispose', () async {
        await withRecordedClients((created) async {
          final provider = create(null)..dispose();

          await expectLater(provider.call(), throwsStateError);
          if (provider.callWithTools case final callWithTools?) {
            await expectLater(callWithTools(), throwsStateError);
          }
          expect(created, isEmpty);
        });
      });

      test('dispose can be called before use and more than once', () {
        create(null)
          ..dispose()
          ..dispose();
      });

      test('never closes a client that was passed in', () async {
        await withRecordedClients((created) async {
          final injected = _RecordingClient();
          final provider = create(injected);

          await provider.call();
          provider.dispose();

          expect(injected.requests, hasLength(1));
          expect(injected.isClosed, isFalse);
          expect(created, isEmpty);
        });
      });
    });
  }
}
