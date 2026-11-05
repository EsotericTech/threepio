// Field mappings and field-addressable values: the parts of a workflow that
// replace Go's reflection over struct fields.
import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/src/compose/field_mapping.dart';
import 'package:threepio_core/src/compose/type_ref.dart';

final class _Query implements FieldAddressable {
  const _Query({this.text = '', this.limit = 0, this.filter = const _Filter()});

  final String text;
  final int limit;
  final _Filter filter;

  @override
  Object? getField(String name) => switch (name) {
        'text' => text,
        'limit' => limit,
        'filter' => filter,
        _ => throw ArgumentError.value(name, 'name', 'no such field'),
      };

  @override
  _Query withField(String name, Object? value) => switch (name) {
        'text' => _Query(text: value! as String, limit: limit, filter: filter),
        'limit' => _Query(text: text, limit: value! as int, filter: filter),
        'filter' => _Query(text: text, limit: limit, filter: value! as _Filter),
        _ => throw ArgumentError.value(name, 'name', 'no such field'),
      };

  @override
  bool operator ==(Object other) =>
      other is _Query &&
      other.text == text &&
      other.limit == limit &&
      other.filter == filter;

  @override
  int get hashCode => Object.hash(text, limit, filter);

  @override
  String toString() => '_Query($text, $limit, $filter)';
}

final class _Filter implements FieldAddressable {
  const _Filter({this.language = ''});

  final String language;

  @override
  Object? getField(String name) => name == 'language'
      ? language
      : throw ArgumentError.value(name, 'name', 'no such field');

  @override
  _Filter withField(String name, Object? value) => name == 'language'
      ? _Filter(language: value! as String)
      : throw ArgumentError.value(name, 'name', 'no such field');

  @override
  bool operator ==(Object other) => other is _Filter && other.language == language;

  @override
  int get hashCode => language.hashCode;

  @override
  String toString() => '_Filter($language)';
}

/// A class whose fields are empty until a mapping reaches into them.
final class _Order implements FieldAddressable {
  const _Order({this.query, this.filters, this.plain});

  final _Query? query;
  final Map<String, _Filter>? filters;
  final _NoBlank? plain;

  @override
  Object? getField(String name) => switch (name) {
        'query' => query,
        'filters' => filters,
        'plain' => plain,
        _ => throw ArgumentError.value(name, 'name', 'no such field'),
      };

  @override
  _Order withField(String name, Object? value) => switch (name) {
        'query' => _Order(query: value as _Query?, filters: filters, plain: plain),
        'filters' => _Order(
            query: query,
            filters: value as Map<String, _Filter>?,
            plain: plain,
          ),
        'plain' => _Order(query: query, filters: filters, plain: value as _NoBlank?),
        _ => throw ArgumentError.value(name, 'name', 'no such field'),
      };
}

final class _NoBlank implements FieldAddressable {
  const _NoBlank();

  @override
  Object? getField(String name) => null;

  @override
  _NoBlank withField(String name, Object? value) => this;
}

