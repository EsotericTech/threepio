// Tests of the two ready-made tool middlewares.
//
// * `JsonFixMiddleware`: port of eino-examples
//   `components/tool/middlewares/jsonfix/json_fix_middleware_test.go`, every
//   test of the file, and after them tests that are not in Go (the enhanced
//   parts, `repair` on its own, random input).
// * `ErrorRemoverMiddleware`: the Go package has no tests. These are written
//   from `components/tool/middlewares/errorremover/errorremover.go` and its
//   `example/main.go`.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

typedef _Json = Map<String, Object?>;

/// Go `echoEndpoint`.
Future<ToolCallOutput> _echoEndpoint(RunContext ctx, ToolCallInput input) async =>
    ToolCallOutput(input.arguments);

/// Go `spyInvokable`: returns its arguments.
final class _SpyInvokable extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: 'spy', description: '');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      argumentsJson;
}

/// An error whose text is exactly [text], like a Go `errors.New(text)`.
final class _GoError implements Exception {
  const _GoError(this.text);

  final String text;

  @override
  String toString() => text;
}

/// What a tool throws to pause the run.
final class _Pause implements InterruptSignal {
  const _Pause();

  @override
  String toString() => '_Pause';
}

final class _Invokable extends InvokableTool {
  _Invokable(this.name, this._run);

  final String name;
  final FutureOr<String> Function(RunContext ctx, String arguments) _run;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: name);

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      _run(ctx, argumentsJson);
}

final class _Streamable extends StreamableTool {
  _Streamable(this.name, this._run);

  final String name;
  final FutureOr<StreamReader<String>> Function(RunContext ctx, String arguments)
      _run;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: name);

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      _run(ctx, argumentsJson);
}

final class _EnhancedInvokable implements EnhancedInvokableTool {
  _EnhancedInvokable(this.name, this._run);

  final String name;
  final FutureOr<ToolResult> Function(RunContext ctx, String arguments) _run;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: name);

  @override
  Future<ToolResult> enhancedInvokableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      _run(ctx, argument.text);
}

final class _EnhancedStreamable implements EnhancedStreamableTool {
  _EnhancedStreamable(this.name, this._run);

  final String name;
  final FutureOr<StreamReader<ToolResult>> Function(
    RunContext ctx,
    String arguments,
  ) _run;

  @override
  Future<ToolInfo> info() async => ToolInfo.function(name: name);

  @override
  Future<StreamReader<ToolResult>> enhancedStreamableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      _run(ctx, argument.text);
}

/// An assistant message with one tool call per `(id, name, arguments)`.
Message _calls(List<(String, String, String)> calls) => Message.assistant(
      '',
      toolCalls: [
        for (final (id, name, arguments) in calls)
          ToolCall(
            id: id,
            function: FunctionCall(name: name, arguments: arguments),
          ),
      ],
    );

/// Reads [reader] to its end and closes it. The loop is bounded: a stream
/// that does not end fails the test instead of hanging it.
Future<List<T>> _readAll<T>(StreamReader<T> reader, {int limit = 500}) async {
  final chunks = <T>[];
  try {
    for (var i = 0; i <= limit; i++) {
      try {
        chunks.add(await reader.recv());
      } on StreamEOFException {
        return chunks;
      }
    }
    fail('the stream did not end within $limit chunks');
  } finally {
    await reader.close();
  }
}

/// The text of the first input part of [message], where an enhanced tool
/// puts its result.
String? _firstPartText(Message message) =>
    message.userInputMultiContent?.first.text;

/// The default text of the error remover.
String _failed(String tool, String error) =>
    "Failed to call tool '$tool', error message: '$error'";

/// A random JSON value, at most [depth] levels deep.
Object? _randomJson(Random random, int depth) {
  const alphabet = '{}[]",:\'\\ abc123\n';
  String text() => String.fromCharCodes([
        for (var i = random.nextInt(8); i > 0; i--)
          alphabet.codeUnitAt(random.nextInt(alphabet.length)),
      ]);
  final kind = random.nextInt(depth <= 0 ? 5 : 7);
  return switch (kind) {
    0 => text(),
    1 => random.nextInt(2000) - 1000,
    2 => random.nextInt(2000) / 8,
    3 => random.nextBool(),
    4 => null,
    5 => [for (var i = random.nextInt(4); i > 0; i--) _randomJson(random, depth - 1)],
    _ => {
        for (var i = random.nextInt(4); i > 0; i--)
          text(): _randomJson(random, depth - 1),
      },
  };
}

