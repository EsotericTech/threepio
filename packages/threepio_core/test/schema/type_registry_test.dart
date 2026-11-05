// The type registry: a port of TestRegister of eino
// `schema/serialization_test.go` (v0.9.22), and the rule that a registration
// is matched with `is`, never by `runtimeType`.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/schema.dart';

class TestStruct1 {
  const TestStruct1({this.a, this.b, this.c, this.d, this.e, this.f});

  factory TestStruct1.fromJson(Map<String, Object?> json) => TestStruct1(
        a: TypeRegistry.decode(json['a']),
        b: TypeRegistry.decode(json['b']),
        c: TypeRegistry.decode(json['c']),
        d: TypeRegistry.decode(json['d']),
        e: TypeRegistry.decode(json['e']),
        f: TypeRegistry.decode(json['f']),
      );

  final Object? a;
  final Object? b;
  final Object? c;
  final Object? d;
  final Object? e;
  final Object? f;

  Map<String, Object?> toJson() => {
        'a': TypeRegistry.encode(a),
        'b': TypeRegistry.encode(b),
        'c': TypeRegistry.encode(c),
        'd': TypeRegistry.encode(d),
        'e': TypeRegistry.encode(e),
        'f': TypeRegistry.encode(f),
      };
}

class TestStruct2 {
  const TestStruct2([this.label = '']);

  factory TestStruct2.fromJson(Map<String, Object?> json) =>
      TestStruct2(json['label']! as String);

  final String label;

  Map<String, Object?> toJson() => {'label': label};

  @override
  bool operator ==(Object other) =>
      other is TestStruct2 && other.label == label;

  @override
  int get hashCode => label.hashCode;
}

abstract class Shape {
  const Shape();
}

class Circle extends Shape {
  const Circle(this.radius);

  final int radius;

  @override
  bool operator ==(Object other) => other is Circle && other.radius == radius;

  @override
  int get hashCode => radius;
}

/// What a checkpoint store would do with an encoded value.
Object? throughJson(Object? value) =>
    TypeRegistry.decode(jsonDecode(jsonEncode(TypeRegistry.encode(value))));

