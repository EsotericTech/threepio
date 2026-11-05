// How the Langfuse handler prepares what it exports: JSON, masks and cuts.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/components.dart';
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/src/observability/langfuse/langfuse_values.dart';
import 'package:threepio_core/streaming.dart';

enum _Colour { red }

final class _WithToJson {
  Map<String, Object?> toJson() => {'kind': 'custom', 'missing': null};
}

final class _Plain {
  @override
  String toString() => 'a plain object';
}

void main() {
  group('truncateText', () {
    test('keeps what fits', () {
      expect(truncateText('short', 10), 'short');
      expect(truncateText('exact', 5), 'exact');
      expect(truncateText('', 5), '');
    });

    test('keeps the beginning and the end around a marker', () {
      final text = '${'a' * 100}${'z' * 100}';
      final cut = truncateText(text, 60);

      expect(cut.length, 60);
      expect(cut, contains(truncationMarker));
      expect(cut, startsWith('aaa'));
      expect(cut, endsWith('zzz'));
      // 7 tenths of what is left for the beginning.
      expect(cut.indexOf(truncationMarker), (60 - truncationMarker.length) * 7 ~/ 10);
    });

    test('too short for the marker, it is a plain prefix', () {
      expect(truncateText('abcdefghijklmnopqrstuvwxyz', 5), 'abcde');
      expect(truncateText('abc', 0), '');
      expect(truncateText('abc', -3), '');
    });

    test('never cuts a character in two', () {
      final text = '😀' * 40; // two code units each
      for (var length = 1; length < 60; length++) {
        final cut = truncateText(text, length);
        expect(cut.length, lessThanOrEqualTo(length));
        expect(() => utf8.encode(cut), returnsNormally);
        expect(cut.replaceAll(truncationMarker, '').runes, everyElement(0x1F600));
      }
    });

    test('always makes progress: the result is never longer than asked', () {
      final text = 'x' * 1000;
      for (var length = 0; length <= 1000; length += 7) {
        expect(truncateText(text, length).length, lessThanOrEqualTo(length));
      }
    });
  });

  group('truncateJson', () {
    test('wraps a preview in a JSON object that fits', () {
      final value = jsonEncode({'text': 'x' * 500});
      for (final length in [60, 100, 200, 400]) {
        final cut = truncateJson(value, length);
        expect(cut.length, lessThanOrEqualTo(length), reason: '$length');
        final decoded = jsonDecode(cut) as Map<String, Object?>;
        expect(decoded['truncated'], isTrue);
        expect(decoded['original_length'], value.length);
        expect(decoded['preview'], isA<String>());
      }
    });

    test('with no room for a preview it is an empty object, or nothing', () {
      final value = jsonEncode({'text': 'x' * 500});
      expect(truncateJson(value, 20), '{}');
      expect(truncateJson(value, 2), '{}');
      expect(truncateJson(value, 1), '');
      expect(truncateJson(value, 0), '');
    });

    test('a preview with characters that need escaping still fits', () {
      final value = jsonEncode('"' * 300);
      final cut = truncateJson(value, 120);
      expect(cut.length, lessThanOrEqualTo(120));
      expect(() => jsonDecode(cut), returnsNormally);
    });
  });

  test('isJson', () {
    expect(isJson('{"a":1}'), isTrue);
    expect(isJson('"text"'), isTrue);
    expect(isJson('12'), isTrue);
    expect(isJson('null'), isTrue);
    expect(isJson('plain text'), isFalse);
    expect(isJson('{"a":'), isFalse);
    expect(isJson(''), isFalse);
  });

  group('valuePreparer', () {
    test('masks first, then cuts', () {
      var limits = 0;
      final prepare = valuePreparer(
        mask: (value) => value.replaceAll('secret', '*'),
        maxLength: 40,
        onLimit: () => limits++,
      );

      expect(prepare('a secret'), 'a *');
      expect(limits, 0);

      final cut = prepare('secret ${'x' * 100}');
      expect(cut.length, lessThanOrEqualTo(40));
      expect(cut, startsWith('* xxx'));
      expect(limits, 1);
    });

    test('a value that only fits after masking is not cut', () {
      var limits = 0;
      final prepare = valuePreparer(
        mask: (value) => value.replaceAll(RegExp('x+'), 'x'),
        maxLength: 10,
        onLimit: () => limits++,
      );
      expect(prepare('x' * 100), 'x');
      expect(limits, 0);
    });

    test('JSON stays JSON, also when the mask broke it', () {
      final prepare = valuePreparer(
        mask: (value) => value.replaceAll('"', "'"),
        maxLength: 80,
        onLimit: () {},
      );
      final cut = prepare(jsonEncode({'k': 'v' * 200}));
      expect(cut.length, lessThanOrEqualTo(80));
      expect((jsonDecode(cut) as Map)['truncated'], isTrue);
    });

    test('a negative limit and no mask change nothing', () {
      final prepare =
          valuePreparer(mask: null, maxLength: -1, onLimit: () => fail('no limit'));
      final long = 'x' * 10000;
      expect(prepare(long), same(long));
    });
  });

  test('fitValue cuts JSON as JSON and text as text', () {
    expect((jsonDecode(fitValue(jsonEncode('x' * 200), 80)) as Map)['truncated'], isTrue);
    expect(fitValue('x' * 200, 80), contains(truncationMarker));
    expect(fitValue('fits', 80), 'fits');
  });

  test('metadataKey makes a key safe to be part of an attribute name', () {
    expect(metadataKey('plain'), 'plain');
    expect(metadataKey('a.b.c'), 'a_b_c');
    expect(metadataKey('  padded  '), 'padded');
    expect(metadataKey(''), '_');
    expect(metadataKey('   '), '_');
    expect(metadataKey('__proto__'), '___proto__');
    expect(metadataKey('constructor'), '_constructor');
    expect(metadataKey('prototype'), '_prototype');
  });

  test('the outputs of an observation that did not finish normally', () {
    expect(jsonDecode(errorOutput('boom')), {'error': 'boom'});
    expect(
      jsonDecode(cancelledOutput('stop')),
      {'status': 'cancelled', 'cause': 'stop'},
    );
    expect(
      jsonDecode(interruptedOutput('approval')),
      {'status': 'interrupted', 'cause': 'approval'},
    );
  });

  test('collapseValues', () {
    expect(collapseValues(['only']), 'only');
    expect(collapseValues([1, 2]), [1, 2]);
    expect(collapseValues([]), isEmpty);
    expect(collapseValues([null]), isNull);
  });

  group('toJsonValue', () {
    test('JSON values stay what they are', () {
      expect(toJsonValue(null), isNull);
      expect(toJsonValue('s'), 's');
      expect(toJsonValue(1), 1);
      expect(toJsonValue(1.5), 1.5);
      expect(toJsonValue(true), isTrue);
      expect(toJsonValue(double.nan), 'NaN');
      expect(toJsonValue(double.infinity), 'Infinity');
    });

    test('messages are written without the fields they do not have', () {
      final message = Message.assistant(
        'calling',
        toolCalls: const [
          ToolCall(
            id: 'c1',
            function: FunctionCall(name: 'search', arguments: '{"q":1}'),
          ),
        ],
      );

      final json = toJsonValue(message)! as Map<String, Object?>;
      expect(json['role'], 'assistant');
      expect(json['content'], 'calling');
      expect(json.keys, isNot(contains('name')));
      expect(json.keys, isNot(contains('toolCallId')));
      final call = (json['toolCalls']! as List).single as Map;
      expect(call['id'], 'c1');
      expect((call['function'] as Map)['name'], 'search');
      expect(json.values, everyElement(isNotNull));
      expect(() => jsonEncode(json), returnsNormally);
    });

    test('collections are converted element by element', () {
      expect(
        toJsonValue({
          1: [Message.user('a'), null],
          'set': {'x'},
          'colour': _Colour.red,
        }),
        {
          '1': [
            {'role': 'user', 'content': 'a'},
            null,
          ],
          'set': ['x'],
          'colour': 'red',
        },
      );
    });

    test('documents, tool infos and tool results', () {
      const doc = Document(id: 'd1', content: 'text');
      expect(
        (toJsonValue(doc)! as Map)..removeWhere((key, value) => key == 'metadata'),
        containsPair('id', 'd1'),
      );
      expect(
        ((toJsonValue(const DocumentSource(uri: 'file:///a'))! as Map)['uri']),
        'file:///a',
      );
      final info = ToolInfo.fromJsonSchema(
        name: 'search',
        schema: JSONSchema(type: 'object', properties: const {}),
      );
      expect(jsonEncode(toJsonValue(info)), contains('"search"'));
      expect(jsonEncode(toJsonValue(ToolResult.text('ok'))), contains('"ok"'));
    });

    test('the callback payloads of the components', () {
      const doc = Document(id: 'd1', content: 'text');

      expect(
        toJsonValue(
          ModelCallbackInput(
            messages: [Message.user('q')],
            toolChoice: ToolChoice.forced,
            config: const ModelCallbackConfig(model: 'm', temperature: 0.1),
          ),
        ),
        {
          'messages': [
            {'role': 'user', 'content': 'q'},
          ],
          'toolChoice': 'forced',
          'config': {'model': 'm', 'temperature': 0.1},
        },
      );
      expect(
        toJsonValue(
          ModelCallbackOutput(
            message: Message.assistant('a'),
            tokenUsage: const TokenUsage(
              promptTokens: 1,
              completionTokens: 2,
              totalTokens: 3,
            ),
          ),
        ),
        {
          'message': {'role': 'assistant', 'content': 'a'},
          'tokenUsage': {
            'promptTokens': 1,
            'completionTokens': 2,
            'totalTokens': 3,
          },
        },
      );
      expect(
        toJsonValue(const PromptCallbackInput(variables: {'name': 'Ada'})),
        {
          'variables': {'name': 'Ada'},
        },
      );
      expect(
        toJsonValue(PromptCallbackOutput(result: [Message.user('Hi Ada')])),
        {
          'result': [
            {'role': 'user', 'content': 'Hi Ada'},
          ],
        },
      );
      expect(
        toJsonValue(const ToolCallbackInput(argumentsJson: '{"q":1}')),
        {'argumentsJson': '{"q":1}'},
      );
      expect(
        toJsonValue(const ToolCallbackOutput(response: 'done')),
        {'response': 'done'},
      );
      expect(
        toJsonValue(
          const EmbeddingCallbackInput(
            texts: ['a', 'b'],
            config: EmbeddingCallbackConfig(model: 'e'),
          ),
        ),
        {
          'texts': ['a', 'b'],
          'config': {'model': 'e'},
        },
      );
      expect(
        toJsonValue(
          const EmbeddingCallbackOutput(
            embeddings: [
              [0.1, 0.2, 0.3],
              [0.4, 0.5, 0.6],
            ],
          ),
        ),
        {'embeddings': 2, 'dimensions': 3},
        reason: 'the vectors themselves are not exported',
      );
      expect(
        toJsonValue(const RetrieverCallbackInput(query: 'q', topK: 3)),
        {'query': 'q', 'topK': 3},
      );
      expect(
        ((toJsonValue(const RetrieverCallbackOutput(docs: [doc]))! as Map)['docs']
                as List)
            .single,
        containsPair('content', 'text'),
      );
      expect(
        (toJsonValue(const IndexerCallbackInput(docs: [doc]))! as Map).keys,
        ['docs'],
      );
      expect(
        toJsonValue(const IndexerCallbackOutput(ids: ['1', '2'])),
        {
          'ids': ['1', '2'],
        },
      );
      expect(
        toJsonValue(
          const LoaderCallbackInput(source: DocumentSource(uri: 'file:///a')),
        ),
        {
          'source': {'uri': 'file:///a'},
        },
      );
      expect(
        (toJsonValue(
          const LoaderCallbackOutput(
            docs: [doc],
            source: DocumentSource(uri: 'file:///a'),
          ),
        )! as Map)
            .keys,
        ['source', 'docs'],
      );
      expect(
        (toJsonValue(const TransformerCallbackInput(input: [doc]))! as Map).keys,
        ['input'],
      );
      expect(
        (toJsonValue(const TransformerCallbackOutput(output: [doc]))! as Map).keys,
        ['output'],
      );
    });

    test('other objects use their toJson, or their toString', () {
      expect(toJsonValue(_WithToJson()), {'kind': 'custom', 'missing': null});
      expect(toJsonValue(_Plain()), 'a plain object');
      expect(toJsonValue(Uri.parse('https://x.dev/a')), 'https://x.dev/a');
      expect(toJsonValue(const Duration(seconds: 2)), '0:00:02.000000');
      expect(
        toJsonValue(DateTime.utc(2026, 11, 5, 12)),
        '2026-11-05T12:00:00.000Z',
      );
    });

    test('streams are named, not read', () {
      expect(toJsonValue(const Stream<int>.empty()), '<stream>');
      expect(toJsonValue(StreamReader.fromIterable([1])), '<stream>');
    });

    test('a message whose extra contains itself is still written', () {
      final extra = <String, dynamic>{'note': 'x'};
      extra['self'] = extra;
      final message = Message.assistant('hi').copyWith(extra: extra);

      final encoded = encodeJson(message);
      expect(encoded, isNotNull);
      expect(jsonDecode(encoded!), containsPair('content', 'hi'));
      expect(encoded.length, lessThan(2000));
    });

    test('nesting without an end stops', () {
      final loop = <String, Object?>{};
      loop['self'] = loop;
      expect(() => toJsonValue(loop), returnsNormally);

      // Below a fixed depth the rest is written as its `toString()`.
      final encoded = encodeJson(loop)!;
      expect(() => jsonDecode(encoded), returnsNormally);
      expect(encoded.length, lessThan(1000));
      expect(encoded, endsWith('"{self: {...}}"${'}' * 33}'));
    });
  });

  test('encodeJson returns null for what cannot be encoded', () {
    expect(encodeJson({'a': 1}), '{"a":1}');
    expect(encodeJson(_Plain()), '"a plain object"');
    expect(encodeJson(_Throwing()), isNull);
  });
}

final class _Throwing {
  Map<String, Object?> toJson() => throw StateError('no');
}
