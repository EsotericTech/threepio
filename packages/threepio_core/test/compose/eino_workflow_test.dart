// Port of eino `compose/workflow_test.go` (v0.9.22), the tests:
// TestWorkflow, TestWorkflowWithMap, TestWorkflowWithNestedFieldMappings,
// TestWorkflowCompile, TestFanInToSameDest, TestIndirectEdge,
// TestDependencyWithNoInput, TestStaticValue, TestBranch,
// TestMayAssignableFieldMapping, TestNilValue, TestStreamFieldMap,
// TestRuntimeTypeCheck, TestIntermediateMappingSource,
// TestSetFanInMergeConfig_RealStreamNode_Workflow, TestCustomExtractor,
// TestAddDependency, TestIndirectDependencyWithBranch.
//
// Go maps struct fields by reflection. Here a Go test struct is a small class
// that implements `FieldAddressable` under the Go field names ("Field1"), and
// a class that mappings write to registers its empty value. What Go finds at
// `Compile` by reflecting over the field types (an unknown field, a field of
// the wrong type) is found here when the workflow runs, as a
// `FieldMappingException`; the cases that moved say so.
//
// Go's `map[string]any` is `Map<String, Object?>`, `any` is `Object?`. Error
// texts are compared with the Dart type names and Dart's list format
// (`[a, b]` where Go prints `[a b]`).
import 'package:collection/collection.dart';
import 'package:test/test.dart';
import 'package:threepio_core/src/compose/stream_conversion.dart'
    show concatStreamReader;
import 'package:threepio_core/threepio_core.dart';

/// A Go test struct: named fields that field mappings read and replace.
abstract base class _GoStruct implements FieldAddressable {
  const _GoStruct();

  /// The values of the fields, by their Go names.
  Map<String, Object?> get fields;

  /// The struct of this type that has [f] as its fields. A value that does
  /// not fit its field is a `TypeError`, as `withField` allows.
  _GoStruct copy(Map<String, Object?> f);

  @override
  Object? getField(String name) {
    final fields = this.fields;
    if (!fields.containsKey(name)) {
      throw ArgumentError.value(name, 'name', '$runtimeType has no such field');
    }
    return fields[name];
  }

  @override
  _GoStruct withField(String name, Object? value) {
    final fields = this.fields;
    if (!fields.containsKey(name)) {
      throw ArgumentError.value(name, 'name', '$runtimeType has no such field');
    }
    return copy({...fields, name: value});
  }

  @override
  bool operator ==(Object other) =>
      other is _GoStruct &&
      other.runtimeType == runtimeType &&
      const DeepCollectionEquality().equals(fields, other.fields);

  @override
  int get hashCode => const DeepCollectionEquality().hash(fields);

  @override
  String toString() => '$runtimeType$fields';
}

/// Go: `structA` of TestWorkflow, the input of the workflow.
final class _WfA extends _GoStruct {
  const _WfA({this.field1 = '', this.field2 = 0, this.field3 = const []});

  final String field1;
  final int field2;
  final List<Object?> field3;

  @override
  Map<String, Object?> get fields =>
      {'Field1': field1, 'Field2': field2, 'Field3': field3};

  @override
  _WfA copy(Map<String, Object?> f) => _WfA(
        field1: f['Field1']! as String,
        field2: f['Field2']! as int,
        field3: f['Field3']! as List<Object?>,
      );
}

/// Go: `structB` of TestWorkflow.
final class _WfB extends _GoStruct {
  const _WfB({this.field1 = '', this.field2 = 0});

  final String field1;
  final int field2;

  @override
  Map<String, Object?> get fields => {'Field1': field1, 'Field2': field2};

  @override
  _WfB copy(Map<String, Object?> f) =>
      _WfB(field1: f['Field1']! as String, field2: f['Field2']! as int);
}

/// Go: `structC` of TestWorkflow.
final class _WfC extends _GoStruct {
  const _WfC({this.field1 = ''});

  final String field1;

  @override
  Map<String, Object?> get fields => {'Field1': field1};

  @override
  _WfC copy(Map<String, Object?> f) => _WfC(field1: f['Field1']! as String);
}

/// Go: `structE` of TestWorkflow.
final class _WfE extends _GoStruct {
  const _WfE({this.field1 = '', this.field2 = '', this.field3 = const []});

  final String field1;
  final String field2;
  final List<Object?> field3;

  @override
  Map<String, Object?> get fields =>
      {'Field1': field1, 'Field2': field2, 'Field3': field3};

  @override
  _WfE copy(Map<String, Object?> f) => _WfE(
        field1: f['Field1']! as String,
        field2: f['Field2']! as String,
        field3: f['Field3']! as List<Object?>,
      );
}

/// Go: `structF` of TestWorkflow.
final class _WfF extends _GoStruct {
  const _WfF({
    this.field1 = '',
    this.field2 = '',
    this.field3 = const [],
    this.b = 0,
    this.stateTemp = '',
  });

  final String field1;
  final String field2;
  final List<Object?> field3;
  final int b;
  final String stateTemp;

  @override
  Map<String, Object?> get fields => {
        'Field1': field1,
        'Field2': field2,
        'Field3': field3,
        'B': b,
        'StateTemp': stateTemp,
      };

  @override
  _WfF copy(Map<String, Object?> f) => _WfF(
        field1: f['Field1']! as String,
        field2: f['Field2']! as String,
        field3: f['Field3']! as List<Object?>,
        b: f['B']! as int,
        stateTemp: f['StateTemp']! as String,
      );
}

/// Go: `state` of TestWorkflow.
final class _WfState {
  String temp = '';
}

/// Go: `structEnd` of TestWorkflow.
final class _WfEnd extends _GoStruct {
  const _WfEnd({this.field1 = ''});

  final String field1;

  @override
  Map<String, Object?> get fields => {'Field1': field1};

  @override
  _WfEnd copy(Map<String, Object?> f) =>
      _WfEnd(field1: f['Field1']! as String);
}

/// Go: `struct2` of TestWorkflow.
final class _Wf2 extends _GoStruct {
  const _Wf2({this.f = const {}});

  final Map<String, Object?> f;

  @override
  Map<String, Object?> get fields => {'F': f};

  @override
  _Wf2 copy(Map<String, Object?> f) =>
      _Wf2(f: f['F']! as Map<String, Object?>);
}

/// Go: `structA` of TestWorkflowWithMap.
final class _MapA extends _GoStruct {
  const _MapA({this.f1});

  final Object? f1;

  @override
  Map<String, Object?> get fields => {'F1': f1};

  @override
  _MapA copy(Map<String, Object?> f) => _MapA(f1: f['F1']);
}

/// Go: `structA` of TestWorkflowWithNestedFieldMappings.
final class _NestedA extends _GoStruct {
  const _NestedA({this.f1 = ''});

  final String f1;

  @override
  Map<String, Object?> get fields => {'F1': f1};

  @override
  _NestedA copy(Map<String, Object?> f) => _NestedA(f1: f['F1']! as String);
}

/// Go: `structB` of TestWorkflowWithNestedFieldMappings. `F1` is a pointer in
/// Go, so it is nullable; `F6` is a struct value, so it is never null.
final class _NestedB extends _GoStruct {
  const _NestedB({
    this.f1,
    this.f2,
    this.f3 = 0,
    this.f4,
    this.f5,
    this.f6 = const _NestedA(),
  });

  final _NestedA? f1;
  final Map<String, Object?>? f2;
  final int f3;
  final Object? f4;
  final Map<String, _NestedA>? f5;
  final _NestedA f6;

  @override
  Map<String, Object?> get fields =>
      {'F1': f1, 'F2': f2, 'F3': f3, 'F4': f4, 'F5': f5, 'F6': f6};

  @override
  _NestedB copy(Map<String, Object?> f) => _NestedB(
        f1: f['F1'] as _NestedA?,
        f2: f['F2'] as Map<String, Object?>?,
        f3: f['F3']! as int,
        f4: f['F4'],
        f5: f['F5'] as Map<String, _NestedA>?,
        f6: f['F6']! as _NestedA,
      );
}

