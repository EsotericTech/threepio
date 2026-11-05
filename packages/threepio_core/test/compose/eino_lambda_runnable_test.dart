// Port of eino `compose/types_lambda_test.go`, `compose/runnable_test.go`,
// `compose/stream_reader_test.go` and, from `compose/checkpoint_test.go`, of
// TestRunnableInvokeAcceptsNilForPointerInput only (v0.9.22).
//
// Go's `runnableLambda` / `newRunnablePacker` is the internal
// `RunnablePacker`; `toGenericRunnable` has no function of its own in Dart
// (`compileAnyGraph` does the same for a compiled graph), so the helper
// `_toGenericRunnable` below repeats its three lines. Go's
// `streamReaderPacker` has no counterpart: a Dart `StreamReader<T>` is a
// `StreamReader<Object?>`, and `TypeRef<T>().stream` is `unpackStreamReader`.
//
// Lines marked "Dart extra" assert more than the Go test does.

import 'package:test/test.dart';
import 'package:threepio_core/src/compose/composable_runnable.dart';
import 'package:threepio_core/src/compose/stream_conversion.dart';
import 'package:threepio_core/src/compose/type_ref.dart';
import 'package:threepio_core/threepio_core.dart';

/// Go: `TestStructForParse`.
final class _TestStructForParse {
  const _TestStructForParse(this.id);

  factory _TestStructForParse.fromJson(Map<String, dynamic> json) =>
      _TestStructForParse(json['id'] as int);

  final int id;
}

/// Go: `checkpointTypedNilInput`.
final class _TypedNilInput {}

/// Go: `person` and `doctor` (graph_test.go).
abstract interface class _Person {
  String say();
}

final class _Doctor implements _Person {
  const _Doctor(this._say);

  final String _say;

  @override
  String say() => _say;
}

/// Go: `toGenericRunnable`. The typed runnable over the type-erased form of
/// [packer], with the other two ways to run derived from `invoke` and
/// `transform`, and a context wrapper that changes nothing.
RunnablePacker<I, O, CallOption> _toGenericRunnable<I, O>(
  RunnablePacker<I, O, CallOption> packer,
) {
  final erased = packer.toComposableRunnable();
  final outputType = TypeRef<O>();
  return RunnablePacker<I, O, CallOption>(
    invoke: (ctx, input, options) async =>
        (await erased.invoke(ctx, input, options)) as O,
    transform: (ctx, input, options) async =>
        outputType.stream(await erased.transform(ctx, input, options)),
  ).withContext((ctx, options) => ctx);
}

/// Go: `opts[0].options[0].(string)`.
String _optionText(List<CallOption> options) =>
    options[0].componentOptions[0]! as String;

StreamReader<String> _threeChunks(int input, String option) {
  final (reader, writer) = pipe<String>(capacity: 3);
  writer
    ..send('$input')
    ..send('+')
    ..send(option)
    ..close();
  return reader;
}