void main() {
  final ctx = RunContext.background();

  group('JsonFixMiddleware', () {
    test('TestInvokableMiddleware_RepairsJSON', () async {
      final mw = JsonFixMiddleware().invokable!;
      final chained = mw(_echoEndpoint);

      const input = ToolCallInput(
        name: 'test_tool',
        arguments: 'noise <|FunctionCallBegin|>{"a":1}<|FunctionCallEnd|> more',
        callId: 'id1',
      );

      final out = await chained(ctx, input);
      final m = jsonDecode(out.result) as _Json;
      expect(m['a'], 1);
    });

    test('TestStreamableMiddleware_RepairsJSON', () async {
      final mw = JsonFixMiddleware().streamable!;
      late String captured;
      Future<StreamToolCallOutput> next(
        RunContext ctx,
        ToolCallInput input,
      ) async {
        captured = input.arguments;
        return StreamToolCallOutput(StreamReader.fromIterable(['ok']));
      }

      final chained = mw(next);
      final out = await chained(
        ctx,
        const ToolCallInput(
          name: 't',
          arguments: '{"text": "He said "hello" to me"}',
          callId: '',
        ),
      );
      final m = jsonDecode(captured) as _Json;
      expect(m['text'], 'He said "hello" to me');
      // The stream of the tool is passed on.
      expect(await _readAll(out.result), ['ok']);
    });

    test('TestInvokableMiddleware_NoChangeForValidJSON', () async {
      final mw = JsonFixMiddleware().invokable!;
      final chained = mw(_echoEndpoint);

      const original = '{"a":1}';
      final out = await chained(
        ctx,
        const ToolCallInput(name: 't', arguments: original, callId: ''),
      );
      expect(out.result, original);
    });

    group('TestInvokableMiddleware_MissingBracesAndUnicode', () {
      const inputs = {
        'missing tail': '{"key":"value"',
        'missing head': '"key":"value"}',
        'emoji': '{"emoji": "😀😎"}',
        'line break and tab in a string':
            '{"text": "line1\nline2\tTabbed"}',
      };
      // What each is repaired to. Go only asks for an object of strings.
      const repaired = {
        'missing tail': {'key': 'value'},
        'missing head': {'key': 'value'},
        'emoji': {'emoji': '😀😎'},
        'line break and tab in a string': {'text': 'line1\nline2\tTabbed'},
      };

      for (final MapEntry(key: name, value: input) in inputs.entries) {
        test(name, () async {
          final chained = JsonFixMiddleware().invokable!(_echoEndpoint);

          final out = await chained(
            ctx,
            ToolCallInput(name: 't', arguments: input, callId: ''),
          );
          final any = jsonDecode(out.result);
          expect(any, isA<_Json>());
          expect((any as _Json).values, everyElement(isA<String>()));
          expect(any, repaired[name]);
        });
      }
    });

    test('TestToolsNodeMiddleware_RepairsInvokable', () async {
      final tn = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [_SpyInvokable()],
          toolCallMiddlewares: [JsonFixMiddleware()],
        ),
      );
      final msg = _calls([('1', 'spy', 'garbage {"x": "a "quote" b"} tail')]);

      final outs = await tn.invokeTools(ctx, msg);
      expect(outs, hasLength(1));
      final m = jsonDecode(outs[0].content) as _Json;
      expect(m['x'], 'a "quote" b');

      // The node streams an invokable tool through the same part.
      final chunks = await _readAll(await tn.streamTools(ctx, msg));
      expect(concatMessageArray(chunks), outs);
    });

    group(
        'TestInvokableMiddleware_'
        'UnescapedBackslashesAndSingleQuotesAndTrailingComma', () {
      const cases = {
        // unescaped backslashes in Windows path
        'unescaped backslashes': r'{"path": "C:\Users\name\file.txt"}',
        // single-quoted JSON
        'single quotes': "{'a': 'b'}",
        // trailing comma
        'trailing comma': '{"a": 1, "b": 2, }',
      };

      for (final MapEntry(key: name, value: input) in cases.entries) {
        test(name, () async {
          final chained = JsonFixMiddleware().invokable!(_echoEndpoint);

          final out = await chained(
            ctx,
            ToolCallInput(name: 't', arguments: input, callId: ''),
          );
          expect(jsonDecode(out.result), isA<_Json>());
        });
      }

      test('what they are repaired to', () {
        expect(jsonDecode(JsonFixMiddleware.repair(cases['single quotes']!)), {
          'a': 'b',
        });
        expect(jsonDecode(JsonFixMiddleware.repair(cases['trailing comma']!)), {
          'a': 1,
          'b': 2,
        });
        final path =
            (jsonDecode(JsonFixMiddleware.repair(cases['unescaped backslashes']!))
                as _Json)['path'];
        // `\U` is no escape and stays; `\n` and `\f` are escapes, and no
        // repair can tell that they were not meant.
        expect(path, startsWith(r'C:\Users'));
        expect(path, endsWith('ile.txt'));
      });
    });

    test('TestInvokableMiddleware_RawQuotesInsideStringValue', () async {
      final mw = JsonFixMiddleware().invokable!;
      final chained = mw(_echoEndpoint);

      // invalid JSON: raw quotes inside value
      const input = '{"a":"b"1""}';
      final out = await chained(
        ctx,
        const ToolCallInput(name: 't', arguments: input, callId: ''),
      );
      final m = jsonDecode(out.result) as _Json;
      expect(m.values, everyElement(isA<String>()));
      final v = m['a']! as String;
      expect(v, isNotEmpty);
      expect(v[0], 'b');
    });

    test('every part repairs the arguments and leaves the rest of the call',
        () async {
      final middleware = JsonFixMiddleware();
      const options = ToolOptions(extensions: ['option']);
      const input = ToolCallInput(
        name: 'tool',
        arguments: "noise {'a': 1,} more",
        callId: 'call-1',
        callOptions: options,
      );
      final passed = <ToolCallInput>[];

      await middleware.invokable!((ctx, input) async {
        passed.add(input);
        return const ToolCallOutput('');
      })(ctx, input);
      await middleware.streamable!((ctx, input) async {
        passed.add(input);
        return StreamToolCallOutput(StreamReader.fromIterable(const []));
      })(ctx, input);
      await middleware.enhancedInvokable!((ctx, input) async {
        passed.add(input);
        return const EnhancedToolCallOutput(ToolResult());
      })(ctx, input);
      await middleware.enhancedStreamable!((ctx, input) async {
        passed.add(input);
        return EnhancedStreamToolCallOutput(
          StreamReader.fromIterable(const []),
        );
      })(ctx, input);

      expect(passed, hasLength(4));
      for (final call in passed) {
        expect(call.arguments, '{"a":1}');
        expect(call.name, 'tool');
        expect(call.callId, 'call-1');
        expect(call.callOptions, same(options));
      }
      // The call the middleware was given is not changed.
      expect(input.arguments, "noise {'a': 1,} more");
    });

    test('in a tools node it repairs the arguments of every kind of tool',
        () async {
      final seen = <String>[];
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          executeSequentially: true,
          tools: [
            _Invokable('inv', (ctx, arguments) {
              seen.add(arguments);
              return 'r';
            }),
            _Streamable('str', (ctx, arguments) {
              seen.add(arguments);
              return StreamReader.fromIterable(['r']);
            }),
            _EnhancedInvokable('einv', (ctx, arguments) {
              seen.add(arguments);
              return ToolResult.text('r');
            }),
            _EnhancedStreamable('estr', (ctx, arguments) {
              seen.add(arguments);
              return StreamReader.fromIterable([ToolResult.text('r')]);
            }),
          ],
          toolCallMiddlewares: [JsonFixMiddleware()],
        ),
      );
      const broken = '<|FunctionCallBegin|>{"q": "x"<|FunctionCallEnd|>';
      final input = _calls([
        ('1', 'inv', broken),
        ('2', 'str', broken),
        ('3', 'einv', broken),
        ('4', 'estr', broken),
      ]);

      await node.invokeTools(ctx, input);
      expect(seen, List.filled(4, '{"q": "x"}'));

      seen.clear();
      await _readAll(await node.streamTools(ctx, input));
      expect(seen, List.filled(4, '{"q": "x"}'));
    });

    test('what the tool throws passes through it', () async {
      const signal = _Pause();
      const failure = _GoError('no');
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable('pause', (ctx, arguments) => throw signal),
            _Invokable('fail', (ctx, arguments) => throw failure),
          ],
          toolCallMiddlewares: [JsonFixMiddleware()],
        ),
      );

      await expectLater(
        node.invokeTools(ctx, _calls([('1', 'pause', '{')])),
        throwsA(same(signal)),
      );
      await expectLater(
        node.invokeTools(ctx, _calls([('1', 'fail', '{')])),
        throwsA(
          isA<ToolsNodeException>().having((e) => e.cause, 'cause', same(failure)),
        ),
      );
    });

    group('repair', () {
      const repair = JsonFixMiddleware.repair;

      test('a valid JSON object is returned as it is, without the blanks '
          'around it', () {
        const valid = '{ "a" : [1, 2.50, {"b": null}],\n  "c": "x\\ny" }';
        expect(repair(valid), valid);
        expect(repair('  \n$valid\t '), valid);
        expect(repair('{}'), '{}');
      });

      test('text around a valid object is cut off', () {
        expect(repair('Sure! Here you go: {"a": 1} Hope that helps.'), '{"a": 1}');
        expect(repair('```json\n{"a": 1}\n```'), '{"a": 1}');
        expect(repair('<think>{"a": 1}'), '{"a": 1}');
        expect(
          repair('<|FunctionCallBegin|>{"a": 1}<|FunctionCallEnd|>'),
          '{"a": 1}',
        );
      });

      test('the tokens of a function call are removed where no object is '
          'closed', () {
        expect(repair('<|FunctionCallBegin|>[1, 2]<|FunctionCallEnd|>'), '[1, 2]');
        expect(repair('<think>[1, 2]'), '[1, 2]');
        expect(
          jsonDecode(repair('<|FunctionCallBegin|>{"a": 1<|FunctionCallEnd|>')),
          {'a': 1},
        );
      });

      test('a missing brace is added', () {
        expect(repair('{"a": 1'), '{"a": 1}');
        expect(repair('"a": 1}'), '{"a": 1}');
        expect(repair('{'), '{}');
        // A brace further in counts as the last one, so none is added; the
        // lenient reading closes the object.
        expect(jsonDecode(repair('{"a": {"b": 1}')), {
          'a': {'b': 1},
        });
      });

      test('valid JSON that is not an object is returned as it is', () {
        for (final text in ['[1,2,3]', '"hello"', '42', 'true', 'null']) {
          expect(repair(text), text);
        }
      });

      test('nothing to repair: an empty text stays empty', () {
        expect(repair(''), '');
        expect(repair(' \n\t'), '');
      });

      test('what is still not JSON is read leniently', () {
        final cases = <String, Object?>{
          // unquoted keys
          '{a: 1, b: "x"}': {'a': 1, 'b': 'x'},
          // single quotes, with a double quote inside
          "{'a': 'say \"hi\"'}": {'a': 'say "hi"'},
          // trailing commas
          '{"a": [1, 2, ], }': {
            'a': [1, 2],
          },
          // unclosed array and object
          '{"a": [1, {"b": "c"': {
            'a': [
              1,
              {'b': 'c'},
            ],
          },
          // words and numbers
          '{"a": true, "b": false, "c": null, "d": -1.5e3, "e": word}': {
            'a': true,
            'b': false,
            'c': null,
            'd': -1500.0,
            'e': 'word',
          },
          // escapes
          r'{"a": "tab\there \u00e9 \"q\" back\\slash \/"}': {
            'a': 'tab\there é "q" back\\slash /',
          },
          // a key without a value
          '{"a":}': {'a': null},
          '{"a":': {'a': null},
        };
        for (final MapEntry(key: text, value: expected) in cases.entries) {
          expect(jsonDecode(repair(text)), expected, reason: text);
        }
      });

      // What the Go function `repair` of eino-examples jsonfix returns for
      // the same input, taken from a run of the Go code with
      // kaptinlin/jsonrepair v0.2.4. The two are compared as JSON values:
      // jsonrepair patches the text, the lenient reader writes the value
      // anew, so blanks and the spelling of numbers differ.
      test('it repairs these as the Go jsonfix does', () {
        const goOutputs = <String, String>{
          // The inputs of the Go tests.
          'noise <|FunctionCallBegin|>{"a":1}<|FunctionCallEnd|> more':
              '{"a":1}',
          '{"text": "He said "hello" to me"}':
              r'{"text": "He said \"hello\" to me"}',
          '{"key":"value"': '{"key":"value"}',
          '"key":"value"}': '{"key":"value"}',
          '{"text": "line1\nline2\tTabbed"}':
              r'{"text": "line1\nline2\tTabbed"}',
          'garbage {"x": "a "quote" b"} tail': r'{"x": "a \"quote\" b"}',
          "{'a': 'b'}": '{"a": "b"}',
          '{"a": 1, "b": 2, }': '{"a": 1, "b": 2 }',
          // Cut off.
          '{"query": "hello world", "limit": 1':
              '{"query": "hello world", "limit": 1}',
          '{"query": "hello world", "nested": {"a": 1':
              '{"query": "hello world", "nested": {"a": 1}}',
          '{"query": "hello world",': '{"query": "hello world"}',
          '{"query":': '{"query":null}',
          '{"a": [1, {"b": "c"': '{"a": [1, {"b": "c"}]}',
          '{"a": [1, {"b": 2': '{"a": [1, {"b": 2}]}',
          '[1, 2': '[1, 2]',
          '{': '{}',
          // Wrapped.
          '```json\n{"a": 1,}\n```': '{"a": 1}',
          '```\n{"a": 1}\n```': '{"a": 1}',
          "Here: {'url': 'web_url',}": '{"url": "web_url"}',
          '<think>thinking</think>{"a": 1}': '{"a": 1}',
          '<think>{"a": 1': '{"a": 1}',
          '{"a": 1}<|FunctionCallEnd|>': '{"a": 1}',
          '<|FunctionCallBegin|>{"a": 1}': '{"a": 1}',
          '<|FunctionCallBegin|>"a": 1}<|FunctionCallEnd|>': '{"a": 1}',
          '<|FunctionCallBegin|>{"a": 1<|FunctionCallEnd|>': '{"a": 1}',
          '<|FunctionCallBegin|>[1, 2]<|FunctionCallEnd|>': '[1, 2]',
          '{"a": "<|FunctionCallEnd|>"}': '{"a": "<|FunctionCallEnd|>"}',
          '{"a": 1};': '{"a": 1}',
          '{"city": "New York", "units": "metric"}}':
              '{"city": "New York", "units": "metric"}',
          '\ufeff{"a": 1}': '{"a": 1}',
          // Quotes, keys and commas.
          '{a: 1, b: "x"}': '{"a": 1, "b": "x"}',
          '{query: hello world}': '{"query": "hello world"}',
          "{'a': 'say \"hi\"'}": r'{"a": "say \"hi\""}',
          '{"a": \'b\', "c": \'d"e\'}': r'{"a": "b", "c": "d\"e"}',
          '{"html": "<a href="x">y</a>"}': r'{"html": "<a href=\"x\">y</a>"}',
          '{"a": [1, 2, ], }': '{"a": [1, 2 ] }',
          '{"a": ["x", "y",], "b": {"c": 1,},}':
              '{"a": ["x", "y"], "b": {"c": 1}}',
          '{,}': '{}',
          // Values.
          '{"a": true, "b": false, "c": null, "d": -1.5e3, "e": word}':
              '{"a": true, "b": false, "c": null, "d": -1.5e3, "e": "word"}',
          '{"a": tru}': '{"a": "tru"}',
          '{"a": 12abc}': '{"a": "12abc"}',
          '{"a": 1.}': '{"a": 1.0}',
          '{"a":}': '{"a":null}',
          r'{"regex": "\d+\.\d+"}': r'{"regex": "\\d+\\.\\d+"}',
          '{"a": "tab\there"}': r'{"a": "tab\there"}',
          // Not an object.
          'hello': '"hello"',
          'city=New York': '"city=New York"',
          '[1, 2]': '[1, 2]',
          'null': 'null',
          '': '',
        };
        for (final MapEntry(key: text, value: go) in goOutputs.entries) {
          final repaired = repair(text);
          if (go.isEmpty) {
            expect(repaired, isEmpty, reason: jsonEncode(text));
          } else {
            expect(jsonDecode(repaired), jsonDecode(go), reason: jsonEncode(text));
          }
        }
      });

      group('repairs checked against the Go jsonfix (Go outputs from a run of '
          'the Go code, jsonrepair v0.2.4)', () {
        test(
          'it never throws: NaN, Infinity and a number too large for a double',
          () {
            for (final text in [
              '{"a": NaN}',
              '{"a": Infinity}',
              '{"a": -Infinity}',
              "{'a': 1e999}",
              'NaN',
              '[NaN]',
            ]) {
              expect(() => repair(text), returnsNormally, reason: text);
            }
            // Go: {"a": "NaN"}, {"a": "Infinity"}, {"a": "-Infinity"}.
            expect(jsonDecode(repair('{"a": NaN}')), {'a': 'NaN'});
            expect(jsonDecode(repair('{"a": -Infinity}')), {'a': '-Infinity'});
          },
        );

        test(
          'arguments cut off inside a string: the brace that is added does not '
          'become part of the string',
          () {
            expect(jsonDecode(repair('{"query": "hello wor')), {
              'query': 'hello wor',
            });
            expect(jsonDecode(repair('{"a": [1, {"b": "c')), {
              'a': [
                1,
                {'b': 'c'},
              ],
            });
            expect(jsonDecode(repair('{"a": {"b": {"c": {"d": "deep')), {
              'a': {
                'b': {
                  'c': {'d': 'deep'},
                },
              },
            });
          },
        );

        test(
          'arguments cut off inside an array get no element they did not have',
          () {
            expect(jsonDecode(repair('{"q": "x", "tags": ["a", "b"')), {
              'q': 'x',
              'tags': ['a', 'b'],
            });
            expect(jsonDecode(repair('{"a": [1, 2')), {
              'a': [1, 2],
            });
            expect(jsonDecode(repair('{"a": [')), {'a': <Object?>[]});
          },
        );

        test(
          'the backslashes of a Windows path stay backslashes',
          () {
            // The input of the Go test
            // TestInvokableMiddleware_UnescapedBackslashesAndSingleQuotesAndTrailingComma,
            // which only asks that the result is JSON.
            expect(
              jsonDecode(repair(r'{"path": "C:\Users\name\file.txt"}')),
              {'path': r'C:\Users\name\file.txt'},
            );
            expect(
              jsonDecode(repair(r'{"p": "D:\data\reports\final.pdf", "n": 1}')),
              {'p': r'D:\data\reports\final.pdf', 'n': 1},
            );
          },
        );

        test(
          'malformations jsonrepair repairs and the lenient reader as well',
          () {
            const goOutputs = <String, String>{
              // a missing comma
              '{"a": "x" "b": "y"}': '{"a": "x", "b": "y"}',
              '{"a": 1 "b": 2}': '{"a": 1, "b": 2}',
              '{"a": [1 2 3]}': '{"a": [1, 2, 3]}',
              // Python and JavaScript words
              '{"a": None, "b": True, "c": False}':
                  '{"a": null, "b": true, "c": false}',
              '{"a": undefined}': '{"a": null}',
              // comments
              '{"a": "x", // comment\n "b": 2}': '{"a": "x", \n "b": 2}',
              '{"a": "x", /* c */ "b": 2}': '{"a": "x",  "b": 2}',
              // typographic quotes
              '{\u201ca\u201d: \u201cb\u201d}': '{"a": "b"}',
              // a closing bracket too many
              '{"a": 1]]': '{"a": 1}',
              // several values
              '[{"a": 1}, {"b": 2}': '[\n{"a": 1}, {"b": 2}\n]',
            };
            for (final MapEntry(key: text, value: go) in goOutputs.entries) {
              expect(
                jsonDecode(repair(text)),
                jsonDecode(go),
                reason: jsonEncode(text),
              );
            }
          },
        );
      });

      test('deep nesting does not overflow', () {
        for (final text in [
          '[' * 2000,
          '{"a":' * 2000,
          '${'[' * 2000}1${']' * 1999}',
          '{' * 2000,
        ]) {
          expect(() => repair(text), returnsNormally, reason: text.substring(0, 8));
        }
      });

      test('it ends and does not throw, whatever it is given', () {
        const alphabet = '{}[]",:\'\\ abc123\n';
        final random = Random(20261105);
        String randomText() => String.fromCharCodes([
              for (var i = random.nextInt(61); i > 0; i--)
                alphabet.codeUnitAt(random.nextInt(alphabet.length)),
            ]);

        final failures = <String>[];
        void tryRepair(String text) {
          try {
            JsonFixMiddleware.repair(text);
          } on Object catch (error) {
            failures.add('${jsonEncode(text)}: $error');
          }
        }

        for (var i = 0; i < 400; i++) {
          final text = randomText();
          expect(text.length, lessThanOrEqualTo(60));
          tryRepair(text);
          // The same in braces, so that most of them are read leniently as
          // an object.
          tryRepair('{$text}');
        }
        expect(failures, isEmpty);
      });

      test('random valid JSON objects are returned unchanged', () {
        final random = Random(4);
        const indented = JsonEncoder.withIndent('  ');
        for (var i = 0; i < 300; i++) {
          final object = <String, Object?>{
            for (var k = random.nextInt(5); k > 0; k--)
              'k$k': _randomJson(random, 3),
          };
          final compact = jsonEncode(object);
          expect(repair(compact), compact);
          final pretty = indented.convert(object);
          expect(repair(pretty), pretty);
          expect(repair('\n $compact \n'), compact);
        }
      });
    });
  });

  group('ErrorRemoverMiddleware', () {
    const input = ToolCallInput(name: 'web_search', arguments: '{}', callId: '1');
    const notFound = _GoError('not found web url');
    final text = _failed('web_search', 'not found web url');

    // errorremover/example/main.go
    test('example: the failed call of web_search becomes a result', () async {
      // 1. Create a mock "web_search" tool. The tool call always fails.
      final searcher = FunctionTool<String, String>(
        name: 'web_search',
        description: 'search content for web url',
        params: const ParamsOneOf.params({
          'url': ParameterInfo(type: DataType.string),
        }),
        fromJson: (json) => json['url']! as String,
        invoke: (ctx, url, options) => throw notFound,
      );

      // 2. Create a tools node and inject the middleware.
      final tn = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [searcher],
          toolCallMiddlewares: [ErrorRemoverMiddleware()],
        ),
      );

      final msg = _calls([('1', 'web_search', '{"url":"web_url"}')]);

      // 4. Although the underlying tool fails, the call succeeds.
      final outs = await tn.invokeTools(ctx, msg);

      // 5. The content is the text of the error handler.
      expect(outs, [
        Message.tool(
          content: "Failed to call tool 'web_search', error message: "
              "'not found web url'",
          toolCallId: '1',
          toolName: 'web_search',
        ),
      ]);

      final chunks = await _readAll(await tn.streamTools(ctx, msg));
      expect(chunks, [outs]);
    });

    group('each part turns a failure into the text', () {
      test('invokable', () async {
        final endpoint = ErrorRemoverMiddleware().invokable!(
          (ctx, input) async => throw notFound,
        );
        expect((await endpoint(ctx, input)).result, text);
      });

      test('streamable', () async {
        final endpoint = ErrorRemoverMiddleware().streamable!(
          (ctx, input) async => throw notFound,
        );
        expect(await _readAll((await endpoint(ctx, input)).result), [text]);
      });

      test('enhanced invokable', () async {
        final endpoint = ErrorRemoverMiddleware().enhancedInvokable!(
          (ctx, input) async => throw notFound,
        );
        expect((await endpoint(ctx, input)).result, ToolResult.text(text));
      });

      test('enhanced streamable', () async {
        final endpoint = ErrorRemoverMiddleware().enhancedStreamable!(
          (ctx, input) async => throw notFound,
        );
        expect(
          await _readAll((await endpoint(ctx, input)).result),
          [ToolResult.text(text)],
        );
      });

      test('an endpoint that throws before it returns a future', () async {
        ToolCallOutput fail() => throw notFound;
        final endpoint = ErrorRemoverMiddleware().invokable!(
          (ctx, input) => Future.value(fail()),
        );
        expect((await endpoint(ctx, input)).result, text);
      });
    });

    group('in a tools node', () {
      late ToolsNode node;

      setUp(() async {
        node = await ToolsNode.create(
          ToolsNodeConfig(
            tools: [
              _Invokable('inv', (ctx, arguments) => throw notFound),
              _Streamable('str', (ctx, arguments) => throw notFound),
              _EnhancedInvokable('einv', (ctx, arguments) => throw notFound),
              _EnhancedStreamable('estr', (ctx, arguments) => throw notFound),
              _Invokable('fine', (ctx, arguments) => 'fine'),
            ],
            toolCallMiddlewares: [ErrorRemoverMiddleware()],
          ),
        );
      });

      final message = _calls([
        ('1', 'inv', ''),
        ('2', 'str', ''),
        ('3', 'einv', ''),
        ('4', 'estr', ''),
        ('5', 'fine', ''),
      ]);

      void check(List<Message> out) {
        expect(out.map((m) => m.toolCallId), ['1', '2', '3', '4', '5']);
        expect(out[0].content, _failed('inv', 'not found web url'));
        expect(out[1].content, _failed('str', 'not found web url'));
        expect(out[2].content, isEmpty);
        expect(_firstPartText(out[2]), _failed('einv', 'not found web url'));
        expect(out[3].content, isEmpty);
        expect(_firstPartText(out[3]), _failed('estr', 'not found web url'));
        expect(out[4].content, 'fine');
      }

      test('invoked: a failing invokable, streamable, enhanced invokable and '
          'enhanced streamable tool', () async {
        check(await node.invokeTools(ctx, message));
      });

      test('streamed: the same', () async {
        final chunks = await _readAll(await node.streamTools(ctx, message));
        expect(chunks, hasLength(5));
        check(concatMessageArray(chunks));
      });

      test('in a graph the run goes on', () async {
        final graph = Graph<Message, List<Message>>()
          ..addToolsNode('tools', node)
          ..addEdge(Graph.start, 'tools')
          ..addEdge('tools', Graph.end);
        final r = await graph.compile(ctx);

        check(await r.invoke(ctx, message));
        check(concatMessageArray(await _readAll(await r.stream(ctx, message))));
      });
    });

    test('the text carries the message of a ThreepioException, and the name '
        'the model called the tool by', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Invokable(
              'search',
              (ctx, arguments) =>
                  throw const ThreepioFormatException('bad arguments'),
            ),
          ],
          toolAliases: const {
            'search': ToolAliasConfig(nameAliases: ['find']),
          },
          toolCallMiddlewares: [ErrorRemoverMiddleware()],
        ),
      );

      final out = await node.invokeTools(ctx, _calls([('1', 'find', '')]));
      expect(out.single.content, _failed('find', 'bad arguments'));
      expect(out.single.toolName, 'find');
    });

    test('a custom describe writes the text, for every part', () async {
      final described = <String>[];
      final middleware = ErrorRemoverMiddleware(
        describe: (ctx, input, error) {
          described.add('${input.name} ${input.callId} ${toolCallIdOf(ctx)}');
          return 'custom: ${input.name}(${input.arguments}) -> $error';
        },
      );
      const custom = 'custom: web_search({}) -> not found web url';
      final callCtx = ctx;

      expect(
        (await middleware.invokable!((ctx, input) async => throw notFound)(
          callCtx,
          input,
        ))
            .result,
        custom,
      );
      expect(
        await _readAll(
          (await middleware.streamable!((ctx, input) async => throw notFound)(
            callCtx,
            input,
          ))
              .result,
        ),
        [custom],
      );
      expect(
        (await middleware.enhancedInvokable!(
          (ctx, input) async => throw notFound,
        )(callCtx, input))
            .result,
        ToolResult.text(custom),
      );
      expect(
        await _readAll(
          (await middleware.enhancedStreamable!(
            (ctx, input) async => throw notFound,
          )(callCtx, input))
              .result,
        ),
        [ToolResult.text(custom)],
      );
      expect(described, List.filled(4, 'web_search 1 null'));

      // In a node, describe gets the context of the tool call.
      described.clear();
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [_Invokable('web_search', (ctx, arguments) => throw notFound)],
          toolCallMiddlewares: [middleware],
        ),
      );
      final out =
          await node.invokeTools(ctx, _calls([('call-9', 'web_search', '{}')]));
      expect(out.single.content, custom);
      expect(described, ['web_search call-9 call-9']);
    });

    group('an interrupt is thrown on', () {
      const signal = _Pause();
      const wrapped = ThreepioException('paused below', cause: signal);

      for (final (name, Object thrown) in [
        ('the signal itself', signal),
        ('the signal wrapped in an error', wrapped),
      ]) {
        test(name, () async {
          var described = 0;
          final middleware = ErrorRemoverMiddleware(
            describe: (ctx, input, error) {
              described++;
              return 'removed';
            },
          );

          await expectLater(
            middleware.invokable!((ctx, input) async => throw thrown)(ctx, input),
            throwsA(same(thrown)),
          );
          await expectLater(
            middleware.streamable!((ctx, input) async => throw thrown)(ctx, input),
            throwsA(same(thrown)),
          );
          await expectLater(
            middleware.enhancedInvokable!(
              (ctx, input) async => throw thrown,
            )(ctx, input),
            throwsA(same(thrown)),
          );
          await expectLater(
            middleware.enhancedStreamable!(
              (ctx, input) async => throw thrown,
            )(ctx, input),
            throwsA(same(thrown)),
          );
          expect(described, 0);
        });
      }

      test('through a tools node, for every kind of tool', () async {
        final node = await ToolsNode.create(
          ToolsNodeConfig(
            tools: [
              _Invokable('inv', (ctx, arguments) => throw signal),
              _Streamable('str', (ctx, arguments) => throw signal),
              _EnhancedInvokable('einv', (ctx, arguments) => throw signal),
              _EnhancedStreamable('estr', (ctx, arguments) => throw signal),
            ],
            toolCallMiddlewares: [ErrorRemoverMiddleware()],
          ),
        );

        for (final name in ['inv', 'str', 'einv', 'estr']) {
          final message = _calls([('1', name, '')]);
          await expectLater(
            node.invokeTools(ctx, message),
            throwsA(same(signal)),
            reason: '$name, invoked',
          );
          await expectLater(
            node.streamTools(ctx, message),
            throwsA(same(signal)),
            reason: '$name, streamed',
          );
        }
      });
    });

    group('once the run was cancelled, what is thrown is thrown on', () {
      test('by every part', () async {
        final token = CancelToken();
        final cancelled = RunContext.background(cancelToken: token);
        const error = CancelledException('stop');
        const other = _GoError('whatever came of the cancellation');
        var described = 0;
        final middleware = ErrorRemoverMiddleware(
          describe: (ctx, input, error) {
            described++;
            return 'removed';
          },
        );

        // Not cancelled yet: an error like any other.
        expect(
          (await middleware.invokable!((ctx, input) async => throw other)(
            cancelled,
            input,
          ))
              .result,
          'removed',
        );
        expect(described, 1);

        token.cancel('stop');

        await expectLater(
          middleware.invokable!((ctx, input) async => throw error)(
            cancelled,
            input,
          ),
          throwsA(same(error)),
        );
        await expectLater(
          middleware.streamable!((ctx, input) async => throw error)(
            cancelled,
            input,
          ),
          throwsA(same(error)),
        );
        await expectLater(
          middleware.enhancedInvokable!((ctx, input) async => throw error)(
            cancelled,
            input,
          ),
          throwsA(same(error)),
        );
        await expectLater(
          middleware.enhancedStreamable!((ctx, input) async => throw other)(
            cancelled,
            input,
          ),
          throwsA(same(other)),
        );
        expect(described, 1);
      });

      test('a tool that fails because the run is cancelled while it runs '
          'fails the node', () async {
        final token = CancelToken();
        final cancellable = RunContext.background(cancelToken: token);
        final started = Completer<void>();
        final node = await ToolsNode.create(
          ToolsNodeConfig(
            tools: [
              _Invokable('wait', (ctx, arguments) async {
                started.complete();
                await ctx.cancelToken.whenCancelled;
                throw CancelledException(ctx.cancelToken.reason);
              }),
            ],
            toolCallMiddlewares: [ErrorRemoverMiddleware()],
          ),
        );

        final run = node.invokeTools(cancellable, _calls([('1', 'wait', '')]));
        final expectation = expectLater(
          run,
          throwsA(
            isA<ToolsNodeException>().having(
              (e) => e.cause,
              'cause',
              isA<CancelledException>(),
            ),
          ),
        );
        await started.future;
        token.cancel('user pressed stop');
        await expectation;
      });
    });

    test('a successful call passes untouched', () async {
      var described = 0;
      final middleware = ErrorRemoverMiddleware(
        describe: (ctx, input, error) {
          described++;
          return 'removed';
        },
      );
      final passed = <ToolCallInput>[];

      const output = ToolCallOutput('fine');
      expect(
        await middleware.invokable!((ctx, input) async {
          passed.add(input);
          return output;
        })(ctx, input),
        same(output),
      );

      final streamOutput = StreamToolCallOutput(StreamReader.fromIterable(['a']));
      expect(
        await middleware.streamable!((ctx, input) async {
          passed.add(input);
          return streamOutput;
        })(ctx, input),
        same(streamOutput),
      );

      const enhancedOutput = EnhancedToolCallOutput(ToolResult());
      expect(
        await middleware.enhancedInvokable!((ctx, input) async {
          passed.add(input);
          return enhancedOutput;
        })(ctx, input),
        same(enhancedOutput),
      );

      final enhancedStreamOutput = EnhancedStreamToolCallOutput(
        StreamReader.fromIterable([ToolResult.text('a')]),
      );
      expect(
        await middleware.enhancedStreamable!((ctx, input) async {
          passed.add(input);
          return enhancedStreamOutput;
        })(ctx, input),
        same(enhancedStreamOutput),
      );

      expect(passed, everyElement(same(input)));
      expect(passed, hasLength(4));
      expect(described, 0);
    });

    test('an error inside the stream of a tool is not removed', () async {
      const broken = _GoError('broken pipe');
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            _Streamable('str', (ctx, arguments) async {
              final (reader, writer) = pipe<String>(capacity: 2);
              writer
                ..send('a')
                ..sendError(broken);
              await writer.close();
              return reader;
            }),
          ],
          toolCallMiddlewares: [ErrorRemoverMiddleware()],
        ),
      );

      final reader = await node.streamTools(ctx, _calls([('1', 'str', '')]));
      addTearDown(reader.close);
      expect((await reader.recv()).single.content, 'a');
      await expectLater(reader.recv(), throwsA(same(broken)));
    });

    test('it removes the failures of what is behind it, not of what is in '
        'front of it', () async {
      ToolMiddleware failing() => ToolMiddleware(
            invokable: (next) => (ctx, input) async {
              await next(ctx, input);
              throw const _GoError('middleware failed');
            },
          );
      Future<ToolsNode> nodeWith(List<ToolMiddleware> middlewares) =>
          ToolsNode.create(
            ToolsNodeConfig(
              tools: [_Invokable('tool', (ctx, arguments) => 'fine')],
              toolCallMiddlewares: middlewares,
            ),
          );
      final message = _calls([('1', 'tool', '')]);

      // First in the list is outermost: it sees the failure of the second.
      final first = await nodeWith([ErrorRemoverMiddleware(), failing()]);
      expect(
        (await first.invokeTools(ctx, message)).single.content,
        _failed('tool', 'middleware failed'),
      );

      final last = await nodeWith([failing(), ErrorRemoverMiddleware()]);
      await expectLater(
        last.invokeTools(ctx, message),
        throwsA(
          isA<ToolsNodeException>().having(
            (e) => e.message,
            'message',
            contains('middleware failed'),
          ),
        ),
      );
    });

    test('with JsonFixMiddleware behind it, arguments no repair can save '
        'become a failure the model can read', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: [
            FunctionTool<String, String>(
              name: 'web_search',
              description: 'search content for web url',
              params: const ParamsOneOf.params({
                'url': ParameterInfo(type: DataType.string),
              }),
              fromJson: (json) => json['url']! as String,
              invoke: (ctx, url, options) => 'searched $url',
            ),
          ],
          toolCallMiddlewares: [ErrorRemoverMiddleware(), JsonFixMiddleware()],
        ),
      );

      final out = await node.invokeTools(
        ctx,
        _calls([
          ('1', 'web_search', "Here: {'url': 'web_url',}"),
          ('2', 'web_search', '[1, 2]'),
        ]),
      );
      expect(out[0].content, 'searched web_url');
      expect(
        out[1].content,
        startsWith("Failed to call tool 'web_search', error message: '"),
      );
    });

    test('a failure of the unknown tools handler is not behind the '
        'middleware', () async {
      final node = await ToolsNode.create(
        ToolsNodeConfig(
          tools: const [],
          unknownToolsHandler: (ctx, name, input) => throw notFound,
          toolCallMiddlewares: [ErrorRemoverMiddleware()],
        ),
      );

      await expectLater(
        node.invokeTools(ctx, _calls([('1', 'nope', '')])),
        throwsA(
          isA<ToolsNodeException>().having((e) => e.cause, 'cause', same(notFound)),
        ),
      );
    });
  });
}
