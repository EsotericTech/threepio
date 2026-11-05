// Port of eino `components/tool/utils/invokable_func_test.go` (TestInferTool,
// TestInferOptionableTool, TestNewTool, TestSnakeToCamel, TestEnumTag) and of
// `common_test.go` (TestMarshalString, TestMarshalStringEdgeCases,
// TestMarshalStringConsistency).
//
// Go infers the schema of a tool from struct tags. Dart has no reflection:
// the tools here are given their parameters, and `fromJson` / `toJson` take
// the place of JSON struct tags.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/src/internal/naming.dart';
import 'package:threepio_core/threepio_core.dart';

final class Job {
  const Job({required this.company, this.position, this.serviceLength});

  factory Job.fromJson(Map<String, Object?> json) => Job(
        company: json['company']! as String,
        position: json['position'] as String?,
        serviceLength: (json['service_length'] as num?)?.toDouble(),
      );

  final String company;
  final String? position;
  final double? serviceLength;
}

final class User {
  const User({required this.name, this.age = 0, this.job});

  factory User.fromJson(Map<String, Object?> json) => User(
        name: json['name']! as String,
        age: json['age'] as int? ?? 0,
        job: switch (json['job']) {
          final Map<String, Object?> job => Job.fromJson(job),
          _ => null,
        },
      );

  final String name;
  final int age;
  final Job? job;
}

final class UserResult {
  const UserResult({required this.code, required this.msg});

  final int code;
  final String msg;

  Map<String, Object?> toJson() => {'code': code, 'msg': msg};
}

/// The parameters of `update_user_info`, as the struct tags of the Go test
/// describe them.
const _jobParams = {
  'company': ParameterInfo(
    type: DataType.string,
    desc: 'the company where the user works',
    required: true,
  ),
  'position': ParameterInfo(
    type: DataType.string,
    desc: "the position of the user's job",
  ),
  'service_length': ParameterInfo(
    type: DataType.number,
    desc: "the year of user's service",
  ),
};

const _userParams = ParamsOneOf.params({
  'name': ParameterInfo(
    type: DataType.string,
    desc: 'the name of the user',
    required: true,
  ),
  'age': ParameterInfo(
    type: DataType.integer,
    desc: 'the age of the user',
    required: true,
  ),
  'job': ParameterInfo(
    type: DataType.object,
    desc: 'the job of the user',
    subParams: _jobParams,
  ),
  'incomes': ParameterInfo(
    type: DataType.array,
    desc: 'the incomes of the user',
    required: true,
    elemInfo: ParameterInfo(
      type: DataType.object,
      subParams: {
        'source': ParameterInfo(
          type: DataType.string,
          desc: 'the source of income',
          required: true,
        ),
        'amount': ParameterInfo(
          type: DataType.integer,
          desc: 'the amount of income',
          required: true,
        ),
        'has_pay_tax': ParameterInfo(
          type: DataType.boolean,
          desc: 'whether the user has paid tax',
          required: true,
        ),
        'job': ParameterInfo(
          type: DataType.object,
          desc: 'the job of the user when earning this income',
          subParams: _jobParams,
        ),
      },
    ),
  ),
});

/// The schema the Go test expects for it (`toolInfo`). A schema made from
/// `ParameterInfo`s lists the required names in alphabetical order, as in
/// Eino, where they come out of a map.
const _jobSchema = {
  'company': JSONSchemaProperty(
    type: 'string',
    description: 'the company where the user works',
  ),
  'position': JSONSchemaProperty(
    type: 'string',
    description: "the position of the user's job",
  ),
  'service_length': JSONSchemaProperty(
    type: 'number',
    description: "the year of user's service",
  ),
};

