// Checkpoints as bytes: the JSON serializer, every type the engine and the
// schema register, and how values get their types back.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/src/compose/address.dart';
import 'package:threepio_core/src/compose/checkpoint.dart';
import 'package:threepio_core/src/compose/checkpoint_serializer.dart';
import 'package:threepio_core/src/compose/dag.dart';
import 'package:threepio_core/src/compose/interrupt.dart';
import 'package:threepio_core/src/compose/pregel.dart';
import 'package:threepio_core/src/compose/type_ref.dart';

final class _Point {
  const _Point(this.x, this.y);
  factory _Point.fromJson(Map<String, Object?> json) =>
      _Point(json['x']! as int, json['y']! as int);
  final int x;
  final int y;
  Map<String, Object?> toJson() => {'x': x, 'y': y};

  @override
  bool operator ==(Object other) => other is _Point && other.x == x && other.y == y;

  @override
  int get hashCode => Object.hash(x, y);

  @override
  String toString() => '_Point($x, $y)';
}

final class _Unregistered {
  const _Unregistered();
}

abstract class _Shape {}

final class _Circle implements _Shape {
  const _Circle(this.radius);
  final int radius;
}

Object? _roundTrip(Object? value) {
  const serializer = JsonCheckpointSerializer();
  return serializer.deserialize(serializer.serialize(value));
}