void main() {
  setUpAll(() {
    FieldAddressable.registerBlank<_Query>(() => const _Query());
    FieldAddressable.registerBlank<_Filter>(() => const _Filter());
    FieldAddressable.registerBlank<_Order>(() => const _Order());
  });

  final ctx = RunContext.background();

  group('FieldMapping', () {
    test('the six ways to make one', () {
      final from = FieldMapping.fromField('a');
      expect(from.fromPath, ['a']);
      expect(from.toPath, isEmpty);

      final to = FieldMapping.toField('b');
      expect(to.fromPath, isEmpty);
      expect(to.toPath, ['b']);

      final both = FieldMapping.mapFields('a', 'b');
      expect(both.fromPath, ['a']);
      expect(both.toPath, ['b']);

      expect(FieldMapping.fromFieldPath(['a', 'b']).fromPath, ['a', 'b']);
      expect(FieldMapping.toFieldPath(['c', 'd']).toPath, ['c', 'd']);
      final paths = FieldMapping.mapFieldPaths(['a', 'b'], ['c', 'd']);
      expect(paths.fromPath, ['a', 'b']);
      expect(paths.toPath, ['c', 'd']);
      expect(paths.fromNodeKey, isEmpty);
      expect(paths.customExtractor, isNull);
    });

    test('a field name may contain a dot, but not the separator', () {
      expect(FieldMapping.mapFields('a.b', 'c.d').fromPath, ['a.b']);
      expect(() => FieldMapping.fromField('a\x1Fb'), throwsArgumentError);
      expect(() => FieldMapping.toFieldPath(['a', 'b\x1F']), throwsArgumentError);
    });

    test('equality: same paths, same node, no custom extractor', () {
      expect(FieldMapping.mapFields('a', 'b'), FieldMapping.mapFields('a', 'b'));
      expect(
        FieldMapping.mapFields('a', 'b').hashCode,
        FieldMapping.mapFields('a', 'b').hashCode,
      );
      expect(FieldMapping.mapFields('a', 'b'), isNot(FieldMapping.mapFields('a', 'c')));
      expect(
        FieldMapping.mapFields('a', 'b').from('n1'),
        isNot(FieldMapping.mapFields('a', 'b').from('n2')),
      );
      Object? extract(Object? input) => input;
      final custom = FieldMapping.toField('b', customExtractor: extract);
      expect(custom, isNot(FieldMapping.toField('b', customExtractor: extract)));
      expect(custom.customExtractor, same(extract));
    });

    test('toString names node and fields', () {
      expect(
        FieldMapping.mapFieldPaths(['a', 'b'], ['c']).from('node').toString(),
        '[from a.b(field) of node to c(field)]',
      );
      expect(FieldMapping.fromField('a').from('n').toString(), '[from a(field) of n]');
      expect(FieldMapping.toField('c').from('n').toString(), '[from n to c(field)]');
    });
  });

  group('applyFieldMappings', () {
    test('reads maps, field-addressable values and paths through both', () {
      final input = {
        'query': const _Query(text: 'q', filter: _Filter(language: 'en')),
        'plain': 1,
      };
      expect(
        applyFieldMappings(
          [
            FieldMapping.mapFields('plain', 'p'),
            FieldMapping.mapFieldPaths(['query', 'text'], ['t']),
            FieldMapping.mapFieldPaths(['query', 'filter', 'language'], ['l']),
            FieldMapping.toField('all'),
            FieldMapping.toField('custom', customExtractor: (input) => 42),
          ],
          input,
          allowKeyNotFound: false,
        ),
        {'p': 1, 't': 'q', 'l': 'en', 'all': input, 'custom': 42},
      );
    });

    test('a missing key is an error for a value and skipped for a chunk', () {
      final mappings = [
        FieldMapping.mapFields('a', 'x'),
        FieldMapping.mapFields('b', 'y'),
      ];
      expect(
        () => applyFieldMappings(mappings, {'a': 1}, allowKeyNotFound: false),
        throwsA(
          isA<FieldMappingException>()
              .having((e) => e.message, 'message', contains('key=b')),
        ),
      );
      expect(
        applyFieldMappings(mappings, {'a': 1}, allowKeyNotFound: true),
        {'x': 1},
      );
    });

    test('what cannot be read from says so', () {
      expect(
        () => applyFieldMappings(
          [FieldMapping.mapFieldPaths(['a', 'b'], ['x'])],
          {'a': null},
          allowKeyNotFound: false,
        ),
        throwsA(
          isA<FieldMappingException>()
              .having((e) => e.message, 'message', contains('is nil')),
        ),
      );
      expect(
        () => applyFieldMappings(
          [FieldMapping.mapFieldPaths(['a', 'b'], ['x'])],
          {'a': 7},
          allowKeyNotFound: false,
        ),
        throwsA(
          isA<FieldMappingException>().having(
            (e) => e.message,
            'message',
            contains('neither a map nor a FieldAddressable'),
          ),
        ),
      );
      expect(
        () => applyFieldMappings(
          [FieldMapping.fromField('missing')],
          const _Query(),
          allowKeyNotFound: true,
        ),
        throwsA(
          isA<FieldMappingException>()
              .having((e) => e.message, 'message', contains('field not found'))
              .having((e) => e.cause, 'cause', isArgumentError),
        ),
      );
      expect(
        const FieldMappingException('x').toString(),
        'FieldMappingException: x',
      );
    });
  });

  group('assembleFromFields', () {
    test('a map, with nested paths', () {
      expect(
        assembleFromFields<Map<String, Object?>>({
          'a': 1,
          'b\x1Fc': 2,
          'b\x1Fd\x1Fe': 3,
        }),
        {
          'a': 1,
          'b': {
            'c': 2,
            'd': {'e': 3},
          },
        },
      );
      expect(assembleFromFields<Object?>({'a': 1}), {'a': 1});
    });

    test('a narrower map type', () {
      final assembled = assembleFromFields<Map<String, String>>({'a': 'x'});
      expect(assembled, isA<Map<String, String>>());
      expect(
        () => assembleFromFields<Map<String, String>>({'a': 1}),
        throwsA(isA<FieldMappingException>()),
      );
    });

    test('a field-addressable class, from its blank', () {
      expect(
        assembleFromFields<_Query>({
          'text': 'hello',
          'filter\x1Flanguage': 'de',
        }),
        const _Query(text: 'hello', filter: _Filter(language: 'de')),
      );
      // Nothing arrived for a field: it keeps the value of the blank.
      expect(assembleFromFields<_Query>({'text': null}), const _Query());
    });

    test('a class that is not there yet is created from its blank', () {
      // Go creates the struct of a nil pointer field from the type of the
      // field; here the registered blank that the field accepts is used.
      final order = assembleFromFields<_Order>({
        'query\x1Ftext': 'find',
        'query\x1Ffilter\x1Flanguage': 'fr',
        'filters\x1Ffirst\x1Flanguage': 'en',
        'filters\x1Fsecond\x1Flanguage': 'de',
      });
      expect(order.query, const _Query(text: 'find', filter: _Filter(language: 'fr')));
      expect(order.filters, isA<Map<String, _Filter>>());
      expect(order.filters, {
        'first': const _Filter(language: 'en'),
        'second': const _Filter(language: 'de'),
      });
    });

    test('a map of classes, and a map of maps of classes', () {
      final filters = assembleFromFields<Map<String, _Filter>>({
        'a\x1Flanguage': 'en',
        'b\x1Flanguage': 'de',
      });
      expect(filters, isA<Map<String, _Filter>>());
      expect(filters['b'], const _Filter(language: 'de'));

      final nested = assembleFromFields<Map<String, Map<String, _Filter>>>({
        'x\x1Fy\x1Flanguage': 'it',
      });
      expect(nested['x']!['y'], const _Filter(language: 'it'));
      // Where a map will do, a map it is.
      expect(
        assembleFromFields<Map<String, Object?>>({'a\x1Flanguage': 'en'}),
        {
          'a': {'language': 'en'},
        },
      );
    });

    test('a field that takes neither a map nor a registered class says so',
        () {
      expect(
        () => assembleFromFields<_Order>(
          {'plain\x1Fanything': 1},
          mappings: [
            FieldMapping.toFieldPath(['plain', 'anything']).from('source'),
          ],
        ),
        throwsA(
          isA<FieldMappingException>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('[from source to plain.anything(field)]'),
              contains('field[plain] of _Order is empty'),
              contains('FieldAddressable.registerBlank'),
            ),
          ),
        ),
      );
      // The class is found, but it has no such field.
      expect(
        () => assembleFromFields<_Order>({'query\x1Fnope': 1}),
        throwsA(
          isA<FieldMappingException>()
              .having((e) => e.message, 'message', contains('field[nope] of _Query')),
        ),
      );
    });

    test('the error of the whole input names the mapping', () {
      expect(
        () => assembleFromFields<int>(
          {'': 'text'},
          mappings: [FieldMapping.fromField('a').from('start')],
        ),
        throwsA(
          isA<FieldMappingException>().having(
            (e) => e.message,
            'message',
            'runtime check failed for mapping [from a(field) of start], '
                'field[String]-[int] is absolutely not assignable',
          ),
        ),
      );
    });

    test('the whole input', () {
      expect(assembleFromFields<String>({'': 'all'}), 'all');
      expect(
        assembleFromFields<List<String>>({
          '': <Object?>['a'],
        }),
        isA<List<String>>(),
      );
      expect(
        () => assembleFromFields<String>({'': 1}),
        throwsA(
          isA<FieldMappingException>().having(
            (e) => e.message,
            'message',
            contains('is absolutely not assignable'),
          ),
        ),
      );
    });

    test('nothing arrived: the empty value of the input type', () {
      expect(assembleFromFields<Map<String, Object?>>({}), isEmpty);
      expect(assembleFromFields<_Query>({}), const _Query());
      // An input that is taken whole from one field.
      expect(assembleFromFields<String>({}), '');
      expect(assembleFromFields<int>({}), 0);
      expect(assembleFromFields<List<String>>({}), isEmpty);
      expect(assembleFromFields<String?>({}), isNull);
      // No empty value: there is nothing to pass.
      expect(
        () => assembleFromFields<DateTime>({}),
        throwsA(isA<NoValueException>()),
      );
      final converter = fieldMappingConverter(const TypeRef<DateTime>());
      expect(
        () => converter.invoke(<String, Object?>{}),
        throwsA(
          isA<FieldMappingException>()
              .having((e) => e.message, 'message', contains('no empty value')),
        ),
      );
      expect(
        () => converter.invoke('not a map'),
        throwsA(isA<ComposeTypeException>()),
      );
    });

    test('a stream: chunks that bring nothing for a whole input are left out',
        () async {
      final moment = DateTime.utc(2026);
      final converter = fieldMappingConverter(const TypeRef<DateTime>());
      final converted = converter.transform(
        StreamReader<Object?>.fromIterable([
          <String, Object?>{},
          <String, Object?>{'': moment},
          <String, Object?>{},
        ]),
      );
      expect(converted, isA<StreamReader<DateTime>>());
      expect(await converted.collectAll(), [moment]);
    });

    test('a value of the wrong type, or an unknown field, is an error', () {
      expect(
        () => assembleFromFields<_Query>({'limit': 'ten'}),
        throwsA(
          isA<FieldMappingException>()
              .having((e) => e.message, 'message', contains('field[limit]')),
        ),
      );
      expect(
        () => assembleFromFields<_Query>({'nope': 1}),
        throwsA(isA<FieldMappingException>()),
      );
      expect(
        () => assembleFromFields<Map<String, Object?>>({'a': 1, 'a\x1Fb': 2}),
        throwsA(isA<FieldMappingException>()),
      );
    });

    test('Message and Document have blanks of their own', () {
      expect(
        assembleFromFields<Message>({'content': 'hi'}),
        const Message(role: RoleType.user, content: 'hi'),
      );
      expect(
        assembleFromFields<Message>({'role': RoleType.system, 'content': 's'}),
        Message.system('s'),
      );
      expect(
        assembleFromFields<Document>({'content': 'text', 'id': 'd1'}),
        const Document(id: 'd1', content: 'text'),
      );
      expect(blankOf<String>(), isNull);
      expect(blankOf<_NoBlank>(), isNull);
      expect(blankOf<_Query>(), const _Query());
      expect(blankOf<_Query?>(), const _Query());
    });
  });

  group('validateFieldMappings', () {
    const map = TypeRef<Map<String, Object?>>();

    test('from all to all is refused', () {
      // Unreachable through a workflow, which makes a plain edge of it.
      expect(
        () => validateFieldMappings(map, map, [
          FieldMapping.toField('a'),
          FieldMapping.fromField('b'),
        ]),
        throwsA(
          isA<GraphBuildException>()
              .having((e) => e.message, 'message', contains('from all fields to all')),
        ),
      );
    });

    test('the successor has to be able to hold fields', () {
      expect(
        () => validateFieldMappings(map, const TypeRef<String>(), [
          FieldMapping.toField('a'),
        ]),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            contains('successor input type should be struct or map, actual: String'),
          ),
        ),
      );
      for (final type in <TypeRef<Object?>>[
        map,
        const TypeRef<Map<String, dynamic>>(),
        const TypeRef<Object?>(),
        const TypeRef<Object>(),
        const TypeRef<_Query>(),
        const TypeRef<Message>(),
      ]) {
        validateFieldMappings(map, type, [FieldMapping.toField('a')]);
      }
      // To the whole input: any type.
      validateFieldMappings(map, const TypeRef<String>(), [
        FieldMapping.fromField('a'),
      ]);
    });

    test('a field-addressable successor needs a blank', () {
      expect(
        () => validateFieldMappings(map, const TypeRef<_NoBlank>(), [
          FieldMapping.toField('a'),
        ]),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            contains('FieldAddressable.registerBlank'),
          ),
        ),
      );
    });

    test('a map that fields are read from or written to has string keys',
        () {
      const intKeys = TypeRef<Map<int, Object?>>();
      expect(
        () => validateFieldMappings(map, intKeys, [FieldMapping.toField('1')]),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            contains('type[Map<int, Object?>] is not a map with string'),
          ),
        ),
      );
      expect(
        () => validateFieldMappings(intKeys, map, [FieldMapping.mapFields('1', 'a')]),
        throwsA(isA<GraphBuildException>()),
      );
      // Taken or given whole, the keys do not matter.
      validateFieldMappings(intKeys, map, [FieldMapping.toField('a')]);
      validateFieldMappings(map, intKeys, [FieldMapping.fromField('a')]);
    });

    test('the predecessor has to be able to hold fields', () {
      expect(
        () => validateFieldMappings(const TypeRef<String>(), map, [
          FieldMapping.mapFields('a', 'b'),
        ]),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            contains('predecessor output type should be struct or map, actual: String'),
          ),
        ),
      );
      // The whole output, or a custom extractor: any type.
      validateFieldMappings(const TypeRef<String>(), map, [
        FieldMapping.toField('b'),
      ]);
      validateFieldMappings(const TypeRef<String>(), map, [
        FieldMapping.toField('b', customExtractor: (input) => input),
      ]);
      validateFieldMappings(const TypeRef<_NoBlank>(), map, [
        FieldMapping.mapFields('a', 'b'),
      ]);
    });
  });

  group('MappedFieldPaths', () {
    test('the whole input can be mapped once, and then nothing else', () {
      final paths = MappedFieldPaths('n')..add([]);
      expect(
        () => paths.add([
          ['a'],
        ]),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            'entire output has already been mapped for node: n',
          ),
        ),
      );
      expect(() => paths.add([]), throwsA(isA<GraphBuildException>()));
    });

    test('a field that is mapped as a whole cannot be mapped again or into',
        () {
      final paths = MappedFieldPaths('n')
        ..add([
          ['a'],
          ['b', 'c'],
        ]);
      expect(
        () => paths.add([
          ['a'],
        ]),
        throwsA(
          isA<GraphBuildException>().having(
            (e) => e.message,
            'message',
            'two terminal field paths conflict for node n: [a], [a]',
          ),
        ),
      );
      expect(
        () => MappedFieldPaths('n')
          ..add([
            ['a'],
          ])
          ..add([
            ['a', 'b'],
          ]),
        throwsA(isA<GraphBuildException>()),
      );
    });
  });

  group('Message and Document as field-addressable values', () {
    test('Message: every field can be read and replaced', () {
      final message = Message.assistant(
        'text',
        toolCalls: const [
          ToolCall(id: 'c', function: FunctionCall(name: 'f', arguments: '{}')),
        ],
      ).copyWith(name: 'bot', reasoningContent: 'why', extra: {'k': 1});
      expect(message, isA<FieldAddressable>());
      expect(message.getField('role'), RoleType.assistant);
      expect(message.getField('content'), 'text');
      expect(message.getField('name'), 'bot');
      expect(message.getField('toolCalls'), message.toolCalls);
      expect(message.getField('reasoningContent'), 'why');
      expect(message.getField('extra'), {'k': 1});
      expect(message.getField('toolCallId'), isNull);
      expect(message.getField('toolName'), isNull);
      expect(message.getField('responseMeta'), isNull);
      expect(message.getField('userInputMultiContent'), isNull);
      expect(message.getField('assistantGenMultiContent'), isNull);
      expect(() => message.getField('nope'), throwsArgumentError);

      expect(message.withField('content', 'new').content, 'new');
      expect(message.withField('role', RoleType.user).role, RoleType.user);
      expect(message.withField('name', null).name, isNull);
      expect(message.withField('toolCallId', 'id').toolCallId, 'id');
      expect(message.withField('toolName', 'tool').toolName, 'tool');
      expect(message.withField('reasoningContent', 'r').reasoningContent, 'r');
      expect(message.withField('extra', <String, Object?>{'a': 1}).extra, {'a': 1});
      expect(
        message.withField('responseMeta', const ResponseMeta(finishReason: 'stop')).responseMeta,
        const ResponseMeta(finishReason: 'stop'),
      );
      // A list that came back from JSON is accepted.
      expect(
        message.withField('toolCalls', <Object?>[message.toolCalls!.single]).toolCalls,
        message.toolCalls,
      );
      expect(
        message
            .withField('userInputMultiContent', <Object?>[
              const MessageInputPart(type: ChatMessagePartType.text, text: 't'),
            ])
            .userInputMultiContent,
        hasLength(1),
      );
      expect(
        message
            .withField('assistantGenMultiContent', <Object?>[
              const MessageOutputPart(type: ChatMessagePartType.text, text: 't'),
            ])
            .assistantGenMultiContent,
        hasLength(1),
      );
      expect(() => message.withField('nope', 1), throwsArgumentError);
      expect(() => message.withField('content', 1), throwsA(isA<TypeError>()));
    });

    test('Document: every field can be read and replaced', () {
      const document = Document(id: 'd', content: 'c', metadata: {'k': 'v'}, score: 0.5);
      expect(document, isA<FieldAddressable>());
      expect(document.getField('id'), 'd');
      expect(document.getField('content'), 'c');
      expect(document.getField('metadata'), {'k': 'v'});
      expect(document.getField('score'), 0.5);
      expect(document.getField('source'), isNull);
      expect(document.getField('embedding'), isNull);
      expect(() => document.getField('nope'), throwsArgumentError);

      expect(document.withField('id', 'x').id, 'x');
      expect(document.withField('content', 'y').content, 'y');
      expect(document.withField('metadata', <String, Object?>{'a': 1}).metadata, {'a': 1});
      expect(document.withField('score', 1).score, 1.0);
      expect(document.withField('embedding', <Object?>[1, 2.5]).embedding, [1.0, 2.5]);
      expect(
        document.withField('source', const DocumentSource(uri: 'u')).source,
        const DocumentSource(uri: 'u'),
      );
      expect(() => document.withField('nope', 1), throwsArgumentError);
    });

    test('a workflow maps fields of messages and into a message', () async {
      final workflow = Workflow<Message, Message>();
      workflow
          .addLambdaNode(
            'shout',
            Lambda.invokable((ctx, String text) => text.toUpperCase()),
          )
          .addInput(Graph.start, [FieldMapping.fromField('content')]);
      workflow.end()
        ..addInput('shout', [FieldMapping.toField('content')])
        ..addInputWithOptions(
          Graph.start,
          [FieldMapping.mapFields('name', 'name')],
          noDirectDependency: true,
        )
        ..setStaticValue(['role'], RoleType.assistant);
      final runnable = await workflow.compile(ctx);
      expect(
        await runnable.invoke(
          ctx,
          const Message(role: RoleType.user, content: 'hello', name: 'ann'),
        ),
        const Message(role: RoleType.assistant, content: 'HELLO', name: 'ann'),
      );
    });
  });

  group('GraphInfo of a workflow', () {
    test('lists the mappings of a node', () async {
      final workflow = Workflow<Map<String, Object?>, Map<String, Object?>>();
      workflow
          .addLambdaNode(
            'n',
            Lambda.invokable((ctx, Map<String, Object?> input) => input),
          )
          .addInput(Graph.start, [FieldMapping.mapFields('a', 'b')]);
      workflow.end().addInput('n');
      GraphInfo? compiled;
      await workflow.compile(
        ctx,
        options: GraphCompileOptions(
          compileCallbacks: [_Capture((info) => compiled = info)],
        ),
      );
      expect(compiled!.component, ComponentType.workflow);
      expect(compiled!.nodes['n']!.mappings, [
        FieldMapping.mapFields('a', 'b').from(Graph.start),
      ]);
      expect(workflow.info.nodes['n']!.mappings, hasLength(1));
      expect(workflow.toMermaid(), contains('graph TD'));
    });
  });
}

final class _Capture implements GraphCompileCallback {
  const _Capture(this._onFinish);

  final void Function(GraphInfo info) _onFinish;

  @override
  void onFinish(RunContext ctx, GraphInfo info) => _onFinish(info);
}