void main() {
  setUp(TypeRegistry.reset);
  tearDownAll(TypeRegistry.reset);

  // TestRegister
  test('registered types survive encoding inside untyped fields', () {
    TypeRegistry.registerName<TestStruct1>(
      'test_struct_1',
      fromJson: TestStruct1.fromJson,
      toJson: (value) => value.toJson(),
    );
    TypeRegistry.registerName<TestStruct2>(
      'test_struct_2',
      fromJson: TestStruct2.fromJson,
      toJson: (value) => value.toJson(),
    );

    final original = TestStruct1(
      a: [Message.user('hi')],
      b: <Object?>[Message.assistant('there')],
      c: const [TestStruct2('x')],
      d: const <Object?>[TestStruct2('y')],
      e: const TestStruct1(a: 'nested'),
      f: const [1],
    );

    final restored = throughJson(original)! as TestStruct1;

    expect(restored.a, [Message.user('hi')]);
    expect(restored.a, isA<List<Message>>());
    expect(restored.b, [Message.assistant('there')]);
    expect(restored.c, [const TestStruct2('x')]);
    expect(restored.d, [const TestStruct2('y')]);
    expect(restored.e, isA<TestStruct1>());
    expect((restored.e! as TestStruct1).a, 'nested');
    expect(restored.f, [1]);
  });

  group('registerName', () {
    test('rejects a name that is taken', () {
      TypeRegistry.registerName<TestStruct2>(
        'taken',
        fromJson: TestStruct2.fromJson,
        toJson: (value) => value.toJson(),
      );

      expect(
        () => TypeRegistry.registerName<Circle>(
          'taken',
          fromJson: (json) => Circle(json['radius']! as int),
          toJson: (value) => {'radius': value.radius},
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'key[taken] already registered to TestStruct2',
          ),
        ),
      );
    });

    test('rejects a type that is registered already', () {
      TypeRegistry.registerName<TestStruct2>(
        'first',
        fromJson: TestStruct2.fromJson,
        toJson: (value) => value.toJson(),
      );

      expect(
        () => TypeRegistry.registerName<TestStruct2>(
          'second',
          fromJson: TestStruct2.fromJson,
          toJson: (value) => value.toJson(),
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            'type[TestStruct2] already registered to first',
          ),
        ),
      );
    });

    test('rejects the names and types of the built-in registrations', () {
      expect(
        () => TypeRegistry.registerName<TestStruct2>(
          '_eino_message',
          fromJson: TestStruct2.fromJson,
          toJson: (value) => value.toJson(),
        ),
        throwsStateError,
      );
      expect(
        () => TypeRegistry.registerName<Message>(
          'my_message',
          fromJson: Message.fromJson,
          toJson: (value) => value.toJson(),
        ),
        throwsStateError,
      );
    });

    test('reset forgets registrations but not the built-in ones', () {
      TypeRegistry.registerName<TestStruct2>(
        'test_struct_2',
        fromJson: TestStruct2.fromJson,
        toJson: (value) => value.toJson(),
      );
      expect(TypeRegistry.isRegistered<TestStruct2>(), isTrue);

      TypeRegistry.reset();

      expect(TypeRegistry.isRegistered<TestStruct2>(), isFalse);
      expect(TypeRegistry.isRegistered<Message>(), isTrue);
    });
  });

  group('values are matched with is, not by runtimeType', () {
    test('a freezed value has a private class and is still found', () {
      final message = Message.user('hello');

      expect(message.runtimeType, isNot(Message));
      expect(TypeRegistry.nameOf(message), '_eino_message');
      expect(throughJson(message), message);
    });

    test('a typed list is found whatever its implementation', () {
      final growable = [Message.user('a')];
      final fixed = List<Message>.unmodifiable(growable);
      final generated = List<Message>.generate(1, (_) => Message.user('a'));

      for (final list in [growable, fixed, generated]) {
        expect(TypeRegistry.nameOf(list), '_eino_message_slice');
        final restored = throughJson(list);
        expect(restored, isA<List<Message>>());
        expect(restored, list);
      }
    });

    test('a list that is not typed as messages is encoded item by item', () {
      final list = <Object?>[Message.user('a'), 'text', 3];

      expect(TypeRegistry.nameOf(list), isNull);
      expect(throughJson(list), list);
    });

    test('a map is encoded entry by entry, whatever its implementation', () {
      final maps = <Map<String, Object?>>[
        {'message': Message.user('a'), 'n': 1},
        Map.unmodifiable({'message': Message.user('a'), 'n': 1}),
        <String, dynamic>{'message': Message.user('a'), 'n': 1},
      ];

      for (final map in maps) {
        expect(throughJson(map), {'message': Message.user('a'), 'n': 1});
      }
    });

    test('a registration for a supertype covers its subtypes', () {
      TypeRegistry.registerName<Shape>(
        'shape',
        fromJson: (json) => Circle(json['radius']! as int),
        toJson: (value) => {'radius': (value as Circle).radius},
      );

      expect(TypeRegistry.isRegistered<Circle>(), isTrue);
      expect(TypeRegistry.nameOf(const Circle(2)), 'shape');
      expect(throughJson(const Circle(2)), const Circle(2));
    });

    test('of several registrations that fit, the last one is used', () {
      TypeRegistry.registerName<Shape>(
        'shape',
        fromJson: (json) => throw UnimplementedError(),
        toJson: (value) => throw UnimplementedError(),
      );
      TypeRegistry.registerName<Circle>(
        'circle',
        fromJson: (json) => Circle(json['radius']! as int),
        toJson: (value) => {'radius': value.radius},
      );

      expect(TypeRegistry.nameOf(const Circle(2)), 'circle');
      expect(throughJson(const Circle(2)), const Circle(2));
    });

    test('enums are registered like any other type', () {
      expect(TypeRegistry.nameOf(RoleType.tool), '_eino_role_type');
      expect(throughJson(RoleType.tool), RoleType.tool);
      expect(
        throughJson(ChatMessagePartType.toolSearchResult),
        ChatMessagePartType.toolSearchResult,
      );
      expect(throughJson(ImageURLDetail.low), ImageURLDetail.low);
    });
  });

  group('encode and decode', () {
    test('JSON values pass through', () {
      for (final value in <Object?>[
        null,
        true,
        1,
        1.5,
        'text',
        <Object?>[1, 'a', null],
        <String, Object?>{
          'a': <Object?>[1],
          'b': <String, Object?>{'c': null},
        },
      ]) {
        expect(TypeRegistry.encode(value), value);
        expect(throughJson(value), value);
      }
    });

    test('the encoded form names the type', () {
      expect(TypeRegistry.encode(const FunctionCall(name: 'f', arguments: '{}')), {
        r'$type': '_eino_function_call',
        r'$value': {'name': 'f', 'arguments': '{}'},
      });
    });

    test('every schema type Eino registers survives', () {
      const usage = TokenUsage(
        promptTokens: 1,
        completionTokens: 2,
        totalTokens: 3,
        promptTokenDetails: PromptTokenDetails(cacheWriteTokens: 4),
      );
      const common = MessagePartCommon(fileId: 'file-1');
      final values = <Object>[
        Message.tool(content: 'ok', toolCallId: 'c1', toolName: 't'),
        [Message.user('a'), Message.assistant('b')],
        Document.simple('text').withScore(0.5),
        RoleType.assistant,
        const ToolCall(
          id: 'c1',
          function: FunctionCall(name: 'f', arguments: '{}'),
        ),
        const FunctionCall(name: 'f', arguments: '{}'),
        const ResponseMeta(finishReason: 'stop', usage: usage),
        usage,
        const LogProbs(content: [LogProb(token: 'a', logProb: -0.5)]),
        ChatMessagePartType.reasoning,
        MessageInputPart.file(fileId: 'file-1', name: 'a.pdf'),
        const MessageInputImage(common: common, detail: ImageURLDetail.auto),
        const MessageInputAudio(common: common),
        const MessageInputVideo(common: common),
        const MessageInputFile(common: common, name: 'a.pdf'),
        const MessageOutputPart(
          type: ChatMessagePartType.reasoning,
          reasoning: MessageOutputReasoning(text: 'hm', signature: 'sig'),
        ),
        common,
        ImageURLDetail.high,
        const PromptTokenDetails(cachedTokens: 1, cacheWriteTokens: 2),
      ];

      for (final value in values) {
        expect(TypeRegistry.nameOf(value), startsWith('_eino_'));
        expect(throughJson(value), value, reason: '${value.runtimeType}');
      }
    });

    test('a map with a key that looks like a type tag is not mistaken', () {
      final tricky = <String, Object?>{
        r'$type': '_eino_message',
        r'$value': 'not a message',
        'other': Message.user('a'),
      };

      expect(throughJson(tricky), tricky);
    });

    test('a value of an unregistered type cannot be encoded', () {
      expect(
        () => TypeRegistry.encode(const TestStruct2('x')),
        throwsA(
          isA<ArgumentError>().having(
            (e) => '${e.message}',
            'message',
            contains('TypeRegistry.registerName'),
          ),
        ),
      );
      expect(
        () => TypeRegistry.encode({
          'nested': [const TestStruct2('x')],
        }),
        throwsArgumentError,
      );
      expect(() => TypeRegistry.encode({1: 'int key'}), throwsArgumentError);
      expect(TypeRegistry.nameOf(const TestStruct2('x')), isNull);
    });

    test('a name that is not registered cannot be decoded', () {
      expect(
        () => TypeRegistry.decode({
          r'$type': 'gone',
          r'$value': <String, Object?>{},
        }),
        throwsA(
          isA<StateError>()
              .having((e) => e.message, 'message', contains('"gone"')),
        ),
      );
    });

    test('canEncode: registered types and what decode gives back', () {
      // JSON values come back with the type they went in with.
      expect(TypeRegistry.canEncode<String>(), isTrue);
      expect(TypeRegistry.canEncode<int>(), isTrue);
      expect(TypeRegistry.canEncode<double>(), isTrue);
      expect(TypeRegistry.canEncode<num>(), isTrue);
      expect(TypeRegistry.canEncode<bool>(), isTrue);
      expect(TypeRegistry.canEncode<Map<String, Object?>>(), isTrue);
      expect(TypeRegistry.canEncode<Map<String, dynamic>>(), isTrue);
      expect(TypeRegistry.canEncode<List<Object?>>(), isTrue);
      expect(TypeRegistry.canEncode<List<dynamic>>(), isTrue);
      expect(TypeRegistry.canEncode<Message>(), isTrue);
      expect(TypeRegistry.canEncode<List<Message>>(), isTrue);

      // These encode, but decode gives a List<Object?> / Map<String, Object?>.
      expect(TypeRegistry.canEncode<List<int>>(), isFalse);
      expect(TypeRegistry.canEncode<Map<String, String>>(), isFalse);
      expect(TypeRegistry.canEncode<TestStruct1>(), isFalse);

      expect(throughJson(<String, Object?>{'a': 1}), isA<Map<String, Object?>>());
      expect(throughJson(<int>[1]), isNot(isA<List<int>>()));
    });

    test('isRegistered answers for a declared type', () {
      expect(TypeRegistry.isRegistered<Message>(), isTrue);
      expect(TypeRegistry.isRegistered<List<Message>>(), isTrue);
      expect(TypeRegistry.isRegistered<Document>(), isTrue);
      expect(TypeRegistry.isRegistered<TestStruct1>(), isFalse);
      expect(TypeRegistry.isRegistered<List<TestStruct1>>(), isFalse);
    });
  });
}