const _userSchema = JSONSchema(
  required: ['age', 'incomes', 'name'],
  properties: {
    'name': JSONSchemaProperty(
      type: 'string',
      description: 'the name of the user',
    ),
    'age': JSONSchemaProperty(
      type: 'integer',
      description: 'the age of the user',
    ),
    'job': JSONSchemaProperty(
      type: 'object',
      description: 'the job of the user',
      required: ['company'],
      properties: _jobSchema,
    ),
    'incomes': JSONSchemaProperty(
      type: 'array',
      description: 'the incomes of the user',
      items: JSONSchemaProperty(
        type: 'object',
        required: ['amount', 'has_pay_tax', 'source'],
        properties: {
          'source': JSONSchemaProperty(
            type: 'string',
            description: 'the source of income',
          ),
          'amount': JSONSchemaProperty(
            type: 'integer',
            description: 'the amount of income',
          ),
          'has_pay_tax': JSONSchemaProperty(
            type: 'boolean',
            description: 'whether the user has paid tax',
          ),
          'job': JSONSchemaProperty(
            type: 'object',
            description: 'the job of the user when earning this income',
            required: ['company'],
            properties: _jobSchema,
          ),
        },
      ),
    ),
  },
);

UserResult updateUserInfo(RunContext ctx, User input, ToolOptions? options) =>
    UserResult(code: 200, msg: 'update ${input.name} success');

/// The implementation-specific option of the Go test (`UserInfoOption`).
final class UserInfoOption {
  const UserInfoOption(this.field1);

  final String field1;
}

UserResult updateUserInfoWithOption(
  RunContext ctx,
  User input,
  ToolOptions? options,
) {
  final option =
      options?.extension<UserInfoOption>() ?? const UserInfoOption('test_origin');
  return UserResult(code: 200, msg: option.field1);
}

final class _Input {
  const _Input(this.name);

  factory _Input.fromJson(Map<String, Object?> json) =>
      _Input(json['name']! as String);

  final String name;
}

final class _Output {
  const _Output(this.name);

  final String name;

  Map<String, Object?> toJson() => {'name': name};
}

final class _Named {
  const _Named(this.name);

  final String name;

  // The field name of the Go test's anonymous struct.
  Map<String, Object?> toJson() => {'Name': name};
}

final class _Interrupted implements InterruptSignal {
  const _Interrupted();
}

const _noParams = ParamsOneOf.params({});

/// A tool that returns [output] whatever it is called with.
FunctionTool<Map<String, Object?>, Object?> _returning(Object? output) =>
    FunctionTool<Map<String, Object?>, Object?>(
      name: 'echo',
      description: 'returns a fixed value',
      params: _noParams,
      fromJson: (json) => json,
      invoke: (ctx, input, options) => output,
    );