void main() {
  final ctx = RunContext.background();

  // ------------------------------------------------------- types_lambda_test.go

  group('TestLambda', () {
    void expectMeta(
      Lambda<Object?, Object?> lambda, {
      required bool callbacksEnabled,
      required String type,
    }) {
      final meta = lambda.executor.meta!;
      expect(meta.isComponentCallbackEnabled, callbacksEnabled);
      expect(meta.component, ComponentType.lambda);
      expect(meta.componentImplType, type);
    }

    StreamReader<String> closedPipe() {
      final (reader, writer) = pipe<String>(capacity: 1);
      writer.close();
      return reader;
    }

    const forTest = LambdaOptions(type: 'ForTest');
    const withCallbacks = LambdaOptions(callbacksEnabled: true);

    test('InvokableLambda', () {
      expectMeta(
        Lambda.invokableWithOption<String, String, Object?>(
          (ctx, input, options) => 'good',
          options: forTest,
        ),
        callbacksEnabled: false,
        type: 'ForTest',
      );
      expectMeta(
        Lambda<String, String>.invokable(
          (ctx, input) => 'good',
          options: forTest,
        ),
        callbacksEnabled: false,
        type: 'ForTest',
      );
    });

    test('StreamableLambda', () {
      expectMeta(
        Lambda.streamableWithOption<String, String, Object?>(
          (ctx, input, options) => closedPipe(),
          options: forTest,
        ),
        callbacksEnabled: false,
        type: 'ForTest',
      );
      expectMeta(
        Lambda<String, String>.streamable(
          (ctx, input) => closedPipe(),
          options: forTest,
        ),
        callbacksEnabled: false,
        type: 'ForTest',
      );
    });

    test('CollectableLambda', () {
      expectMeta(
        Lambda.collectableWithOption<String, String, Object?>(
          (ctx, input, options) => 'good',
          options: withCallbacks,
        ),
        callbacksEnabled: true,
        type: '',
      );
      expectMeta(
        Lambda<String, String>.collectable(
          (ctx, input) => 'good',
          options: withCallbacks,
        ),
        callbacksEnabled: true,
        type: '',
      );
    });

    test('TransformableLambda', () {
      expectMeta(
        Lambda.transformableWithOption<String, String, Object?>(
          (ctx, input, options) => closedPipe(),
          options: withCallbacks,
        ),
        callbacksEnabled: true,
        type: '',
      );
      expectMeta(
        Lambda<String, String>.transformable(
          (ctx, input) => closedPipe(),
          options: withCallbacks,
        ),
        callbacksEnabled: true,
        type: '',
      );
    });

    test('AnyLambda', () {
      const options = LambdaOptions(callbacksEnabled: true, type: 'ForTest');
      expectMeta(
        Lambda.anyWithOption<String, String, Object?>(
          invoke: (ctx, input, options) => 'good',
          stream: (ctx, input, options) => closedPipe(),
          collect: (ctx, input, options) => 'good',
          transform: (ctx, input, options) => closedPipe(),
          options: options,
        ),
        callbacksEnabled: true,
        type: 'ForTest',
      );
      // Dart extra: the variant without call options.
      expectMeta(
        Lambda<String, String>.any(
          invoke: (ctx, input) => 'good',
          stream: (ctx, input) => closedPipe(),
          collect: (ctx, input) => 'good',
          transform: (ctx, input) => closedPipe(),
          options: options,
        ),
        callbacksEnabled: true,
        type: 'ForTest',
      );
    });

    // Dart extra. In Go a lambda made of four nil functions is built and
    // fails when it runs; here it cannot be built.
    test('AnyLambda without a function', () {
      expect(Lambda<String, String>.any, throwsArgumentError);
      expect(
        () => Lambda.anyWithOption<String, String, Object?>(),
        throwsArgumentError,
      );
    });
  });

  group('TestMessageParser', () {
    test('parse from content', () async {
      final parser = MessageJsonParser<_TestStructForParse>.object(
        fromJson: _TestStructForParse.fromJson,
      );

      final parserLambda = Lambda.messageParser<_TestStructForParse>(parser);
      // Dart extra: Go names the lambda `MessageParse` as well.
      expect(parserLambda.executor.meta!.componentImplType, 'MessageParse');

      final chain = Chain<Message, _TestStructForParse>()
        ..appendLambda(parserLambda);
      final r = await chain.compile(ctx);

      final parsed = await r.invoke(ctx, Message.assistant('{"id": 1}'));
      expect(parsed.id, 1);
    });

    test('parse from tool call', () async {
      // Go parses into a pointer; here the result type is nullable.
      final parser = MessageJsonParser<_TestStructForParse?>.object(
        fromJson: _TestStructForParse.fromJson,
        parseFrom: MessageParseFrom.toolCall,
      );

      final parserLambda = Lambda.messageParser<_TestStructForParse?>(parser);

      final chain = Chain<Message, _TestStructForParse?>()
        ..appendLambda(parserLambda);
      final r = await chain.compile(ctx);

      final parsed = await r.invoke(
        ctx,
        Message.assistant(
          '',
          toolCalls: const [
            ToolCall(
              id: '',
              function: FunctionCall(name: '', arguments: '{"id": 1}'),
            ),
          ],
        ),
      );
      expect(parsed!.id, 1);
    });
  });

  // ----------------------------------------------------------- runnable_test.go

  group('TestRunnableLambda', () {
    final option = [CallOption.lambda<String>(['100'])];

    /// The four calls every Go sub-test makes, on a stream of one int for the
    /// two that take a stream.
    Future<void> expectFourModes(RunnablePacker<int, String, CallOption> gr) async {
      expect(await gr.invoke(ctx, 10, option), '10+100');

      expect(
        await concatStreamReader(await gr.stream(ctx, 10, option)),
        '10+100',
      );

      final (sri, swi) = pipe<int>(capacity: 1);
      swi.send(10);
      await swi.close();
      final sriArr = sri.copy(2);

      expect(await gr.collect(ctx, sriArr[0], option), '10+100');

      expect(
        await concatStreamReader(await gr.transform(ctx, sriArr[1], option)),
        '10+100',
      );
    }

    test('invoke_to_runnable', () async {
      var calls = 0;
      final rl = RunnablePacker<int, String, CallOption>(
        invoke: (ctx, input, options) async {
          calls++;
          return '$input+${_optionText(options)}';
        },
      );

      await expectFourModes(_toGenericRunnable<int, String>(rl));
      expect(calls, 4);

      // Dart extra: the packer itself, without the type-erased round trip:
      // stream by invoke, collect by invoke, transform by invoke.
      await expectFourModes(rl);
      expect(calls, 8);
    });

    test('stream_to_runnable', () async {
      var calls = 0;
      final rl = RunnablePacker<int, String, CallOption>(
        stream: (ctx, input, options) async {
          calls++;
          return _threeChunks(input, _optionText(options));
        },
      );

      await expectFourModes(_toGenericRunnable<int, String>(rl));
      expect(calls, 4);

      // Dart extra: invoke by stream, collect by stream, transform by stream.
      await expectFourModes(rl);
      expect(calls, 8);
    });

    test('transform_to_runnable', () async {
      var calls = 0;
      final rl = RunnablePacker<int, String, CallOption>(
        transform: (ctx, input, options) async {
          calls++;
          final int value;
          try {
            value = await input.recv();
          } on StreamEOFException {
            throw StateError('unpected EOF');
          }
          await input.close();
          return _threeChunks(value, _optionText(options));
        },
      );

      await expectFourModes(_toGenericRunnable<int, String>(rl));
      expect(calls, 4);

      // Dart extra: invoke by transform, stream by transform, collect by
      // transform.
      await expectFourModes(rl);
      expect(calls, 8);
    });

    test('collect_to_runnable', () async {
      var calls = 0;
      final rl = RunnablePacker<int, String, CallOption>(
        collect: (ctx, input, options) async {
          calls++;
          final int value;
          try {
            value = await input.recv();
          } on StreamEOFException {
            throw StateError('unpected EOF');
          }
          await input.close();
          return '$value+${_optionText(options)}';
        },
      );

      await expectFourModes(_toGenericRunnable<int, String>(rl));
      expect(calls, 4);

      // Dart extra: invoke by collect, stream by collect, transform by
      // collect.
      await expectFourModes(rl);
      expect(calls, 8);
    });
  });

  // Not in Go's test file. The twelve conversions of `newRunnablePacker`, each
  // named by what it derives from what, on inputs and outputs of several
  // chunks, so that joining the chunks shows.
  group('TestRunnableLambda: derived conversions', () {
    Future<String> i(RunContext ctx, String input, List<Object?> _) async =>
        'i($input)';
    Future<StreamReader<String>> s(
      RunContext ctx,
      String input,
      List<Object?> _,
    ) async =>
        StreamReader.fromIterable(['s(', input, ')']);
    Future<String> c(
      RunContext ctx,
      StreamReader<String> input,
      List<Object?> _,
    ) async =>
        'c(${(await input.collectAll()).join('|')})';
    Future<StreamReader<String>> t(
      RunContext ctx,
      StreamReader<String> input,
      List<Object?> _,
    ) async =>
        input.convert((chunk) => 't($chunk)');

    StreamReader<String> ab() => StreamReader.fromIterable(['a', 'b']);

    test('invoke by stream: the chunks are joined', () async {
      final packer = RunnablePacker<String, String, Object?>(stream: s);
      expect(await packer.invoke(ctx, 'ab', const []), 's(ab)');
    });

    test('invoke by collect: the input is a stream of one', () async {
      final packer = RunnablePacker<String, String, Object?>(collect: c);
      expect(await packer.invoke(ctx, 'ab', const []), 'c(ab)');
    });

    test('invoke by transform', () async {
      final packer = RunnablePacker<String, String, Object?>(transform: t);
      expect(await packer.invoke(ctx, 'ab', const []), 't(ab)');
    });

    test('stream by invoke: the output is a stream of one', () async {
      final packer = RunnablePacker<String, String, Object?>(invoke: i);
      final out = await packer.stream(ctx, 'ab', const []);
      expect(await out.collectAll(), ['i(ab)']);
    });

    test('stream by transform', () async {
      final packer = RunnablePacker<String, String, Object?>(transform: t);
      final out = await packer.stream(ctx, 'ab', const []);
      expect(await out.collectAll(), ['t(ab)']);
    });

    test('stream by collect', () async {
      final packer = RunnablePacker<String, String, Object?>(collect: c);
      final out = await packer.stream(ctx, 'ab', const []);
      expect(await out.collectAll(), ['c(ab)']);
    });

    test('collect by invoke: the input chunks are joined', () async {
      final packer = RunnablePacker<String, String, Object?>(invoke: i);
      expect(await packer.collect(ctx, ab(), const []), 'i(ab)');
    });

    test('collect by stream: input and output chunks are joined', () async {
      final packer = RunnablePacker<String, String, Object?>(stream: s);
      expect(await packer.collect(ctx, ab(), const []), 's(ab)');
    });

    test('collect by transform: the output chunks are joined', () async {
      final packer = RunnablePacker<String, String, Object?>(transform: t);
      expect(await packer.collect(ctx, ab(), const []), 't(a)t(b)');
    });

    test('transform by invoke', () async {
      final packer = RunnablePacker<String, String, Object?>(invoke: i);
      final out = await packer.transform(ctx, ab(), const []);
      expect(await out.collectAll(), ['i(ab)']);
    });

    test('transform by stream: the input chunks are joined', () async {
      final packer = RunnablePacker<String, String, Object?>(stream: s);
      final out = await packer.transform(ctx, ab(), const []);
      expect(await out.collectAll(), ['s(', 'ab', ')']);
    });

    test('transform by collect', () async {
      final packer = RunnablePacker<String, String, Object?>(collect: c);
      final out = await packer.transform(ctx, ab(), const []);
      expect(await out.collectAll(), ['c(a|b)']);
    });

    test('a function that is given is used as it is', () async {
      final packer = RunnablePacker<String, String, Object?>(
        invoke: i,
        stream: s,
        collect: c,
        transform: t,
      );
      expect(await packer.invoke(ctx, 'ab', const []), 'i(ab)');
      expect(
        await (await packer.stream(ctx, 'ab', const [])).collectAll(),
        ['s(', 'ab', ')'],
      );
      expect(await packer.collect(ctx, ab(), const []), 'c(a|b)');
      expect(
        await (await packer.transform(ctx, ab(), const [])).collectAll(),
        ['t(a)', 't(b)'],
      );
    });

    test('which function a missing one is derived from', () async {
      // invoke: stream, then collect, then transform
      expect(
        await RunnablePacker<String, String, Object?>(
          stream: s,
          collect: c,
          transform: t,
        ).invoke(ctx, 'ab', const []),
        's(ab)',
      );
      expect(
        await RunnablePacker<String, String, Object?>(collect: c, transform: t)
            .invoke(ctx, 'ab', const []),
        'c(ab)',
      );

      // stream: transform, then invoke, then collect
      expect(
        await (await RunnablePacker<String, String, Object?>(
          invoke: i,
          collect: c,
          transform: t,
        ).stream(ctx, 'ab', const []))
            .collectAll(),
        ['t(ab)'],
      );
      expect(
        await (await RunnablePacker<String, String, Object?>(
          invoke: i,
          collect: c,
        ).stream(ctx, 'ab', const []))
            .collectAll(),
        ['i(ab)'],
      );

      // collect: transform, then invoke, then stream
      expect(
        await RunnablePacker<String, String, Object?>(
          invoke: i,
          stream: s,
          transform: t,
        ).collect(ctx, ab(), const []),
        't(a)t(b)',
      );
      expect(
        await RunnablePacker<String, String, Object?>(invoke: i, stream: s)
            .collect(ctx, ab(), const []),
        'i(ab)',
      );

      // transform: stream, then collect, then invoke
      expect(
        await (await RunnablePacker<String, String, Object?>(
          invoke: i,
          stream: s,
          collect: c,
        ).transform(ctx, ab(), const []))
            .collectAll(),
        ['s(', 'ab', ')'],
      );
      expect(
        await (await RunnablePacker<String, String, Object?>(
          invoke: i,
          collect: c,
        ).transform(ctx, ab(), const []))
            .collectAll(),
        ['c(a|b)'],
      );
    });

    test('none of the four is an error', () {
      expect(RunnablePacker<String, String, Object?>.new, throwsArgumentError);
    });
  });

  // Not in Go's test file. The same four kinds through the public API: a
  // lambda that takes call options as the one node of a chain and of a graph.
  group('TestRunnableLambda: a lambda as the one node of a chain or graph',
      () {
    final option = [CallOption.lambda<String>(['100'])];

    final lambdas = <String, Lambda<int, String>>{
      'invokable': Lambda.invokableWithOption<int, String, String>(
        (ctx, input, options) => '$input+${options.single}',
      ),
      'streamable': Lambda.streamableWithOption<int, String, String>(
        (ctx, input, options) => _threeChunks(input, options.single),
      ),
      'collectable': Lambda.collectableWithOption<int, String, String>(
        (ctx, input, options) async {
          final value = await concatStreamReader(input);
          return '$value+${options.single}';
        },
      ),
      'transformable': Lambda.transformableWithOption<int, String, String>(
        (ctx, input, options) async {
          final value = await concatStreamReader(input);
          return _threeChunks(value, options.single);
        },
      ),
    };

    Future<void> expectFourModes(Runnable<int, String> r) async {
      expect(await r.invoke(ctx, 10, options: option), '10+100');
      expect(
        await concatStreamReader(await r.stream(ctx, 10, options: option)),
        '10+100',
      );
      expect(
        await r.collect(ctx, StreamReader.fromIterable([10]), options: option),
        '10+100',
      );
      expect(
        await concatStreamReader(
          await r.transform(
            ctx,
            StreamReader.fromIterable([10]),
            options: option,
          ),
        ),
        '10+100',
      );
    }

    for (final MapEntry(key: kind, value: lambda) in lambdas.entries) {
      test('$kind lambda in a chain', () async {
        final chain = Chain<int, String>()..appendLambda(lambda);
        await expectFourModes(await chain.compile(ctx));
      });

      test('$kind lambda in a graph', () async {
        final graph = Graph<int, String>()
          ..addLambdaNode('node', lambda)
          ..addEdge(Graph.start, 'node')
          ..addEdge('node', Graph.end);
        await expectFourModes(await graph.compile(ctx));
      });
    }
  });

  // --------------------------------------------------------- checkpoint_test.go

  group('TestRunnableInvokeAcceptsNilForPointerInput', () {
    test('a nullable input type accepts null', () async {
      Object? seen = 'not called';
      final lambda = Lambda<_TypedNilInput?, String>.invokable((ctx, input) {
        seen = input;
        return 'ok';
      });

      expect(await lambda.executor.invoke(ctx, null, const []), 'ok');
      expect(seen, isNull);
    });

    // Dart extra: the same through a compiled graph, in all four modes.
    test('a nullable input type accepts null in a compiled graph', () async {
      final seen = <_TypedNilInput?>[];
      final graph = Graph<_TypedNilInput?, String>()
        ..addLambdaNode(
          'node',
          Lambda<_TypedNilInput?, String>.invokable((ctx, input) {
            seen.add(input);
            return 'ok';
          }),
        )
        ..addEdge(Graph.start, 'node')
        ..addEdge('node', Graph.end);
      final r = await graph.compile(ctx);

      expect(await r.invoke(ctx, null), 'ok');
      expect(await (await r.stream(ctx, null)).collectAll(), ['ok']);
      expect(await r.collect(ctx, StreamReader.fromIterable([null])), 'ok');
      expect(
        await (await r.transform(ctx, StreamReader.fromIterable([null])))
            .collectAll(),
        ['ok'],
      );
      expect(seen, [null, null, null, null]);
    });

    // The Dart counterpart of the Go case: a type that is not nullable does
    // not accept null.
    test('a non-nullable input type does not accept null', () async {
      final lambda = Lambda<_TypedNilInput, String>.invokable(
        (ctx, input) => 'ok',
      );

      await expectLater(
        lambda.executor.invoke(ctx, null, const []),
        throwsA(
          isA<ComposeTypeException>().having(
            (e) => e.message,
            'message',
            allOf(contains('unexpected input type'), contains('Null')),
          ),
        ),
      );
    });

    test(
        'a non-nullable input type given null through an Object? edge fails '
        'with a type error', () async {
      var calls = 0;
      final graph = Graph<Object?, String>()
        ..addLambdaNode(
          'node',
          Lambda<_TypedNilInput, String>.invokable((ctx, input) {
            calls++;
            return 'ok';
          }),
        )
        ..addEdge(Graph.start, 'node')
        ..addEdge('node', Graph.end);
      final r = await graph.compile(ctx);

      expect(await r.invoke(ctx, _TypedNilInput()), 'ok');
      expect(calls, 1);

      await expectLater(
        r.invoke(ctx, null),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'toString()',
            allOf(contains('runtime type check'), contains('Null')),
          ),
        ),
      );
      await expectLater(
        () async => (await r.stream(ctx, null)).collectAll(),
        throwsA(
          isA<Object>().having(
            (e) => e.toString(),
            'toString()',
            allOf(contains('runtime type check'), contains('Null')),
          ),
        ),
      );
      expect(calls, 1);
    });
  });

  // ------------------------------------------------------ stream_reader_test.go

  group('TestArrayStreamMerge', () {
    test('unpack_to_equal_type', () async {
      final a1 = [1, 2, 3];
      final a2 = [4, 5, 6];
      final a3 = [7, 8, 9];

      // Go: sp1.merge([sp2, sp3]), which is schema.MergeStreamReaders.
      final merged = mergeStreamReaders<int>([
        StreamReader.fromIterable(a1),
        StreamReader.fromIterable(a2),
        StreamReader.fromIterable(a3),
      ]);
      // The form the engine passes streams around in.
      final StreamReader<Object?> packed = merged;

      final sr = const TypeRef<int>().stream(packed);
      // Dart extra: unpacking to the type the stream has is free.
      expect(sr, same(merged));

      expect(await sr.collectAll(), [...a1, ...a2, ...a3]);
      await sr.close();
    });

    test('unpack_to_father_type', () async {
      const a1 = [_Doctor('a'), _Doctor('b'), _Doctor('c')];
      const a2 = [_Doctor('d'), _Doctor('e'), _Doctor('f')];
      const a3 = [_Doctor('g'), _Doctor('h'), _Doctor('i')];

      final merged = mergeStreamReaders<_Doctor>([
        StreamReader.fromIterable(a1),
        StreamReader.fromIterable(a2),
        StreamReader.fromIterable(a3),
      ]);
      final StreamReader<Object?> packed = merged;

      final sr = const TypeRef<_Person>().stream(packed);

      final result = await sr.collectAll();
      await sr.close();

      final baseline = [...a1, ...a2, ...a3];
      expect(result, hasLength(baseline.length));
      for (var idx = 0; idx < result.length; idx++) {
        expect(result[idx].say(), baseline[idx].say());
      }
    });

    // Dart extra: a stream declared with a wider chunk type than the one it
    // is unpacked to is checked chunk by chunk.
    test('unpack a stream of Object? to the type of its chunks', () async {
      final packed = StreamReader<Object?>.fromIterable(
        const [_Doctor('a'), _Doctor('b')],
      );
      final sr = const TypeRef<_Person>().stream(packed);
      expect(sr, isA<StreamReader<_Person>>());
      expect((await sr.collectAll()).map((p) => p.say()), ['a', 'b']);

      final wrong = const TypeRef<_Person>().stream(
        StreamReader<Object?>.fromIterable(const [_Doctor('a'), 'not a person']),
      );
      expect((await wrong.recv()).say(), 'a');
      await expectLater(
        wrong.recv(),
        throwsA(
          isA<ComposeTypeException>().having(
            (e) => e.message,
            'message',
            contains('runtime type check'),
          ),
        ),
      );
      await wrong.close();
    });

    // Dart extra: Go's streamReaderPacker.withKey and the map filter in front
    // of a node with an input key.
    test('an output key packs the chunks, an input key unpacks them', () async {
      final upper = RunnablePacker<String, String, Object?>(
        transform: (ctx, input, _) async =>
            input.convert((chunk) => chunk.toUpperCase()),
      ).toComposableRunnable();

      final outputKeyed = outputKeyedComposableRunnable('k', upper);
      expect(outputKeyed.outputType!.isSameAs(mapType), isTrue);
      final packed = await outputKeyed.transform(
        ctx,
        StreamReader<String>.fromIterable(['a', 'b']),
        const [],
      );
      expect(packed, isA<StreamReader<Map<String, Object?>>>());
      expect(await packed.collectAll(), [
        {'k': 'A'},
        {'k': 'B'},
      ]);
      expect(await outputKeyed.invoke(ctx, 'ab', const []), {'k': 'AB'});

      final inputKeyed = inputKeyedComposableRunnable('k', upper);
      expect(inputKeyed.inputType!.isSameAs(mapType), isTrue);
      final unpacked = await inputKeyed.transform(
        ctx,
        StreamReader<Map<String, Object?>>.fromIterable([
          {'k': 'a'},
          {'other': 'x'},
          {'k': 'b'},
        ]),
        const [],
      );
      // A chunk without the key is left out.
      expect(await unpacked.collectAll(), ['A', 'B']);
      expect(
        await inputKeyed.invoke(ctx, <String, Object?>{'k': 'ab'}, const []),
        'AB',
      );
      await expectLater(
        inputKeyed.invoke(ctx, <String, Object?>{'other': 'x'}, const []),
        throwsA(
          isA<ComposeTypeException>().having(
            (e) => e.message,
            'message',
            contains('cannot find input key: k'),
          ),
        ),
      );
    });
  });
}