/// Go: `fmt.Stringer`, the interface type of the map values in
/// TestWorkflowWithNestedFieldMappings, TestNilValue and
/// TestIntermediateMappingSource.
abstract interface class _Stringer {
  String string();
}

/// Go: `type stringAlias string` of TestWorkflowCompile.
extension type const _StringAlias(String value) implements String {}

/// Go: `dest` of TestFanInToSameDest.
final class _FanDest extends _GoStruct {
  const _FanDest({this.f = const {}});

  final Map<String, Object?> f;

  @override
  Map<String, Object?> get fields => {'F': f};

  @override
  _FanDest copy(Map<String, Object?> f) =>
      _FanDest(f: f['F']! as Map<String, Object?>);
}

/// Go: `in` of TestFanInToSameDest.
final class _FanIn extends _GoStruct {
  const _FanIn({this.a = '', this.b = 0});

  final String a;
  final int b;

  @override
  Map<String, Object?> get fields => {'A': a, 'B': b};

  @override
  _FanIn copy(Map<String, Object?> f) =>
      _FanIn(a: f['A']! as String, b: f['B']! as int);
}

/// Go: `a` of TestStaticValue.
final class _StaticA extends _GoStruct {
  const _StaticA({this.b = '', this.d = ''});

  final String b;
  final String d;

  @override
  Map<String, Object?> get fields => {'B': b, 'D': d};

  @override
  _StaticA copy(Map<String, Object?> f) =>
      _StaticA(b: f['B']! as String, d: f['D']! as String);
}

/// Go: `s` of TestStaticValue. `A` is a struct value, so it is never null.
final class _StaticS extends _GoStruct {
  const _StaticS({this.a = const _StaticA(), this.c});

  final _StaticA a;
  final Map<String, Object?>? c;

  @override
  Map<String, Object?> get fields => {'A': a, 'C': c};

  @override
  _StaticS copy(Map<String, Object?> f) => _StaticS(
        a: f['A']! as _StaticA,
        c: f['C'] as Map<String, Object?>?,
      );
}

/// Go: `type goodInterface interface{ GOOD() }`.
abstract interface class _GoodInterface {
  void good();
}

/// Go: `type goodStruct struct{}`.
final class _GoodStruct implements _GoodInterface {
  const _GoodStruct();

  @override
  void good() {}
}

/// Go: `in` of TestMayAssignableFieldMapping.
final class _MayIn extends _GoStruct {
  const _MayIn({this.a});

  final _GoodInterface? a;

  @override
  Map<String, Object?> get fields => {'A': a};

  @override
  _MayIn copy(Map<String, Object?> f) => _MayIn(a: f['A'] as _GoodInterface?);
}

/// Go: `in`, `out` and `inOut` of TestNilValue: `struct{ A *string }`.
final class _NilA extends _GoStruct {
  const _NilA({this.a});

  final String? a;

  @override
  Map<String, Object?> get fields => {'A': a};

  @override
  _NilA copy(Map<String, Object?> f) => _NilA(a: f['A'] as String?);
}

/// Go: `inner` of TestIntermediateMappingSource.
final class _Inner extends _GoStruct {
  const _Inner({this.a = ''});

  final String a;

  @override
  Map<String, Object?> get fields => {'A': a};

  @override
  _Inner copy(Map<String, Object?> f) => _Inner(a: f['A']! as String);
}

/// Go: `type goodStruct2 struct{ A string; c string }`, a `fmt.Stringer`. The
/// unexported field `c` has no Dart equivalent.
final class _GoodStruct2 extends _GoStruct implements _Stringer {
  const _GoodStruct2({this.a = ''});

  final String a;

  @override
  String string() => a;

  @override
  Map<String, Object?> get fields => {'A': a};

  @override
  _GoodStruct2 copy(Map<String, Object?> f) =>
      _GoodStruct2(a: f['A']! as String);
}

/// Go: `model.NewMockChatModel`.
final class _FakeChatModel extends BaseChatModel {
  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      Message.assistant('fake');

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      StreamReader.fromIterable([Message.assistant('fake')]);
}

/// Go: `embedding.NewMockEmbedder`.
final class _FakeEmbedder extends Embedder {
  @override
  Future<List<List<double>>> embedStrings(
    List<String> texts, {
    EmbedderOptions? options,
  }) async =>
      [
        for (final text in texts) [text.length.toDouble()],
      ];
}

/// Go: `indexer.NewMockIndexer`.
final class _FakeIndexer implements Indexer {
  @override
  Future<List<String>> store(
    RunContext ctx,
    List<Document> docs, {
    IndexerOptions? options,
  }) async =>
      [for (var i = 0; i < docs.length; i++) 'id$i'];
}

/// Go: `&ToolsNode{}`.
ToolsNode _emptyToolsNode() => ToolsNode(const ToolsNodeConfig(tools: []));

/// Go: `err.Error()`: the texts of [error] and of its causes.
String _errorText(Object error) {
  final texts = <String>[];
  Object? current = error;
  for (var depth = 0; depth < 16 && current != null; depth++) {
    texts.add(current.toString());
    current = current is ThreepioException ? current.cause : null;
  }
  return texts.join('\n');
}

/// Go: `assert.ErrorContains(t, err, text)` for an error of `Compile`.
Matcher _buildErrorContaining(String text) => throwsA(
      isA<GraphBuildException>()
          .having((e) => e.toString(), 'toString()', contains(text)),
    );

/// Go: `assert.ErrorContains(t, err, text)` for an error of applying field
/// mappings when the workflow runs: a `FieldMappingException`, on its own or
/// as a cause of the error of the run, that says [text] (and [text2]).
Matcher _mappingErrorContaining(String text, [String? text2]) => throwsA(
      allOf([
        predicate<Object>(
          (e) => ThreepioException.findCause<FieldMappingException>(e) != null,
          'has a FieldMappingException among its causes',
        ),
        for (final expected in [text, if (text2 != null) text2])
          predicate<Object>(
            (e) => _errorText(e).contains(expected),
            'says "$expected"',
          ),
      ]),
    );

/// Go: `for { chunk, err := s.Recv(); if err == io.EOF { break } … }`.
Future<List<T>> _recvAll<T>(StreamReader<T> reader) async {
  final chunks = <T>[];
  for (var i = 0; i < 100; i++) {
    try {
      chunks.add(await reader.recv());
    } on StreamEOFException {
      return chunks;
    }
  }
  fail('the stream did not end within 100 chunks');
}

/// Go: `sr, sw := schema.Pipe[T](n); sw.Send(x, nil)…; sw.Close()`.
Future<StreamReader<T>> _pipeOf<T>(int capacity, List<T> chunks) async {
  final (reader, writer) = pipe<T>(capacity: capacity);
  chunks.forEach(writer.send);
  await writer.close();
  return reader;
}