void main() {
  final ctx = RunContext.background();

  group('TestInferTool', () {
    final tool = FunctionTool<User, UserResult>(
      name: 'update_user_info',
      description: 'full update user info',
      params: _userParams,
      fromJson: User.fromJson,
      invoke: updateUserInfo,
    );

    test('invoke_infer_tool: the tool reports the schema it was given',
        () async {
      final info = await tool.info();

      expect(info.name, 'update_user_info');
      expect(info.desc, 'full update user info');
      expect(info.type, 'function');
      expect(info.paramsOneOf!.toJsonSchema(), _userSchema);
      // And as the JSON a provider is sent.
      expect(
        jsonDecode(jsonEncode(info.paramsOneOf!.toJsonSchema())),
        jsonDecode(jsonEncode(_userSchema)),
      );
    });

    test('invoke_infer_tool: arguments are decoded and the result encoded',
        () async {
      final content = await tool.invokableRun(ctx, '{"name": "bruce lee"}');

      expect(
        jsonDecode(content),
        {'code': 200, 'msg': 'update bruce lee success'},
      );
    });

    test('a schema given as JSON schema is reported unchanged', () async {
      final bySchema = FunctionTool<User, UserResult>(
        name: 'update_user_info',
        description: 'full update user info',
        params: const ParamsOneOf.jsonSchema(_userSchema),
        fromJson: User.fromJson,
        invoke: updateUserInfo,
      );

      expect((await bySchema.info()).function.parameters, _userSchema);
      expect(await bySchema.info(), await tool.info());
    });

    test('nested arguments reach the function', () async {
      final seen = <User>[];
      final recording = FunctionTool<User, UserResult>(
        name: 'update_user_info',
        description: 'full update user info',
        params: _userParams,
        fromJson: User.fromJson,
        invoke: (ctx, input, options) {
          seen.add(input);
          return const UserResult(code: 200, msg: 'ok');
        },
      );

      await recording.invokableRun(
        ctx,
        '{"name": "bruce lee", "age": 32, '
        '"job": {"company": "golden harvest", "service_length": 2.5}}',
      );

      expect(seen.single.name, 'bruce lee');
      expect(seen.single.age, 32);
      expect(seen.single.job?.company, 'golden harvest');
      expect(seen.single.job?.serviceLength, 2.5);
    });
  });

  group('TestInferOptionableTool', () {
    final tool = FunctionTool<User, UserResult>(
      name: 'invoke_infer_optionable_tool',
      description: 'full update user info',
      params: _userParams,
      fromJson: User.fromJson,
      invoke: updateUserInfoWithOption,
    );

    test('invoke_infer_optionable_tool: the function receives the options',
        () async {
      final content = await tool.invokableRun(
        ctx,
        '{"name": "bruce lee"}',
        options: const ToolOptions(extensions: [UserInfoOption('hello world')]),
      );

      expect(jsonDecode(content), {'code': 200, 'msg': 'hello world'});
    });

    test('without options the function sees null and uses its default',
        () async {
      final content = await tool.invokableRun(ctx, '{"name": "bruce lee"}');
      expect(jsonDecode(content), {'code': 200, 'msg': 'test_origin'});
    });
  });

  group('TestNewTool', () {
    final info = ToolInfo.simple(
      name: 'rename',
      description: 'renames',
      properties: {'name': JSONSchemaProperty.string()},
      required: ['name'],
    );

    test('struct_input_struct_output', () async {
      final tool = FunctionTool<_Input, _Output>.fromInfo(
        info,
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) => _Output(input.name),
      );

      expect(await tool.invokableRun(ctx, '{"name":"test"}'), '{"name":"test"}');
      expect(await tool.info(), same(info));
      expect(tool.name, 'rename');
    });

    test('pointer_input_pointer_output: a nullable output is encoded', () async {
      final tool = FunctionTool<_Input, _Output?>.fromInfo(
        info,
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) => input.name == 'none' ? null : _Output(input.name),
      );

      expect(await tool.invokableRun(ctx, '{"name":"test"}'), '{"name":"test"}');
      expect(await tool.invokableRun(ctx, '{"name":"none"}'), 'null');
    });

    test('string_input_int64_output: arguments that are not a JSON object '
        'are rejected', () async {
      var called = false;
      final tool = FunctionTool<Map<String, Object?>, int>.fromInfo(
        info,
        fromJson: (json) => json,
        invoke: (ctx, input, options) {
          called = true;
          return 10;
        },
      );

      for (final (arguments, kind) in [
        ('100', 'a number'),
        ('"100"', 'a string'),
        ('[1]', 'an array'),
        ('true', 'a boolean'),
        ('null', 'null'),
      ]) {
        await expectLater(
          tool.invokableRun(ctx, arguments),
          throwsA(
            isA<ThreepioFormatException>()
                .having((e) => e.message, 'message', contains('"rename"'))
                .having((e) => e.message, 'message', contains(kind))
                .having((e) => e.source, 'source', arguments),
          ),
          reason: arguments,
        );
      }
      expect(called, isFalse);
    });

    test('string_pointer_input_int64_pointer_output: a number is encoded as '
        'JSON', () async {
      final tool = FunctionTool<_Input, int>.fromInfo(
        info,
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) => 10,
      );

      expect(await tool.invokableRun(ctx, '{"name":"100"}'), '10');
    });

    test('the function may be asynchronous', () async {
      final tool = FunctionTool<_Input, _Output>.fromInfo(
        info,
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) async => _Output(input.name.toUpperCase()),
      );

      expect(await tool.invokableRun(ctx, '{"name":"test"}'), '{"name":"TEST"}');
    });
  });

  group('TestSnakeToCamel', () {
    test('normal_case', () {
      expect(snakeToUpperCamel('google_search_3'), 'GoogleSearch3');
    });

    test('empty_case', () {
      expect(snakeToUpperCamel(''), '');
    });

    test('single_word_case', () {
      expect(snakeToUpperCamel('google'), 'Google');
    });

    test('upper_case', () {
      expect(snakeToUpperCamel('_HTTP_HOST_'), 'HttpHost');
    });

    test('underscore_case', () {
      expect(snakeToUpperCamel('_'), '');
    });

    test('a function tool names its type after itself (GetType)', () {
      final tool = FunctionTool<User, UserResult>(
        name: 'update_user_info',
        description: 'full update user info',
        params: _userParams,
        fromJson: User.fromJson,
        invoke: updateUserInfo,
      );

      expect(tool, isA<TypedComponent>());
      expect(tool.componentTypeName, 'UpdateUserInfo');
      expect(componentTypeNameOf(tool), 'UpdateUserInfo');
    });
  });

  group('TestEnumTag', () {
    test('enum values of a parameter are part of the reported schema',
        () async {
      final tool = FunctionTool<Map<String, Object?>, String>(
        name: 'pick',
        description: 'picks',
        params: const ParamsOneOf.params({
          'field1': ParameterInfo(type: DataType.string, enumValues: ['a', 'b']),
          'field5': ParameterInfo(type: DataType.string, enumValues: ['a', 'c']),
          'field4': ParameterInfo(type: DataType.boolean),
        }),
        fromJson: (json) => json,
        invoke: (ctx, input, options) => '',
      );

      final schema = (await tool.info()).paramsOneOf!.toJsonSchema();
      expect(schema.properties['field1']?.enumValues, ['a', 'b']);
      expect(schema.properties['field5']?.enumValues, ['a', 'c']);
      expect(schema.properties['field4']?.enumValues, isNull);
    });
  });

  group('TestMarshalString', () {
    final cases = <(String, Object?, String)>[
      ('string input should return as-is', 'hello world', 'hello world'),
      ('empty string should return empty', '', ''),
      (
        'string with special characters',
        'hello\nworld\t"test"',
        'hello\nworld\t"test"',
      ),
      ('string with unicode', '你好世界', '你好世界'),
      ('integer should be marshaled to JSON', 42, '42'),
      ('float should be marshaled to JSON', 3.14, '3.14'),
      ('boolean true should be marshaled to JSON', true, 'true'),
      ('boolean false should be marshaled to JSON', false, 'false'),
      ('nil should be marshaled to JSON null', null, 'null'),
      ('slice should be marshaled to JSON array', [1, 2, 3], '[1,2,3]'),
      ('empty slice should be marshaled to JSON empty array', <int>[], '[]'),
      (
        'empty map should be marshaled to JSON empty object',
        <String, int>{},
        '{}',
      ),
      ('struct should be marshaled to JSON', const _Named('test'), '{"Name":"test"}'),
    ];

    for (final (name, output, expected) in cases) {
      test(name, () async {
        expect(await _returning(output).invokableRun(ctx, '{}'), expected);
      });
    }
  });

  group('TestMarshalStringEdgeCases', () {
    test('complex nested structure', () async {
      final result = await _returning({
        'string': 'value',
        'number': 42,
        'nested': {
          'array': ['a', 'b', 'c'],
          'bool': true,
        },
      }).invokableRun(ctx, '{}');

      expect(result, contains('"string":"value"'));
      expect(result, contains('"number":42'));
      expect(result, contains('"nested"'));
    });

    test('string type assertion priority', () async {
      final result = await _returning('direct string').invokableRun(ctx, '{}');
      expect(result, 'direct string');
      expect(result, isNot('"direct string"'));
    });
  });

  group('TestMarshalStringConsistency', () {
    test('string vs JSON marshaling difference', () async {
      const input = '{"key": "value"}';
      final result = await _returning(input).invokableRun(ctx, '{}');

      expect(result, input);
      expect(result, isNot('"$input"'));
    });
  });

  group('fromJson and toJson (WithUnmarshalArguments, WithMarshalOutput)', () {
    test('toJson turns the output into what is encoded', () async {
      final tool = FunctionTool<_Input, DateTime>(
        name: 'when',
        description: 'tells the time',
        params: _noParams,
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) => DateTime.utc(2026, 11, 5),
        toJson: (time) => {'for': 'x', 'at': time.toIso8601String()},
      );

      expect(
        await tool.invokableRun(ctx, '{"name":"x"}'),
        '{"for":"x","at":"2026-11-05T00:00:00.000Z"}',
      );
    });

    test('a string returned by toJson is the result as it is', () async {
      final tool = FunctionTool<_Input, _Output>(
        name: 'greet',
        description: 'greets',
        params: _noParams,
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) => _Output(input.name),
        toJson: (output) => 'Hello, ${output.name}!',
      );

      expect(await tool.invokableRun(ctx, '{"name":"Ada"}'), 'Hello, Ada!');
    });

    test('an empty argument string counts as an empty object', () async {
      final seen = <Map<String, Object?>>[];
      final tool = FunctionTool<Map<String, Object?>, String>(
        name: 'ping',
        description: 'pings',
        params: _noParams,
        fromJson: (json) {
          seen.add(json);
          return json;
        },
        invoke: (ctx, input, options) => 'pong',
      );

      expect(await tool.invokableRun(ctx, ''), 'pong');
      expect(await tool.invokableRun(ctx, '  \n'), 'pong');
      expect(seen, [isEmpty, isEmpty]);
    });

    test('arguments that are not JSON fail with the decoder error as cause',
        () async {
      await expectLater(
        _returning('never').invokableRun(ctx, '{"name": '),
        throwsA(
          isA<ThreepioFormatException>()
              .having((e) => e.message, 'message', contains('not valid JSON'))
              .having((e) => e.message, 'message', contains('"echo"'))
              .having((e) => e.source, 'source', '{"name": ')
              .having((e) => e.cause, 'cause', isA<FormatException>()),
        ),
      );
    });

    test('a fromJson that cannot build the input fails as bad arguments',
        () async {
      var called = false;
      final tool = FunctionTool<_Input, String>(
        name: 'strict',
        description: 'needs a name',
        params: _noParams,
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) {
          called = true;
          return 'never';
        },
      );

      // `json['name']! as String` fails on a missing and on a mistyped field.
      for (final arguments in ['{}', '{"name": 7}']) {
        await expectLater(
          tool.invokableRun(ctx, arguments),
          throwsA(
            isA<ThreepioFormatException>()
                .having(
                  (e) => e.message,
                  'message',
                  contains('could not be decoded'),
                )
                .having((e) => e.cause, 'cause', isA<TypeError>()),
          ),
          reason: arguments,
        );
      }
      expect(called, isFalse);
    });
  });

  group('what the function throws', () {
    FunctionTool<_Input, String> throwing(Object error) =>
        FunctionTool<_Input, String>(
          name: 'fails',
          description: 'always fails',
          params: _noParams,
          fromJson: _Input.fromJson,
          invoke: (ctx, input, options) => throw error,
        );

    test('is thrown by the call unchanged', () async {
      final error = StateError('boom');
      await expectLater(
        throwing(error).invokableRun(ctx, '{"name":"x"}'),
        throwsA(same(error)),
      );

      const exception = CancelledException('stop');
      await expectLater(
        throwing(exception).invokableRun(ctx, '{"name":"x"}'),
        throwsA(same(exception)),
      );
    });

    test('an interrupt passes through', () async {
      await expectLater(
        throwing(const _Interrupted()).invokableRun(ctx, '{"name":"x"}'),
        throwsA(isA<InterruptSignal>()),
      );
    });

    test('an error of an asynchronous function fails the returned future',
        () async {
      final tool = FunctionTool<_Input, String>(
        name: 'fails',
        description: 'fails later',
        params: _noParams,
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) async => throw StateError('later'),
      );

      await expectLater(
        tool.invokableRun(ctx, '{"name":"x"}'),
        throwsStateError,
      );
    });
  });

  group('context and the older entry point', () {
    test('the function receives the context of the call', () async {
      final token = CancelToken();
      final callContext = RunContext.background(cancelToken: token);
      RunContext? seen;
      final tool = FunctionTool<_Input, String>(
        name: 'ctx',
        description: 'records its context',
        params: _noParams,
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) {
          seen = ctx;
          return 'ok';
        },
      );

      await tool.invokableRun(callContext, '{"name":"x"}');
      expect(seen, same(callContext));
    });

    test('run() still works and gives the function a fresh context', () async {
      RunContext? seen;
      ToolOptions? seenOptions = const ToolOptions();
      final tool = FunctionTool<_Input, _Output>(
        name: 'legacy',
        description: 'called the old way',
        params: _noParams,
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) {
          seen = ctx;
          seenOptions = options;
          return _Output(input.name);
        },
      );

      expect(await tool.run('{"name":"test"}'), '{"name":"test"}');
      expect(seen, isNotNull);
      expect(seen!.cancelToken.isCancelled, isFalse);
      expect(seenOptions, isNull);
    });

    test('extra is kept in the tool info', () async {
      final tool = FunctionTool<_Input, String>(
        name: 'tagged',
        description: 'has extra',
        params: _noParams,
        fromJson: _Input.fromJson,
        invoke: (ctx, input, options) => '',
        extra: const {'category': 'demo'},
      );

      expect((await tool.info()).extra, {'category': 'demo'});
    });
  });

  group('EnhancedFunctionTool (NewEnhancedTool, InferEnhancedTool)', () {
    final tool = EnhancedFunctionTool<_Input>(
      name: 'enhanced_search',
      description: 'search with enhanced output',
      params: const ParamsOneOf.params({
        'name': ParameterInfo(type: DataType.string, desc: 'user name'),
      }),
      fromJson: _Input.fromJson,
      invoke: (ctx, input, options) {
        final prefix = options?.extension<UserInfoOption>()?.field1 ?? 'result';
        return ToolResult([
          ToolOutputPart.text('$prefix for: ${input.name}'),
          const ToolOutputPart(
            type: ToolPartType.image,
            image: ToolOutputImage(
              common: MessagePartCommon(url: 'https://example.com/a.png'),
            ),
          ),
        ]);
      },
    );

    test('reports its info and type', () async {
      final info = await tool.info();
      expect(info.name, 'enhanced_search');
      expect(info.desc, 'search with enhanced output');
      expect(tool.name, 'enhanced_search');
      expect(tool.componentTypeName, 'EnhancedSearch');
      expect(tool, isA<EnhancedInvokableTool>());
      expect(tool, isA<BaseTool>());
      expect(tool, isNot(isA<InvokableTool>()));
    });

    test('returns the result of the function as it is', () async {
      final result = await tool.enhancedInvokableRun(
        ctx,
        const ToolArgument('{"name":"test"}'),
      );

      expect(result.parts, hasLength(2));
      expect(result.parts[0].type, ToolPartType.text);
      expect(result.parts[0].text, 'result for: test');
      expect(result.parts[1].type, ToolPartType.image);
      expect(result.parts[1].image?.common.url, 'https://example.com/a.png');
    });

    test('passes the options of the call to the function', () async {
      final result = await tool.enhancedInvokableRun(
        ctx,
        const ToolArgument('{"name":"test"}'),
        options: const ToolOptions(extensions: [UserInfoOption('custom')]),
      );

      expect(result.parts.first.text, 'custom for: test');
    });

    test('rejects arguments it cannot decode', () async {
      await expectLater(
        tool.enhancedInvokableRun(ctx, const ToolArgument('nope')),
        throwsA(isA<ThreepioFormatException>()),
      );
      await expectLater(
        tool.enhancedInvokableRun(ctx, const ToolArgument('{"name": 1}')),
        throwsA(isA<ThreepioFormatException>()),
      );
    });

    test('fromInfo uses an existing tool info', () async {
      final info = ToolInfo.fromParams(name: 'shot', params: const {});
      final fromInfo = EnhancedFunctionTool<Map<String, Object?>>.fromInfo(
        info,
        fromJson: (json) => json,
        invoke: (ctx, input, options) async => ToolResult.text('done'),
      );

      expect(await fromInfo.info(), same(info));
      expect(
        (await fromInfo.enhancedInvokableRun(ctx, const ToolArgument('')))
            .parts
            .single
            .text,
        'done',
      );
    });
  });
}