void main() {
  setUpAll(() {
    TypeRegistry.registerName<_Point>(
      'checkpoint_serializer_test.point',
      fromJson: _Point.fromJson,
      toJson: (point) => point.toJson(),
    );
    TypeRegistry.registerName<_Circle>(
      'checkpoint_serializer_test.circle',
      fromJson: (json) => _Circle(json['radius']! as int),
      toJson: (circle) => {'radius': circle.radius},
    );
  });

  group('JsonCheckpointSerializer', () {
    test('writes UTF-8 JSON', () {
      final bytes = const JsonCheckpointSerializer()
          .serialize({'text': 'grüße', 'n': 1, 'list': [true, null]});
      expect(jsonDecode(utf8.decode(bytes)), {
        'text': 'grüße',
        'n': 1,
        'list': [true, null],
      });
    });

    test('plain JSON values survive', () {
      for (final value in <Object?>[
        null,
        true,
        1,
        1.5,
        'text',
        <Object?>[1, 'a', null],
        <String, Object?>{'a': 1, 'b': <String, Object?>{'c': <Object?>[]}},
      ]) {
        expect(_roundTrip(value), value);
      }
    });

    test('a registered class survives, also inside lists and maps', () {
      expect(_roundTrip(const _Point(1, 2)), const _Point(1, 2));
      expect(
        _roundTrip({
          'points': [const _Point(1, 2), const _Point(3, 4)],
          'origin': const _Point(0, 0),
        }),
        {
          'points': [const _Point(1, 2), const _Point(3, 4)],
          'origin': const _Point(0, 0),
        },
      );
    });

    test('a map that has a key called \$type survives', () {
      final value = {r'$type': 'not a type', 'x': 1};
      expect(_roundTrip(value), value);
    });

    test('a value of an unregistered class is refused', () {
      expect(
        () => const JsonCheckpointSerializer().serialize(const _Unregistered()),
        throwsArgumentError,
      );
    });

    test('a type name that is not registered is refused when read', () {
      final bytes = Uint8List.fromList(
        utf8.encode(jsonEncode({r'$type': 'nobody', r'$value': <String, Object?>{}})),
      );
      expect(
        () => const JsonCheckpointSerializer().deserialize(bytes),
        throwsStateError,
      );
    });

    test('toJson and fromJson are the two halves of it', () {
      final json = JsonCheckpointSerializer.toJson(const _Point(5, 6));
      expect(json, {
        r'$type': 'checkpoint_serializer_test.point',
        r'$value': {'x': 5, 'y': 6},
      });
      expect(JsonCheckpointSerializer.fromJson(json), const _Point(5, 6));
    });
  });

  group('every registered schema type makes the round trip', () {
    final cases = <String, Object>{
      '_eino_message': Message.assistant(
        'hello',
        toolCalls: const [
          ToolCall(id: 'c', function: FunctionCall(name: 'f', arguments: '{}')),
        ],
      ),
      '_eino_message_slice': [Message.user('a'), Message.system('b')],
      '_eino_document': const Document(id: 'd', content: 'text', metadata: {'k': 1}),
      '_eino_role_type': RoleType.tool,
      '_eino_tool_call':
          const ToolCall(id: 'c', function: FunctionCall(name: 'f', arguments: '{}')),
      '_eino_function_call': const FunctionCall(name: 'f', arguments: '{"a":1}'),
      '_eino_response_meta': const ResponseMeta(finishReason: 'stop'),
      '_eino_token_usage':
          const TokenUsage(promptTokens: 1, completionTokens: 2, totalTokens: 3),
      '_eino_chat_message_type': ChatMessagePartType.text,
      '_eino_message_input_part': const MessageInputPart(
        type: ChatMessagePartType.text,
        text: 'part',
      ),
      '_eino_message_output_part': const MessageOutputPart(
        type: ChatMessagePartType.text,
        text: 'out',
      ),
      '_eino_image_url_detail': ImageURLDetail.high,
    };

    for (final MapEntry(key: name, :value) in cases.entries) {
      test(name, () {
        expect(TypeRegistry.nameOf(value), name);
        expect(_roundTrip(value), value);
      });
    }
  });

  group('the types the engine registers', () {
    test('are there after a checkpoint was encoded once', () {
      _roundTrip(GraphCheckpoint());
      expect(TypeRegistry.nameOf(GraphCheckpoint()), '_eino_checkpoint');
      expect(
        TypeRegistry.nameOf(
          DagChannel(
            controlPredecessors: {},
            dataPredecessors: {},
            zeroValue: () => null,
            emptyStream: () => StreamReader<Object?>.fromIterable(const []),
          ),
        ),
        '_eino_dag_channel',
      );
      expect(TypeRegistry.nameOf(PregelChannel()), '_eino_pregel_channel');
      expect(
        TypeRegistry.nameOf(GraphInterruptInfo()),
        '_eino_compose_interrupt_info',
      );
      expect(
        TypeRegistry.nameOf(ToolsInterruptAndRerunExtra(toolCalls: const [])),
        '_eino_compose_tools_interrupt_and_rerun_extra',
      );
    });

    test('a checkpoint with everything in it', () {
      final address = Address(const [
        AddressSegment(type: AddressSegmentType.runnable, id: 'root'),
        AddressSegment(type: AddressSegmentType.node, id: 'tools'),
        AddressSegment(type: AddressSegmentType.tool, id: 'search', subId: 'call_1'),
      ]);
      final dag = DagChannel(
        controlPredecessors: {
          'a': DependencyState.ready,
          'b': DependencyState.waiting,
          'c': DependencyState.skipped,
        },
        dataPredecessors: {'a': true, 'b': false},
        zeroValue: () => null,
        emptyStream: () => StreamReader<Object?>.fromIterable(const []),
      )
        ..values = {'a': Message.user('waiting')}
        ..skipped = false;
      final pregel = PregelChannel()..values = {'x': const _Point(1, 1), 'y': 'text'};
      final checkpoint = GraphCheckpoint(
        channels: {'n1': dag, 'n2': pregel},
        inputs: {
          'n1': [Message.user('in')],
          'n2': null,
          'n3': 'text',
        },
        state: const _Point(7, 8),
        skipPreHandler: {'sub': true},
        rerunNodes: ['sub', 'n3'],
        subGraphs: {
          'sub': GraphCheckpoint(
            state: {'nested': true},
            rerunNodes: ['inner'],
            interruptId2Address: {'i2': address},
          ),
        },
        interruptId2Address: {'i1': address},
        interruptId2State: {
          'i1': const InterruptState(
            state: _Point(2, 3),
            layerSpecificPayload: {'kind': 'agent'},
          ),
          'i0': const InterruptState(),
        },
      );

      final restored = _roundTrip(checkpoint)! as GraphCheckpoint;
      final restoredDag = restored.channels['n1']! as DagChannel;
      expect(restoredDag.controlPredecessors, dag.controlPredecessors);
      expect(restoredDag.dataPredecessors, dag.dataPredecessors);
      expect(restoredDag.values, {'a': Message.user('waiting')});
      expect(restoredDag.skipped, isFalse);
      expect(
        (restored.channels['n2']! as PregelChannel).values,
        {'x': const _Point(1, 1), 'y': 'text'},
      );
      expect(restored.inputs, {
        'n1': [Message.user('in')],
        'n2': null,
        'n3': 'text',
      });
      expect(restored.inputs.containsKey('n2'), isTrue);
      expect(restored.state, const _Point(7, 8));
      expect(restored.skipPreHandler, {'sub': true});
      expect(restored.rerunNodes, ['sub', 'n3']);
      expect(restored.subGraphs['sub']!.state, {'nested': true});
      expect(restored.subGraphs['sub']!.rerunNodes, ['inner']);
      expect(restored.subGraphs['sub']!.interruptId2Address, {'i2': address});
      expect(restored.interruptId2Address, {'i1': address});
      expect(restored.interruptId2State['i1']!.state, const _Point(2, 3));
      expect(
        restored.interruptId2State['i1']!.layerSpecificPayload,
        {'kind': 'agent'},
      );
      expect(restored.interruptId2State['i0']!.state, isNull);
    });

    test('an interrupt info, with nested graphs and points', () {
      final root = InterruptCtx(
        id: 'root-id',
        address: Address(const [
          AddressSegment(type: AddressSegmentType.runnable, id: 'root'),
        ]),
      );
      final info = GraphInterruptInfo(
        state: const _Point(1, 2),
        beforeNodes: const ['b'],
        afterNodes: const ['a'],
        rerunNodes: const ['r'],
        rerunNodesExtra: const {'r': 'extra'},
        subGraphs: {
          'sub': GraphInterruptInfo(afterNodes: const ['x']),
        },
        interruptContexts: [
          InterruptCtx(
            id: 'leaf-id',
            address: root.address.append(
              const AddressSegment(type: AddressSegmentType.node, id: 'r'),
            ),
            info: const _Point(9, 9),
            isRootCause: true,
            parent: root,
          ),
        ],
      );
      final restored = _roundTrip(info)! as GraphInterruptInfo;
      expect(restored.state, const _Point(1, 2));
      expect(restored.beforeNodes, ['b']);
      expect(restored.afterNodes, ['a']);
      expect(restored.rerunNodes, ['r']);
      expect(restored.rerunNodesExtra, {'r': 'extra'});
      expect(restored.subGraphs['sub']!.afterNodes, ['x']);
      final point = restored.interruptContexts.single;
      expect(point.id, 'leaf-id');
      expect(point.equalsWithoutId(info.interruptContexts.single), isTrue);
      expect(point.parent!.id, 'root-id');
    });

    test('an interrupt info keeps an unregistered info as text', () {
      final info = GraphInterruptInfo(
        rerunNodesExtra: const {'n': _Unregistered()},
        interruptContexts: [
          InterruptCtx(
            id: 'i',
            address: const Address.empty(),
            info: const _Unregistered(),
            isRootCause: true,
          ),
        ],
      );
      final restored = _roundTrip(info)! as GraphInterruptInfo;
      expect(restored.rerunNodesExtra['n'], "Instance of '_Unregistered'");
      expect(
        restored.interruptContexts.single.info,
        "Instance of '_Unregistered'",
      );
    });

    test('what a tools node reports and keeps', () {
      final extra = ToolsInterruptAndRerunExtra(
        toolCalls: const [
          ToolCall(id: 'c1', function: FunctionCall(name: 'a', arguments: '{}')),
          ToolCall(id: 'c2', function: FunctionCall(name: 'b', arguments: '{}')),
        ],
        executedTools: const {'c1': 'done'},
        executedEnhancedTools: {'c3': ToolResult.text('rich')},
        rerunTools: const ['c2'],
        rerunExtraMap: const {'c2': 'approve?'},
      );
      final restored = _roundTrip(extra)! as ToolsInterruptAndRerunExtra;
      expect(restored.toolCalls, extra.toolCalls);
      expect(restored.executedTools, {'c1': 'done'});
      expect(restored.executedEnhancedTools, {'c3': ToolResult.text('rich')});
      expect(restored.rerunTools, ['c2']);
      expect(restored.rerunExtraMap, {'c2': 'approve?'});
      expect(restored.toString(), contains('rerunTools: [c2]'));
    });

    test('an unencodable input names the node', () {
      final checkpoint = GraphCheckpoint(inputs: {'node': const _Unregistered()});
      expect(
        () => const JsonCheckpointSerializer().serialize(checkpoint),
        throwsA(
          isA<CheckpointEncodeException>().having(
            (e) => e.message,
            'message',
            allOf(contains('the input of node[node]'), contains('_Unregistered')),
          ),
        ),
      );
    });

    test('an unencodable state and an unencodable output are named too', () {
      expect(
        () => const JsonCheckpointSerializer()
            .serialize(GraphCheckpoint(state: const _Unregistered())),
        throwsA(
          isA<CheckpointEncodeException>()
              .having((e) => e.message, 'message', contains('the state of the graph')),
        ),
      );
      final channel = PregelChannel()..values = {'from': const _Unregistered()};
      expect(
        () => const JsonCheckpointSerializer()
            .serialize(GraphCheckpoint(channels: {'to': channel})),
        throwsA(
          isA<CheckpointEncodeException>()
              .having((e) => e.message, 'message', contains('the output of node[from]')),
        ),
      );
      expect(
        const CheckpointEncodeException('x').toString(),
        'CheckpointEncodeException: x',
      );
    });
  });

  group('values get their types back', () {
    test('reviveAs gives lists and maps the narrowest type that holds them', () {
      expect(reviveAs<List<String>>(<Object?>['a', 'b']), isA<List<String>>());
      expect(reviveAs<List<int>>(<Object?>[1, 2]), [1, 2]);
      expect(reviveAs<List<double>>(<Object?>[1.5, 2.5]), isA<List<double>>());
      expect(reviveAs<List<num>>(<Object?>[1, 2.5]), isA<List<num>>());
      expect(reviveAs<List<String?>>(<Object?>['a', null]), isA<List<String?>>());
      expect(
        reviveAs<List<List<double>>>(<Object?>[
          <Object?>[0.1, 0.2],
          <Object?>[0.3],
        ]),
        isA<List<List<double>>>(),
      );
      expect(
        reviveAs<Map<String, String>>(<String, Object?>{'a': 'b'}),
        isA<Map<String, String>>(),
      );
      expect(
        reviveAs<Map<String, List<int>>>(<String, Object?>{
          'a': <Object?>[1],
        }),
        isA<Map<String, List<int>>>(),
      );
      expect(
        reviveAs<List<Message>>(<Object?>[Message.user('a')]),
        isA<List<Message>>(),
      );
      expect(
        reviveAs<List<_Point>>(<Object?>[const _Point(1, 2)]),
        isA<List<_Point>>(),
      );
      expect(
        reviveAs<List<Map<String, Object?>>>(<Object?>[
          <String, Object?>{'a': 1},
          <String, Object?>{'b': 'x'},
        ]),
        isA<List<Map<String, Object?>>>(),
      );
    });

    test('an empty list or map fits every element type', () {
      expect(reviveAs<List<String>>(<Object?>[]), isA<List<String>>());
      expect(reviveAs<List<Message>>(<Object?>[]), isEmpty);
      expect(
        reviveAs<Map<String, int>>(<String, Object?>{}),
        isA<Map<String, int>>(),
      );
    });

    test('a value that already fits is returned as it is', () {
      final list = <String>['a'];
      expect(reviveAs<List<String>>(list), same(list));
      expect(reviveAs<String>('x'), 'x');
      final loose = <Object?>['a', 1];
      expect(reviveAs<List<Object?>>(loose), same(loose));
    });

    test('a value that does not fit is not made to fit', () {
      expect(reviveAs<List<String>>(<Object?>['a', 1]), isNull);
      expect(reviveAs<String>(1), isNull);
      expect(reviveAs<_Point>(<String, Object?>{'x': 1, 'y': 2}), isNull);
      expect(reviveAs<List<int>>(null), isNull);
      expect(reviveFor<List<String>>(<Object?>['a', 1]), ['a', 1]);
      expect(reviveFor<List<String>>(<Object?>['a', 1]), isNot(isA<List<String>>()));
    });

    test('the collections are as wide as the place allows, and can grow', () {
      final numbers = reviveAs<List<num>>(<Object?>[1, 2])!;
      expect(numbers, isA<List<num>>());
      numbers.add(2.5);
      expect(numbers, [1, 2, 2.5]);

      final strings = reviveAs<List<String>>(<Object?>[])!;
      strings.add('x');
      expect(strings, ['x']);

      final messages = reviveAs<List<Message>>(<Object?>[])!;
      messages.add(Message.user('a'));
      expect(messages, hasLength(1));

      final points = reviveAs<List<_Point>>(<Object?>[])!;
      points.add(const _Point(1, 1));
      expect(points, hasLength(1));

      final anything = reviveAs<List<Object?>>(<Object?>[1])!;
      anything.add('text');
      expect(anything, [1, 'text']);

      final nested = reviveAs<List<List<double>>>(<Object?>[<Object?>[]])!;
      nested.single.add(1.5);
      nested.add([2.5]);
      expect(nested, [
        [1.5],
        [2.5],
      ]);

      final map = reviveAs<Map<String, num?>>(<String, Object?>{'a': 1})!;
      map['b'] = null;
      map['c'] = 1.5;
      expect(map, {'a': 1, 'b': null, 'c': 1.5});

      final loose = reviveAs<Map<String, Object>>(<String, Object?>{'a': 1})!;
      loose['b'] = 'x';
      expect(loose, {'a': 1, 'b': 'x'});

      // What JSON gave is kept where the place takes anything.
      final raw = <Object?>[
        <Object?>[1],
      ];
      expect(reviveFor<List<Object?>>(raw), same(raw));
      final inner = reviveAs<List<List<Object?>>>(raw)!;
      expect(inner, raw);
      inner.single.add('anything');
    });

    test('an empty list for an unknown class takes no elements', () {
      final list = reviveAs<List<_Unregistered>>(<Object?>[]);
      expect(list, isA<List<_Unregistered>>());
      expect(() => list!.add(const _Unregistered()), throwsA(isA<TypeError>()));
    });

    test('TypeRef.revive is the same for a type known only as a value', () {
      const type = TypeRef<List<String>>();
      expect(type.revive(<Object?>['a']), isA<List<String>>());
      final mixed = <Object?>['a', 1];
      expect(type.revive(mixed), same(mixed));
      expect(const TypeRef<String>().revive('x'), 'x');
    });

    test('TypeRef.restoreStream and concatStream are each other\'s inverse',
        () async {
      const type = TypeRef<List<String>>();
      final stream = type.restoreStream(<Object?>['a', 'b']);
      expect(stream, isA<StreamReader<List<String>>>());
      expect(await type.concatStream(stream, (_) => false), ['a', 'b']);

      expect(await type.restoreStream(null).collectAll(), isEmpty);
      expect(
        await type.concatStream(
          StreamReader<List<String>>.fromIterable(const []),
          (_) => false,
        ),
        isNull,
      );
      expect(
        () => type.restoreStream(42),
        throwsA(isA<ComposeTypeException>()),
      );
    });

    test('concatStream stops at an error it is told to ignore', () async {
      const type = TypeRef<String>();
      final (reader, writer) = pipe<String>(capacity: 4);
      writer
        ..send('a')
        ..send('b')
        ..sendError(StateError('cut'))
        ..close();
      final seen = <Object>[];
      expect(
        await type.concatStream(reader, (error) {
          seen.add(error);
          return true;
        }),
        'ab',
      );
      expect(seen.single, isStateError);

      final (failing, failingWriter) = pipe<String>(capacity: 4);
      failingWriter
        ..send('a')
        ..sendError(StateError('cut'))
        ..close();
      await expectLater(
        type.concatStream(failing, (_) => false),
        throwsA(isA<StreamReadException>()),
      );
    });
  });

  group('deepCopyState', () {
    test('copies a registered class and plain JSON', () {
      const point = _Point(1, 2);
      expect(deepCopyState(point), point);
      final map = <String, Object?>{
        'list': <Object?>[1, 2],
        'point': point,
      };
      final copy = deepCopyState(map)! as Map<String, Object?>;
      expect(copy, map);
      expect(copy, isNot(same(map)));
      expect(copy['list'], isNot(same(map['list'])));
      expect(deepCopyState(null), isNull);
    });

    test('returns what it cannot encode as it is', () {
      const state = _Unregistered();
      expect(deepCopyState(state), same(state));
    });
  });

  group('a graph with a checkpoint store checks its state type', () {
    final ctx = RunContext.background();

    Graph<String, String> graphWith(LocalState state) => Graph<String, String>(
          localState: state,
        )
          ..addLambdaNode('a', Lambda<String, String>.invokable((ctx, s) => s))
          ..addEdge(Graph.start, 'a')
          ..addEdge('a', Graph.end);

    test('an unregistered class is refused at compile', () async {
      await expectLater(
        graphWith(LocalState.of<_Unregistered>((ctx) => const _Unregistered()))
            .compile(
          ctx,
          options: GraphCompileOptions(checkpointStore: InMemoryCheckpointStore()),
        ),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            allOf(contains('_Unregistered'), contains('TypeRegistry.registerName')),
          ),
        ),
      );
    });

    test('without a store any state type will do', () async {
      final runnable = await graphWith(
        LocalState.of<_Unregistered>((ctx) => const _Unregistered()),
      ).compile(ctx);
      expect(await runnable.invoke(ctx, 'x'), 'x');
    });

    test('a registered class, JSON, and an interface a registered class '
        'implements are accepted', () async {
      final options =
          GraphCompileOptions(checkpointStore: InMemoryCheckpointStore());
      for (final state in [
        LocalState.of<_Point>((ctx) => const _Point(0, 0)),
        LocalState.of<Map<String, Object?>>((ctx) => {}),
        LocalState.of<List<Object?>>((ctx) => []),
        LocalState.of<_Shape>((ctx) => const _Circle(1)),
      ]) {
        final runnable = await graphWith(state).compile(ctx, options: options);
        expect(await runnable.invoke(ctx, 'x'), 'x');
      }
    });
  });

  group('typed node inputs after a resume', () {
    final ctx = RunContext.background();

    test('a List<String> input comes back as a List<String>', () async {
      final store = InMemoryCheckpointStore();
      final g = Graph<String, int>()
        ..addLambdaNode(
          'split',
          Lambda.invokable((ctx, String input) => input.split(',')),
        )
        ..addLambdaNode(
          'count',
          Lambda.invokable((ctx, List<String> parts) => parts.length),
        )
        ..addEdge(Graph.start, 'split')
        ..addEdge('split', 'count')
        ..addEdge('count', Graph.end);
      final r = await g.compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: store,
          interruptBeforeNodes: const ['count'],
        ),
      );
      await expectLater(
        r.invoke(ctx, 'a,b,c', options: [CallOption.checkpointId('id')]),
        throwsA(isA<GraphInterruptedException>()),
      );
      // What the store holds is JSON: the list has lost its element type.
      final stored = jsonDecode(utf8.decode((await store.get('id'))!));
      expect(jsonEncode(stored), contains('["a","b","c"]'));
      expect(
        await r.invoke(ctx, '', options: [CallOption.checkpointId('id')]),
        3,
      );
    });

    test('the same in a streaming run', () async {
      final store = InMemoryCheckpointStore();
      final g = Graph<String, List<List<double>>>()
        ..addLambdaNode(
          'vectors',
          Lambda.invokable(
            (ctx, String input) => [
              for (final part in input.split(',')) [double.parse(part)],
            ],
          ),
        )
        ..addLambdaNode(
          'double',
          Lambda.invokable(
            (ctx, List<List<double>> vectors) => [
              for (final vector in vectors) [for (final v in vector) v * 2],
            ],
          ),
        )
        ..addEdge(Graph.start, 'vectors')
        ..addEdge('vectors', 'double')
        ..addEdge('double', Graph.end);
      final r = await g.compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: store,
          interruptBeforeNodes: const ['double'],
        ),
      );
      await expectLater(
        r.stream(ctx, '1.5,2.5', options: [CallOption.checkpointId('id')]),
        throwsA(isA<GraphInterruptedException>()),
      );
      final stream =
          await r.stream(ctx, '', options: [CallOption.checkpointId('id')]);
      expect(await stream.collectAll(), [
        [
          [3.0],
          [5.0],
        ],
      ]);
    });
  });

  group('InMemoryCheckpointStore', () {
    test('keeps copies, by key', () async {
      final store = InMemoryCheckpointStore();
      expect(await store.get('a'), isNull);
      final bytes = Uint8List.fromList([1, 2, 3]);
      await store.set('a', bytes);
      bytes[0] = 9;
      expect(await store.get('a'), [1, 2, 3]);
      (await store.get('a'))![1] = 9;
      expect(await store.get('a'), [1, 2, 3]);
      await store.set('a', Uint8List.fromList([4]));
      expect(await store.get('a'), [4]);
      expect(store.keys, ['a']);
      await store.delete('a');
      await store.delete('missing');
      expect(await store.get('a'), isNull);
      expect(store.keys, isEmpty);
    });
  });
}