void main() {
  final ctx = RunContext.background();

  setUpAll(() {
    // The types field mappings write to: Go creates their zero values by
    // reflection.
    FieldAddressable.registerBlank<_WfE>(() => const _WfE());
    FieldAddressable.registerBlank<_WfF>(() => const _WfF());
    FieldAddressable.registerBlank<_WfEnd>(() => const _WfEnd());
    FieldAddressable.registerBlank<_Wf2>(() => const _Wf2());
    FieldAddressable.registerBlank<_MapA>(() => const _MapA());
    FieldAddressable.registerBlank<_NestedA>(() => const _NestedA());
    FieldAddressable.registerBlank<_NestedB>(() => const _NestedB());
    FieldAddressable.registerBlank<_FanDest>(() => const _FanDest());
    FieldAddressable.registerBlank<_StaticS>(() => const _StaticS());
    FieldAddressable.registerBlank<_NilA>(() => const _NilA());

    // Go: `RegisterStreamChunkConcatFunc(func(ts []*structF) (*structF, error)`.
    StreamConcat.register<_WfF>(
      (chunks) => _WfF(
        field1: [for (final chunk in chunks) chunk.field1].join(),
        field2: [for (final chunk in chunks) chunk.field2].join(),
        field3: [for (final chunk in chunks) ...chunk.field3],
        b: chunks.fold(0, (sum, chunk) => sum + chunk.b),
        stateTemp: [for (final chunk in chunks) chunk.stateTemp].join(),
      ),
    );
  });

  test('TestWorkflow', () async {
    final subGraph = Graph<String, _WfB>()
      ..addLambdaNode(
        '1',
        Lambda.invokable(
          (ctx, String input) => _WfB(field1: input, field2: 33),
        ),
      )
      ..addEdge(Graph.start, '1')
      ..addEdge('1', Graph.end);

    final subChain = Chain<Object?, _WfC>()
      ..appendLambda(
        Lambda.invokable((ctx, Object? input) => _WfC(field1: '$input')),
      );

    final subWorkflow = Workflow<List<Object?>, List<Object?>>();
    subWorkflow
        .addLambdaNode(
          '1',
          Lambda.invokable((ctx, List<Object?> input) => input),
          options: const NodeOptions(outputKey: 'key'),
        )
        .addInput(Graph.start); // []any -> map["key"][]any
    subWorkflow
        .addLambdaNode(
          '2',
          Lambda.invokable((ctx, List<Object?> input) => input),
          options: const NodeOptions(inputKey: 'key', outputKey: 'key1'),
        )
        .addInput('1'); // map["key"][]any -> []any -> map["key1"][]any
    subWorkflow
        .addLambdaNode('3', Lambda.invokable((ctx, _Wf2 input) => input.f))
        // map["key1"][]any -> map["F"]map["key1"][]any ->
        // struct2{F: map["key1"]any} -> map["key1"][]any
        .addInput('2', [FieldMapping.toField('F')]);
    subWorkflow
        .addLambdaNode(
          '4',
          Lambda.invokable((ctx, List<Object?> input) => input),
          options: const NodeOptions(inputKey: 'key1'),
        )
        .addInput('3'); // map["key1"][]any -> []any
    subWorkflow.end().addInput('4');

    final w = Workflow<_WfA, _WfEnd>(
      localState: LocalState.of<_WfState>((ctx) => _WfState()),
    );

    w
        .addGraphNode(
          'B',
          subGraph,
          options: NodeOptions(
            statePostHandler: StateHandler.post<_WfB, _WfState>(
              (ctx, out, state) {
                state.temp = out.field1;
                return out;
              },
            ),
          ),
        )
        .addInput(Graph.start, [FieldMapping.fromField('Field1')]);

    w
        .addGraphNode('C', subChain)
        .addInput(Graph.start, [FieldMapping.fromField('Field2')]);

    w
        .addGraphNode('D', subWorkflow)
        .addInput(Graph.start, [FieldMapping.fromField('Field3')]);

    w.addLambdaNode(
      'E',
      Lambda.transformable(
        (ctx, StreamReader<_WfE> input) => input.convert<_WfE>(
          (chunk) => _WfE(
            field1: chunk.field1.isNotEmpty ? 'E:${chunk.field1}' : '',
            field2: chunk.field2.isNotEmpty ? 'E:${chunk.field2}' : '',
            field3: chunk.field3,
          ),
        ),
      ),
      options: NodeOptions(
        streamStatePreHandler: StateHandler.streamPre<_WfE, _WfState>(
          (ctx, input, state) {
            final temp = state.temp;
            return input.convert<_WfE>(
              (v) => v.field3.isEmpty
                  ? v
                  : _WfE(
                      field1: v.field1,
                      field2: v.field2,
                      field3: [...v.field3, 'Pre:$temp'],
                    ),
            );
          },
        ),
        streamStatePostHandler: StateHandler.streamPost<_WfE, _WfState>(
          (ctx, out, state) => out.convert<_WfE>(
            (v) => v.field1.isEmpty
                ? v
                : _WfE(
                    field1: '${v.field1}+Post',
                    field2: v.field2,
                    field3: v.field3,
                  ),
          ),
        ),
      ),
    )
      ..addInput('B', [FieldMapping.mapFields('Field1', 'Field1')])
      ..addInput('C', [FieldMapping.mapFields('Field1', 'Field2')])
      ..addInput('D', [FieldMapping.toField('Field3')]);

    w.addLambdaNode(
      'F',
      Lambda.invokable(
        // Go: `fmt.Sprintf("%v_%v_%v_%v_%v", …)`, which prints a slice as
        // `[1 good Pre:1]`.
        (ctx, _WfF input) => '${input.field1}_${input.field2}_'
            '[${input.field3.join(' ')}]_${input.b}_${input.stateTemp}',
      ),
      options: NodeOptions(
        statePreHandler: StateHandler.pre<_WfF, _WfState>(
          (ctx, input, state) => _WfF(
            field1: input.field1,
            field2: input.field2,
            field3: input.field3,
            b: input.b,
            stateTemp: state.temp,
          ),
        ),
      ),
    )
      ..addInput('B', [FieldMapping.mapFields('Field2', 'B')])
      ..addInput('E', [
        FieldMapping.mapFields('Field1', 'Field1'),
        FieldMapping.mapFields('Field2', 'Field2'),
        FieldMapping.mapFields('Field3', 'Field3'),
      ]);

    w.end().addInput('F', [FieldMapping.toField('Field1')]);

    final compiled = await w.compile(ctx);

    const input = _WfA(field1: '1', field2: 2, field3: [1, 'good']);
    const expected = _WfEnd(field1: 'E:1+Post_E:2_[1 good Pre:1]_33_1');
    expect(await compiled.invoke(ctx, input), expected);

    final outStream = await compiled.stream(ctx, input);
    for (final chunk in await _recvAll(outStream)) {
      expect(chunk, expected);
    }
    await outStream.close();
  });

  test('TestWorkflowWithMap', () async {
    final wf = Workflow<Map<String, Object?>, Map<String, Object?>>();
    wf
        .addLambdaNode(
          'lambda1',
          Lambda.invokable((ctx, Map<String, Object?> input) => input),
        )
        .addInput(
          Graph.start,
          [FieldMapping.mapFields('map_key', 'lambda1_key')],
        );
    wf
        .addLambdaNode('lambda2', Lambda.invokable((ctx, _MapA input) => input))
        .addInput(Graph.start, [FieldMapping.mapFields('map_key', 'F1')]);
    wf.end().addInput(
      'lambda1',
      [FieldMapping.mapFields('lambda1_key', 'end_lambda1')],
    );
    wf.end().addInput('lambda2', [FieldMapping.mapFields('F1', 'end_lambda2')]);
    final r = await wf.compile(ctx);
    expect(
      await r.invoke(ctx, {'map_key': 'value'}),
      {'end_lambda1': 'value', 'end_lambda2': 'value'},
    );
  });

  group('TestWorkflowWithNestedFieldMappings', () {
    test('from struct.struct.field', () async {
      var wf = Workflow<_NestedB, String>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['F1', 'F1']),
      ]);
      var r = await wf.compile(ctx);
      const input = _NestedB(f1: _NestedA(f1: 'hello'));
      expect(await r.invoke(ctx, input), 'hello');

      // Go finds the unknown field at Compile ("has no field[F2]"); without
      // reflection it is found when the workflow runs.
      wf = Workflow<_NestedB, String>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['F1', 'F2']),
      ]);
      r = await wf.compile(ctx);
      await expectLater(
        r.invoke(ctx, input),
        _mappingErrorContaining('but field not found. field=F2'),
      );
    });

    test('to struct.(non-ptr)struct.field', () async {
      final wf = Workflow<String, _NestedB>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['F6', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(
        await r.invoke(ctx, 'hello'),
        const _NestedB(f6: _NestedA(f1: 'hello')),
      );
    });

    test('to map.(non-ptr)struct.field', () async {
      final wf = Workflow<String, Map<String, _NestedA>>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['key', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(
        await r.invoke(ctx, 'hello'),
        {'key': const _NestedA(f1: 'hello')},
      );
    });

    test('from map.map.field', () async {
      final wf = Workflow<Map<String, Map<String, String>>, String>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['F1', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(
        await r.invoke(ctx, {
          'F1': {'F1': 'hello'},
        }),
        'hello',
      );

      // Go: an `internalError` that wraps an `errMapKeyNotFound`.
      await expectLater(
        r.invoke(ctx, {
          'F1': {'F2': 'hello'},
        }),
        _mappingErrorContaining(
          'field mapping from a map key, but key not found in input',
        ),
      );
    });

    test('from struct.map.field', () async {
      final wf = Workflow<_NestedB, String>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['F2', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, const _NestedB(f2: {'F1': 'hello'})), 'hello');

      // Go: an `internalError` that wraps an `errMapKeyNotFound`.
      await expectLater(
        r.invoke(ctx, const _NestedB(f2: {'F2': 'hello'})),
        _mappingErrorContaining(
          'field mapping from a map key, but key not found in input',
        ),
      );
    });

    test('from map.struct.field', () async {
      var wf = Workflow<Map<String, _NestedA>, String>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['F1', 'F1']),
      ]);
      var r = await wf.compile(ctx);
      const input = {'F1': _NestedA(f1: 'hello')};
      expect(await r.invoke(ctx, input), 'hello');

      // Go finds the unknown field at Compile ("has no field[F2]"); without
      // reflection it is found when the workflow runs.
      wf = Workflow<Map<String, _NestedA>, String>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['F1', 'F2']),
      ]);
      r = await wf.compile(ctx);
      await expectLater(
        r.invoke(ctx, input),
        _mappingErrorContaining('but field not found. field=F2'),
      );
    });

    test('from map[string]any.field', () async {
      final wf = Workflow<Map<String, Object?>, String>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['F1', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(
        await r.invoke(ctx, {'F1': const _NestedA(f1: 'hello')}),
        'hello',
      );

      expect(
        await r.invoke(ctx, {
          'F1': {'F1': 'hello'},
        }),
        'hello',
      );

      // Go: an `internalError` that wraps an
      // `errInterfaceNotValidForFieldMapping`.
      await expectLater(
        r.invoke(ctx, {'F1': 1}),
        _mappingErrorContaining(
          'field mapping from a value that is neither a map nor a '
          'FieldAddressable',
          'actual type=int',
        ),
      );
    });

    test('to struct.struct.field', () async {
      var wf = Workflow<String, _NestedB>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['F1', 'F1']),
      ]);
      var r = await wf.compile(ctx);
      expect(
        await r.invoke(ctx, 'hello'),
        const _NestedB(f1: _NestedA(f1: 'hello')),
      );

      // Go finds the unknown field at Compile ("has no field[F2]"); without
      // reflection it is found when the workflow runs.
      wf = Workflow<String, _NestedB>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['F1', 'F2']),
      ]);
      r = await wf.compile(ctx);
      await expectLater(
        r.invoke(ctx, 'hello'),
        _mappingErrorContaining('field[F2]'),
      );
    });

    test('to map.map.field', () async {
      final wf = Workflow<String, Map<String, Map<String, String>>>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['F1', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, 'hello'), {
        'F1': {'F1': 'hello'},
      });

      // Go refuses this at Compile ("field[string]-[int] is absolutely not
      // assignable"); without reflection the value that does not fit is
      // found when the workflow runs.
      final wf1 = Workflow<String, Map<String, Map<String, int>>>();
      wf1.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['F1', 'F1']),
      ]);
      final r1 = await wf1.compile(ctx);
      await expectLater(
        r1.invoke(ctx, 'hello'),
        _mappingErrorContaining('Map<String, Map<String, int>>'),
      );
    });

    test('to struct.map.field', () async {
      final wf = Workflow<String, _NestedB>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['F2', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, 'hello'), const _NestedB(f2: {'F1': 'hello'}));
    });

    test('to map.struct.struct.field', () async {
      final wf = Workflow<String, Map<String, _NestedB>>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['F1', 'F1', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, 'hello'), {
        'F1': const _NestedB(f1: _NestedA(f1: 'hello')),
      });
    });

    test('to struct.map.struct.field', () async {
      final wf = Workflow<String, _NestedB>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['F5', 'key', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(
        await r.invoke(ctx, 'hello'),
        const _NestedB(f5: {'key': _NestedA(f1: 'hello')}),
      );
    });

    test('to map.map.struct(non-ptr).field', () async {
      final wf = Workflow<String, Map<String, Map<String, _NestedA>>>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['key1', 'key2', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, 'hello'), {
        'key1': {'key2': const _NestedA(f1: 'hello')},
      });
    });

    test('to struct.int.field', () async {
      // Go refuses the path through an int at Compile ("type[int] is not
      // valid"); without reflection it is found when the workflow runs.
      final wf = Workflow<String, _NestedB>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['F3', 'F1', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      await expectLater(
        r.invoke(ctx, 'hello'),
        _mappingErrorContaining('type[int]', 'is not valid'),
      );
    });

    test('to struct.any.field', () async {
      final wf = Workflow<String, _NestedB>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['F4', 'F1', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(
        await r.invoke(ctx, 'hello'),
        const _NestedB(
          f4: {
            'F1': {'F1': 'hello'},
          },
        ),
      );
    });

    test('to map.any.any.field', () async {
      final wf = Workflow<String, Map<String, Object?>>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['Key1', 'Key2', 'Key3']),
      ]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, 'hello'), {
        'Key1': {
          'Key2': {'Key3': 'hello'},
        },
      });
    });

    test('to any', () async {
      final wf = Workflow<String, Object?>();
      wf.end().addInput(Graph.start);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, 'hello'), 'hello');
    });

    test('to any.field', () async {
      final wf = Workflow<String, Object?>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['Key1']),
      ]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, 'hello'), {'Key1': 'hello'});
    });

    test('to interface.field', () async {
      // Go refuses a path through an interface type at Compile ("the
      // successor has intermediate interface type fmt.Stringer"); without
      // reflection the fields that do not make the map of the output are
      // found when the workflow runs.
      final wf = Workflow<String, Map<String, _Stringer>>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['Key1', 'A']),
      ]);
      final r = await wf.compile(ctx);
      await expectLater(
        r.invoke(ctx, 'hello'),
        _mappingErrorContaining('Map<String, _Stringer>'),
      );
    });

    test('both to map.any, and to map.any.field', () async {
      final wf = Workflow<String, Map<String, Object?>>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['Key1']),
        FieldMapping.toFieldPath(['Key1', 'Key2']),
      ]);
      await expectLater(
        wf.compile(ctx),
        _buildErrorContaining('two terminal field paths conflict'),
      );
    });

    test('to map.any.any.field1, and to map.any.any.field2', () async {
      final wf = Workflow<String, Map<String, Object?>>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toFieldPath(['Key1', 'Key2', 'key3']),
        FieldMapping.toFieldPath(['Key1', 'Key2', 'key4']),
      ]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, 'hello'), {
        'Key1': {
          'Key2': {'key3': 'hello', 'key4': 'hello'},
        },
      });
    });

    test('from nested to nested', () async {
      final wf = Workflow<Map<String, Object?>, _NestedB>();
      wf.end().addInput(Graph.start, [
        FieldMapping.mapFieldPaths(['key1', 'key2'], ['F1', 'F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(
        await r.invoke(ctx, {
          'key1': {'key2': 'hello'},
        }),
        const _NestedB(f1: _NestedA(f1: 'hello')),
      );
    });

    test('from nested to normal', () async {
      final wf = Workflow<Map<String, Object?>, _NestedA>();
      wf.end().addInput(Graph.start, [
        FieldMapping.mapFieldPaths(['key1', 'key2'], ['F1']),
      ]);
      final r = await wf.compile(ctx);
      expect(
        await r.invoke(ctx, {
          'key1': {'key2': 'hello'},
        }),
        const _NestedA(f1: 'hello'),
      );
    });
  });

  group('TestWorkflowCompile', () {
    test('compile without add end', () async {
      final w = Workflow<Message, List<Message>>();
      w.addToolsNode('1', _emptyToolsNode()).addInput(Graph.start);
      await expectLater(
        w.compile(ctx),
        _buildErrorContaining('end node not set'),
      );
    });

    test('type mismatch', () async {
      final w = Workflow<String, String>();
      w.addToolsNode('1', _emptyToolsNode()).addInput(Graph.start);
      w.end().addInput('1');
      await expectLater(w.compile(ctx), _buildErrorContaining(' mismatch'));
    });

    test(
        "predecessor's output not struct/struct ptr/map, mapping has "
        'FromField', () async {
      final w = Workflow<List<Document>, List<String>>();
      w
          .addIndexerNode('indexer', _FakeIndexer())
          .addInput(Graph.start, [FieldMapping.fromField('F1')]);
      w.end().addInput('indexer');
      await expectLater(
        w.compile(ctx),
        _buildErrorContaining('predecessor output type should be struct'),
      );
    });

    test("successor's input not struct/struct ptr/map, mapping has ToField",
        () async {
      final w = Workflow<List<String>, List<List<double>>>();
      w
          .addEmbeddingNode('embedder', _FakeEmbedder())
          .addInput(Graph.start, [FieldMapping.toField('F1')]);
      w.end().addInput('embedder');
      await expectLater(
        w.compile(ctx),
        _buildErrorContaining('successor input type should be struct'),
      );
    });

    test('map to non existing field in predecessor', () async {
      // Go finds the unknown field at Compile ("type[schema.Message] has no
      // field[non_exist]"); without reflection it is found when the workflow
      // runs.
      final w = Workflow<Message, List<Message>>();
      w
          .addToolsNode('tools_node', _emptyToolsNode())
          .addInput(Graph.start, [FieldMapping.fromField('non_exist')]);
      w.end().addInput('tools_node');
      final r = await w.compile(ctx);
      await expectLater(
        r.invoke(ctx, Message.assistant('')),
        _mappingErrorContaining('but field not found. field=non_exist'),
      );
    });

    // Go: "map to not exported field in successor" and "map from not exported
    // field in predecessor" have no Dart equivalent: a `FieldAddressable`
    // has no unexported fields, a field it does not answer to is unknown.

    test('duplicate node key', () async {
      final w = Workflow<List<Message>, List<Message>>();
      w.addChatModelNode('1', _FakeChatModel()).addInput(Graph.start);
      w.addToolsNode('1', _emptyToolsNode()).addInput('1');
      w.end().addInput('1');
      await expectLater(
        w.compile(ctx),
        _buildErrorContaining("node '1' already present"),
      );
    });

    test('from non-existing node', () async {
      final w = Workflow<Message, List<Message>>();
      w.addToolsNode('1', _emptyToolsNode()).addInput(Graph.start);
      w.end().addInput('2');
      await expectLater(
        w.compile(ctx),
        _buildErrorContaining(
          "edge start node '2' needs to be added to graph first",
        ),
      );
    });

    test('to map with non-string key type', () async {
      final w = Workflow<String, Map<int, Object?>>();
      w.end().addInput(Graph.start, [FieldMapping.toField('1')]);
      await expectLater(
        w.compile(ctx),
        _buildErrorContaining(
          'type[Map<int, Object?>] is not a map with string or string alias '
          'key',
        ),
      );

      final w1 = Workflow<String, Map<_StringAlias, Object?>>();
      w1.end().addInput(Graph.start, [FieldMapping.toField('1')]);
      final r1 = await w1.compile(ctx);
      expect(
        await r1.invoke(ctx, 'hello'),
        {const _StringAlias('1'): 'hello'},
      );
    });

    test('from map with non-string key type', () async {
      final w = Workflow<Map<int, Object?>, String>();
      w.end().addInput(Graph.start, [FieldMapping.fromField('1')]);
      await expectLater(
        w.compile(ctx),
        _buildErrorContaining(
          'type[Map<int, Object?>] is not a map with string or string alias '
          'key',
        ),
      );

      final w1 = Workflow<Map<_StringAlias, Object?>, String>();
      w1.end().addInput(Graph.start, [FieldMapping.fromField('1')]);
      final r1 = await w1.compile(ctx);
      expect(
        await r1.invoke(ctx, {const _StringAlias('1'): 'hello'}),
        'hello',
      );
    });
  });

  group('TestFanInToSameDest', () {
    test('traditional outputKey fan-in with map[string]any', () async {
      final wf = Workflow<String, List<Message>>();
      wf
          .addLambdaNode(
            '1',
            Lambda.invokable((ctx, String input) => input),
            options: const NodeOptions(outputKey: 'q1'),
          )
          .addInput(Graph.start);
      wf
          .addLambdaNode(
            '2',
            Lambda.invokable((ctx, String input) => input),
            options: const NodeOptions(outputKey: 'q2'),
          )
          .addInput(Graph.start);
      wf.addChatTemplateNode(
        'prompt',
        ChatTemplate.fromMessages(
          FormatType.jinja2,
          [Message.user('{{q1}}_{{q2}}')],
        ),
      )
        ..addInput('1', [FieldMapping.mapFields('q1', 'q1')])
        ..addInput('2', [FieldMapping.mapFields('q2', 'q2')]);
      wf.end().addInput('prompt');
      final c = await wf.compile(ctx);
      final out = await c.invoke(ctx, 'query');
      expect(out, hasLength(1));
      expect(out.single.role, RoleType.user);
      expect(out.single.content, 'query_query');
    });

    test('fan-in to a field of map', () async {
      final wf = Workflow<_FanIn, _FanDest>();
      wf
          .addLambdaNode(
            '1',
            Lambda.invokable((ctx, String input) => input),
            options: const NodeOptions(outputKey: 'A'),
          )
          .addInput(Graph.start, [FieldMapping.fromField('A')]);
      wf
          .addLambdaNode(
            '2',
            Lambda.invokable((ctx, int input) => input),
            options: const NodeOptions(outputKey: 'B'),
          )
          .addInput(Graph.start, [FieldMapping.fromField('B')]);
      wf.end()
        ..addInput('1', [FieldMapping.toField('F')])
        ..addInput('2', [FieldMapping.toField('F')]);
      await expectLater(
        wf.compile(ctx),
        _buildErrorContaining(
          'two terminal field paths conflict for node end: [F], [F]',
        ),
      );
    });
  });

  test('TestIndirectEdge', () async {
    final wf = Workflow<String, Map<String, Object?>>();

    wf
        .addLambdaNode(
          '1',
          Lambda.invokable((ctx, String input) => '${input}_$input'),
        )
        .addInput(Graph.start);

    wf.addLambdaNode(
      '2',
      Lambda.invokable(
        (ctx, Map<String, String> input) =>
            '${input['1']}_${input[Graph.start]}',
      ),
    )
      ..addInput('1', [FieldMapping.toField('1')])
      ..addInputWithOptions(
        Graph.start,
        [FieldMapping.toField(Graph.start)],
        noDirectDependency: true,
      );

    wf.end()
      ..addInput('2', [FieldMapping.toField('2')])
      ..addInputWithOptions(
        '1',
        [FieldMapping.toField('1')],
        noDirectDependency: true,
      );

    final r = await wf.compile(ctx);
    expect(
      await r.invoke(ctx, 'query'),
      {'1': 'query_query', '2': 'query_query_query'},
    );
  });

  group('TestDependencyWithNoInput', () {
    test('simple case', () async {
      final wf = Workflow<String, String>();
      wf
          .addLambdaNode('0', Lambda.invokable((ctx, String input) => 'useless'))
          .addInput(Graph.start);
      wf.addLambdaNode(
        '1',
        Lambda.invokable((ctx, String input) => '${input}_done'),
      )
        ..addDependency('0')
        ..addInputWithOptions(Graph.start, const [], noDirectDependency: true);
      wf.end().addInput('1');
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, 'hello'), 'hello_done');
    });

    test("simple control flow: [Start] --> [Node '0'] --> [End]", () async {
      final wf = Workflow<Map<String, Object?>, Map<String, Object?>>();
      wf
          .addLambdaNode(
            '0',
            Lambda.invokable(
              (ctx, Map<String, Object?> input) =>
                  <String, Object?>{'result': 'result from node 0'},
            ),
          )
          .addDependency(Graph.start);
      wf.end()
        ..addInput('0', [FieldMapping.toField('final_result')])
        ..addInputWithOptions(
          Graph.start,
          [FieldMapping.toField('final_from_start')],
          noDirectDependency: true,
        );
      final r = await wf.compile(ctx);
      const expected = {
        'final_result': {'result': 'result from node 0'},
        'final_from_start': {'input': 'hello'},
      };
      expect(await r.invoke(ctx, {'input': 'hello'}), expected);

      final sRet = await r.stream(ctx, {'input': 'hello'});
      expect(await concatStreamReader(sRet), expected);
    });
  });

  group('TestStaticValue', () {
    test('prefill map', () async {
      final wf = Workflow<String, Map<String, Object?>>();
      wf.addLambdaNode(
        '0',
        Lambda.invokable((ctx, Map<String, Object?> input) => input),
      )
        ..addInput(Graph.start, [FieldMapping.toField(Graph.start)])
        ..setStaticValue(['prefilled'], 'yo-ho');
      wf.end().addInput('0');
      final r = await wf.compile(ctx);
      const expected = {'prefilled': 'yo-ho', Graph.start: 'hello'};
      expect(await r.invoke(ctx, 'hello'), expected);

      final streamOut = await r.stream(ctx, 'hello');
      final out = <String, Object?>{};
      (await _recvAll(streamOut)).forEach(out.addAll);
      expect(out, expected);
    });

    test('static value and to-all mapping conflict', () async {
      final wf = Workflow<Map<String, Object?>, Map<String, Object?>>();
      wf.addLambdaNode(
        '0',
        Lambda.invokable((ctx, Map<String, Object?> input) => input),
      )
        ..addInput(Graph.start)
        ..setStaticValue(['prefilled'], 'yo-ho');
      wf.end().addInput('0');
      await expectLater(
        wf.compile(ctx),
        _buildErrorContaining(
          'entire output has already been mapped for node: 0',
        ),
      );
    });

    test('static value and dynamic mapping conflict', () async {
      final wf = Workflow<String, Map<String, Object?>>();
      wf.addLambdaNode(
        '0',
        Lambda.invokable((ctx, Map<String, Object?> input) => input),
      )
        ..addInput(Graph.start, [FieldMapping.toField('prefilled')])
        ..setStaticValue(['prefilled'], 'yo-ho');
      wf.end().addInput('0');
      await expectLater(
        wf.compile(ctx),
        _buildErrorContaining(
          'two terminal field paths conflict for node 0: '
          '[prefilled], [prefilled]',
        ),
      );
    });

    test('all inputs are static values', () async {
      final wf = Workflow<String, Map<String, Object?>>();
      wf.addLambdaNode(
        '0',
        Lambda.invokable((ctx, Map<String, Object?> input) => input),
      )
        ..addDependency(Graph.start)
        ..setStaticValue(['a', 'b'], 'a_b')
        ..setStaticValue(['c', 'd'], 'c_d')
        ..setStaticValue(['a', 'd'], 'a_d');
      wf.end().addInput('0');
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, 'hello'), {
        'a': {'b': 'a_b', 'd': 'a_d'},
        'c': {'d': 'c_d'},
      });

      final wf1 = Workflow<String, _StaticS>();
      wf1.addLambdaNode(
        '0',
        Lambda.invokable((ctx, Map<String, Object?> input) => input),
      )
        ..addDependency(Graph.start)
        ..setStaticValue(['A', 'B'], 'a_b')
        ..setStaticValue(['C', 'D'], 'c_d')
        ..setStaticValue(['A', 'D'], 'a_d');
      wf1.end().addInput('0', [
        FieldMapping.mapFieldPaths(['A', 'B'], ['A', 'B']),
        FieldMapping.mapFieldPaths(['A', 'D'], ['A', 'D']),
        FieldMapping.mapFields('C', 'C'),
      ]);
      final r1 = await wf1.compile(ctx);
      final out1 = await r1.stream(ctx, 'hello');
      final outChunk = await out1.recv();
      await out1.close();
      expect(
        outChunk,
        const _StaticS(a: _StaticA(b: 'a_b', d: 'a_d'), c: {'D': 'c_d'}),
      );
    });
  });

  group('TestBranch', () {
    test(
        'simple branch: one predecessor, two successor, one of them is END',
        () async {
      final wf = Workflow<String, Map<String, Object?>>();
      wf
          .addLambdaNode(
            '1',
            Lambda.invokable((ctx, String input) => '${input}_$input'),
          )
          .addInputWithOptions(
            Graph.start,
            const [],
            noDirectDependency: true,
          );

      wf
          .addPassthroughNode('branch_1')
          .addInput(Graph.start, [FieldMapping.toField(Graph.start)]);

      final branch = GraphBranch.single<Map<String, Object?>>(
        (ctx, input) => input[Graph.start] == 'hello' ? '1' : Graph.end,
        {'1', Graph.end},
      );
      wf.addBranch('branch_1', branch);
      wf.end()
        ..addInput('1', [FieldMapping.toField('1')])
        ..addInputWithOptions(
          Graph.start,
          [FieldMapping.toField(Graph.start)],
          noDirectDependency: true,
        );
      final r = await wf.compile(ctx);
      expect(
        await r.invoke(ctx, 'hello'),
        {'1': 'hello_hello', Graph.start: 'hello'},
      );
      expect(await r.invoke(ctx, 'world'), {Graph.start: 'world'});
    });

    test('multiple predecessors', () async {
      final wf = Workflow<String, Map<String, Object?>>();
      wf
          .addLambdaNode(
            '1',
            Lambda.invokable((ctx, String input) => '${input}_$input'),
          )
          .addInput(Graph.start);
      wf
          .addLambdaNode(
            '2',
            Lambda.invokable((ctx, String input) => '${input}_$input'),
          )
          .addInputWithOptions('1', const [], noDirectDependency: true);
      wf
          .addLambdaNode(
            '0',
            Lambda.invokable((ctx, String input) => '${input}_$input'),
          )
          .addInput(Graph.start);

      wf.addPassthroughNode('branch_1')
        ..addInput(Graph.start, [FieldMapping.toField(Graph.start)])
        ..addInput('1', [FieldMapping.toField('1')])
        ..addDependency('0');
      wf.addBranch(
        'branch_1',
        GraphBranch.single<Map<String, Object?>>(
          (ctx, input) =>
              input[Graph.start]! as String == 'hello' ? '2' : Graph.end,
          {'2', Graph.end},
        ),
      );
      wf.end()
        ..addInput('2', [FieldMapping.toField('2')])
        ..addInputWithOptions(
          Graph.start,
          [FieldMapping.toField(Graph.start)],
          noDirectDependency: true,
        );
      final r = await wf.compile(ctx);
      expect(
        await r.invoke(ctx, 'hello'),
        {'2': 'hello_hello_hello_hello', Graph.start: 'hello'},
      );
      expect(await r.invoke(ctx, 'world'), {Graph.start: 'world'});
    });

    test('empty input for node after branch', () async {
      final wf = Workflow<Map<String, Object?>, Map<String, Object?>>();
      wf
          .addLambdaNode(
            'start_1',
            Lambda.invokable(
              (ctx, Map<String, Object?> input) => <String, Object?>{},
            ),
          )
          .addInput(Graph.start);
      wf.addLambdaNode(
        'branch_1',
        Lambda.invokable(
          (ctx, Map<String, Object?> input) => <String, Object?>{},
        ),
      );
      wf.addPassthroughNode('my_branch').addInput('start_1');
      wf.addBranch(
        'my_branch',
        GraphBranch.single<Map<String, Object?>>(
          (ctx, input) => Graph.end,
          {'branch_1', Graph.end},
        ),
      );
      wf.end().addInput('branch_1');
      final runner = await wf.compile(ctx);
      // Go: `(map[string]any)(nil)`, the zero value of the output type. The
      // empty value of a Dart map type is the empty map.
      expect(await runner.invoke(ctx, {}), <String, Object?>{});
    });
  });

  test('TestMayAssignableFieldMapping', () async {
    final wf = Workflow<_MayIn, _GoodStruct>();
    wf
        .addLambdaNode(
          '1',
          Lambda<_GoodStruct, _GoodInterface>.invokable((ctx, input) => input),
        )
        .addInput(Graph.start, [FieldMapping.fromField('A')]);
    wf.end().addInput('1');
    final r = await wf.compile(ctx);
    final result = await r.invoke(ctx, const _MayIn(a: _GoodStruct()));
    result.good();
  });

  group('TestNilValue', () {
    test('from map key with a nil value to map key', () async {
      final wf = Workflow<Map<String, Object?>, Map<String, Object?>>();
      wf.end().addInput(Graph.start, [FieldMapping.mapFields('a', 'a')]);
      final r = await wf.compile(ctx);

      expect(await r.invoke(ctx, {'a': null}), {'a': null});
    });

    test('from nil struct field to map key', () async {
      final wf = Workflow<_NilA, Map<String, Object?>>();
      wf.end().addInput(Graph.start, [FieldMapping.mapFields('A', 'A')]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, const _NilA()), {'A': null});
    });

    test('from map key with a nil value to struct field', () async {
      final wf = Workflow<Map<String, Object?>, _NilA>();
      wf.end().addInput(Graph.start, [FieldMapping.mapFields('A', 'A')]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, {'A': null}), const _NilA());
    });

    test('from nil struct field to struct field', () async {
      final wf = Workflow<_NilA, _NilA>();
      wf.end().addInput(Graph.start, [FieldMapping.mapFields('A', 'A')]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, const _NilA()), const _NilA());
    });

    test("from nil to a type that can't be nil", () async {
      final wf = Workflow<Map<String, Object?>, int>();
      wf.end().addInput(Graph.start, [FieldMapping.fromField('a')]);
      final r = await wf.compile(ctx);
      // Go: "field[<nil>]-[int]". The full text is the next test.
      await expectLater(
        r.invoke(ctx, {'a': null}),
        _mappingErrorContaining(
          'runtime check failed for mapping',
          'field[Null]-[int] is absolutely not assignable',
        ),
      );
    });

    test(
      "from nil to a type that can't be nil: the error names the mapping",
      () async {
        final wf = Workflow<Map<String, Object?>, int>();
        wf.end().addInput(Graph.start, [FieldMapping.fromField('a')]);
        final r = await wf.compile(ctx);
        await expectLater(
          r.invoke(ctx, {'a': null}),
          _mappingErrorContaining(
            'runtime check failed for mapping [from a(field) of start], '
            'field[Null]-[int] is absolutely not assignable',
          ),
        );
      },
    );

    test('from nil to a map other than map[string]any', () async {
      final wf = Workflow<Map<String, Object?>, Map<String, _Stringer?>>();
      wf.end().addInput(Graph.start, [FieldMapping.mapFields('a', 'a')]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, {'a': null}), {'a': null});
    });
  });

  group('TestStreamFieldMap', () {
    test('multiple incomplete chunks in source stream', () async {
      final wf = Workflow<Map<String, Object?>, Map<String, Object?>>();
      wf.end().addInput(Graph.start, [
        FieldMapping.mapFields('a', 'a'),
        FieldMapping.mapFields('b', 'b'),
      ]);
      final r = await wf.compile(ctx);

      final sr = await _pipeOf<Map<String, Object?>>(2, [
        {'a': 1},
        {'b': 2},
      ]);
      final outputS = await r.transform(ctx, sr);
      expect(await concatStreamReader(outputS), {'a': 1, 'b': 2});
    });
  });

  test('TestRuntimeTypeCheck', () async {
    final g = Workflow<Map<String, Object?>, Object?>();

    g
        .addLambdaNode('A', Lambda.invokable((ctx, String input) => input))
        .addInput(Graph.start, [FieldMapping.fromField('A')]);

    g
        .addLambdaNode('B', Lambda.invokable((ctx, String input) => input))
        .addInput(Graph.start, [FieldMapping.fromField('B')]);

    g.addLambdaNode(
      'MergeA',
      Lambda.invokable((ctx, Map<String, Object?> input) => input),
    )
      ..addInput('A', [FieldMapping.toField('a')])
      ..addInput('B', [FieldMapping.toField('b')]);

    g.end().addInput('MergeA');

    final r = await g.compile(ctx);
    final result = await r.stream(ctx, {'A': '1', 'B': '2'});
    expect(await result.recv(), {'a': '1', 'b': '2'});
    await expectLater(result.recv(), throwsA(isA<StreamEOFException>()));
  });

  group('TestIntermediateMappingSource', () {
    test('intermediate any source is nil', () async {
      final wf = Workflow<Map<String, Object?>, Object?>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['a', 'b']),
      ]);
      final r = await wf.compile(ctx);
      // Go ends the text with "for type [interface {}]", the declared type
      // of the value that is nil, which it knows by reflection.
      await expectLater(
        r.invoke(ctx, {'a': null}),
        _mappingErrorContaining(
          'intermediate source value on path=[a, b] is nil',
        ),
      );
      final outStream = await r.transform(
        ctx,
        StreamReader.fromIterable([
          {'a': null},
          {'b': 'ok'},
        ]),
      );
      await expectLater(
        outStream.recv(),
        _mappingErrorContaining(
          'intermediate source value on path=[a, b] is nil',
        ),
      );
      await outStream.close();
    });

    test('intermediate map source is nil', () async {
      // Go passes a nil map; a Dart map type that has null is nullable.
      final wf = Workflow<Map<String, Object?>?, Object?>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['a']),
      ]);
      final r = await wf.compile(ctx);
      // Go ends the text with "for map type [map[string]interface {}]", which
      // it knows by reflection.
      await expectLater(
        r.invoke(ctx, null),
        _mappingErrorContaining('intermediate source value on path=[a] is nil'),
      );
      final outStream = await r.stream(ctx, null);
      await expectLater(
        outStream.recv(),
        _mappingErrorContaining('intermediate source value on path=[a] is nil'),
      );
      await outStream.close();
    });

    // Go: "intermediate map ptr source is nil" (`*map[string]any`) has no
    // Dart equivalent: there is no pointer to a map next to the nullable map
    // of the case above.

    test('intermediate struct ptr source is nil', () async {
      final wf = Workflow<Map<String, _Inner?>, String>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['I', 'A']),
      ]);
      final r = await wf.compile(ctx);
      await expectLater(
        r.invoke(ctx, {'I': null}),
        _mappingErrorContaining(
          'intermediate source value on path=[I, A] is nil',
        ),
      );
      final outStream = await r.stream(ctx, {'I': null});
      await expectLater(
        outStream.recv(),
        _mappingErrorContaining(
          'intermediate source value on path=[I, A] is nil',
        ),
      );
      await outStream.close();
    });

    test('intermediate interface source is nil', () async {
      final wf = Workflow<Map<String, _Stringer?>, String>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['a', 'b']),
      ]);
      final r = await wf.compile(ctx);
      // Go ends the text with "for type [fmt.Stringer]", which it knows by
      // reflection.
      await expectLater(
        r.invoke(ctx, {'a': null}),
        _mappingErrorContaining(
          'intermediate source value on path=[a, b] is nil',
        ),
      );
      final outStream = await r.stream(ctx, {'a': null});
      await expectLater(
        outStream.recv(),
        _mappingErrorContaining(
          'intermediate source value on path=[a, b] is nil',
        ),
      );
      await outStream.close();
    });

    test('intermediate interface source valid', () async {
      final wf = Workflow<Map<String, _Stringer>, String>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['a', 'A']),
      ]);
      final r = await wf.compile(ctx);
      const input = <String, _Stringer>{'a': _GoodStruct2(a: 'hello')};
      expect(await r.invoke(ctx, input), 'hello');
      final outStream = await r.stream(ctx, input);
      expect(await outStream.recv(), 'hello');
      await outStream.close();
    });

    test(
        'intermediate interface source, source field not found at request '
        'time', () async {
      final wf = Workflow<Map<String, _Stringer>, String>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['a', 'B']),
      ]);
      final r = await wf.compile(ctx);
      const input = <String, _Stringer>{'a': _GoodStruct2(a: 'hello')};
      // Go: "field mapping from a struct field, but field not found.
      // field=B"; Dart has no structs, the text says "from a field".
      await expectLater(
        r.invoke(ctx, input),
        _mappingErrorContaining(
          'field mapping from a field, but field not found. field=B',
        ),
      );
      final outStream = await r.stream(ctx, input);
      await expectLater(
        outStream.recv(),
        _mappingErrorContaining(
          'field mapping from a field, but field not found. field=B',
        ),
      );
      await outStream.close();
    });

    // Go: "intermediate interface source, source field not exported at
    // request time" has no Dart equivalent: a `FieldAddressable` has no
    // unexported fields.

    test('intermediate interface source, type mismatch at request time',
        () async {
      final wf = Workflow<Map<String, _Stringer>, int>();
      wf.end().addInput(Graph.start, [
        FieldMapping.fromFieldPath(['a', 'A']),
      ]);
      final r = await wf.compile(ctx);
      const input = <String, _Stringer>{'a': _GoodStruct2(a: 'hello')};
      // Go: "field[string]-[int]". The full text is the next test.
      await expectLater(
        r.invoke(ctx, input),
        _mappingErrorContaining(
          'runtime check failed for mapping',
          'field[String]-[int] is absolutely not assignable',
        ),
      );
      final outStream = await r.stream(ctx, input);
      await expectLater(
        outStream.recv(),
        _mappingErrorContaining(
          'runtime check failed for mapping',
          'field[String]-[int] is absolutely not assignable',
        ),
      );
      await outStream.close();
    });

    test(
      'intermediate interface source, type mismatch at request time: the '
      'error names the mapping',
      () async {
        final wf = Workflow<Map<String, _Stringer>, int>();
        wf.end().addInput(Graph.start, [
          FieldMapping.fromFieldPath(['a', 'A']),
        ]);
        final r = await wf.compile(ctx);
        const input = <String, _Stringer>{'a': _GoodStruct2(a: 'hello')};
        // Go prints the path of a mapping with its separator, U+001F; the
        // Dart text joins the names with a dot.
        const text =
            'runtime check failed for mapping [from a.A(field) of start], '
            'field[String]-[int] is absolutely not assignable';
        await expectLater(r.invoke(ctx, input), _mappingErrorContaining(text));
        final outStream = await r.stream(ctx, input);
        await expectLater(outStream.recv(), _mappingErrorContaining(text));
        await outStream.close();
      },
    );
  });

  test('TestSetFanInMergeConfig_RealStreamNode_Workflow', () async {
    final wf = Workflow<int, Map<String, int>>();

    wf
        .addLambdaNode(
          's1',
          Lambda.streamable(
            (ctx, int input) => _pipeOf<int>(2, [input + 1, input + 2]),
          ),
        )
        .addInput(Graph.start);

    wf
        .addLambdaNode(
          's2',
          Lambda.streamable(
            (ctx, int input) => _pipeOf<int>(2, [input + 10, input + 20]),
          ),
        )
        .addInput(Graph.start);

    wf.end()
      ..addInput('s1', [FieldMapping.toField('s1')])
      ..addInput('s2', [FieldMapping.toField('s2')]);

    final r = await wf.compile(
      ctx,
      options: const GraphCompileOptions(
        fanInMergeConfig: {
          Graph.end: FanInMergeConfig(streamMergeWithSourceEof: true),
        },
      ),
    );

    final sr = await r.stream(ctx, 1);

    final merged = <String, Set<int>>{};
    var sourceEofCount = 0;
    final sourceNames = <String>{};
    var ended = false;
    for (var i = 0; i < 100 && !ended; i++) {
      final Map<String, int> m;
      try {
        m = await sr.recv();
      } on SourceEOFException catch (e) {
        sourceEofCount++;
        sourceNames.add(e.sourceName);
        continue;
      } on StreamEOFException {
        ended = true;
        continue;
      }
      for (final MapEntry(:key, :value) in m.entries) {
        (merged[key] ??= {}).add(value);
      }
    }
    expect(ended, isTrue, reason: 'the stream should end');

    expect(merged, {
      's1': {2, 3},
      's2': {11, 21},
    });
    expect(
      sourceEofCount,
      2,
      reason: 'should receive SourceEOF for each input stream when '
          'StreamMergeWithSourceEOF is true',
    );
    expect(sourceNames, contains('s1'), reason: 'SourceEOF from s1');
    expect(sourceNames, contains('s2'), reason: 'SourceEOF from s2');
  });

  group('TestCustomExtractor', () {
    test('custom extract from array element', () async {
      final wf = Workflow<List<int>, Map<String, int>>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toField(
          'a',
          customExtractor: (input) => (input! as List<int>)[0],
        ),
      ]);
      final r = await wf.compile(ctx);
      expect(await r.invoke(ctx, [1, 2]), {'a': 1});
    });

    test('mix custom extract with normal mapping', () async {
      final wf = Workflow<Map<String, Object?>, Map<String, int>>();
      wf.end().addInput(Graph.start, [
        FieldMapping.toField(
          'a',
          customExtractor: (input) {
            final a = (input! as Map<String, Object?>)['a']! as List<Object?>;
            return (a[0]! as Map<String, Object?>)['c'];
          },
        ),
        FieldMapping.mapFields('b', 'b'),
      ]);
      final r = await wf.compile(ctx);
      expect(
        await r.invoke(ctx, {
          'a': <Object?>[
            <String, Object?>{'c': 1},
          ],
          'b': 2,
        }),
        {'a': 1, 'b': 2},
      );
    });
  });

  test('TestAddDependency', () async {
    final wf = Workflow<String, Object?>();

    wf
        .addLambdaNode(
          '1',
          Lambda.invokable((ctx, String input) => '${input}_$input'),
        )
        .addDependency(Graph.start);

    wf.end().addDependency('1');

    final r = await wf.compile(ctx);
    expect(await r.invoke(ctx, 'input'), isNull);
  });

  group('TestIndirectDependencyWithBranch', () {
    /// Go: the extractor of both cases.
    Object? firstOf(Object? input) {
      final inputList = input! as List<int>;
      if (inputList.isEmpty) throw Exception('input list is empty');
      return inputList[0];
    }

    /// Go: the workflow both cases build.
    Workflow<List<int>, Map<String, Object?>> build() {
      final wf = Workflow<List<int>, Map<String, Object?>>();

      wf
          .addLambdaNode('1', Lambda.invokable((ctx, int input) => input + 1))
          .addInputWithOptions(
            Graph.start,
            [FieldMapping.toField('', customExtractor: firstOf)],
            noDirectDependency: true,
          );

      wf.addBranch(
        Graph.start,
        GraphBranch.single<List<int>>(
          (ctx, input) => input.isNotEmpty ? '1' : Graph.end,
          {'1', Graph.end},
        ),
      );

      wf.end()
        ..addInput('1', [FieldMapping.toField('output')])
        ..setStaticValue(['static'], 2);
      return wf;
    }

    test('data only mapping across branch', () async {
      final r = await build().compile(ctx);

      // skip lambda node "1" (Go passes a nil slice)
      expect(await r.invoke(ctx, const []), {'static': 2});

      // choose lambda node "1"
      expect(await r.invoke(ctx, [1]), {'output': 2, 'static': 2});
    });

    test('data only mapping across branch, with interrupt after branch',
        () async {
      final r = await build().compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: InMemoryCheckpointStore(),
          interruptBeforeNodes: const ['1'],
        ),
      );

      // skip lambda node "1"
      expect(await r.invoke(ctx, const []), {'static': 2});

      // choose lambda node "1"
      Object? interrupted;
      try {
        await r.invoke(ctx, [1], options: [CallOption.checkpointId('123')]);
      } on Object catch (error) {
        interrupted = error;
      }
      expect(extractInterruptInfo(interrupted), isNotNull);

      expect(
        await r.invoke(
          ctx,
          const [],
          options: [CallOption.checkpointId('123')],
        ),
        {'output': 2, 'static': 2},
      );
    });
  });
}
