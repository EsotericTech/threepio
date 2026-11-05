// The two generations of the tool contract: `run` / `streamRun` (threepio
// before 0.9) and `invokableRun` / `streamableRun` (eino `tool.InvokableTool`
// and `tool.StreamableTool`), and the enhanced contracts next to them.
//
// Also ports eino `components/tool/option_test.go` (TestImplSpecificOpts) and
// `components/tool/callback_extra_test.go` (TestConvCallbackInput,
// TestConvCallbackOutput).
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

import '../../support/scripted_chat_model.dart';

ToolInfo _info(String name) => ToolInfo.simple(
      name: name,
      description: 'a test tool',
      properties: {'text': JSONSchemaProperty.string()},
    );

/// Written the way tools were written before `invokableRun` existed, like the
/// tools of the consumer apps.
final class _OldStyleTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => _info('old_style');

  @override
  Future<String> run(String argumentsJson) async => 'old:$argumentsJson';
}

/// Written against the Eino-shaped contract.
final class _NewStyleTool extends InvokableTool {
  final List<(RunContext, ToolOptions?)> calls = [];

  @override
  Future<ToolInfo> info() async => _info('new_style');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async {
    calls.add((ctx, options));
    return 'new:$argumentsJson';
  }
}

final class _OldStyleStreamTool extends StreamableTool {
  @override
  Future<ToolInfo> info() async => _info('old_stream');

  @override
  Future<StreamReader<String>> streamRun(String argumentsJson) async =>
      StreamReader.fromIterable(['old', ':', argumentsJson]);
}

final class _NewStyleStreamTool extends StreamableTool {
  @override
  Future<ToolInfo> info() async => _info('new_stream');

  @override
  Future<StreamReader<String>> streamableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      StreamReader.fromIterable(['new', ':', argumentsJson]);
}

final class _EmptyTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => _info('empty');
}

final class _EmptyStreamTool extends StreamableTool {
  @override
  Future<ToolInfo> info() async => _info('empty_stream');
}

/// One class that offers the plain and the enhanced form of a call.
final class _PlainAndEnhanced extends InvokableTool
    implements EnhancedInvokableTool, EnhancedStreamableTool {
  @override
  Future<ToolInfo> info() async => _info('both');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      'plain';

  @override
  Future<ToolResult> enhancedInvokableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      ToolResult.text('enhanced:${argument.text}');

  @override
  Future<StreamReader<ToolResult>> enhancedStreamableRun(
    RunContext ctx,
    ToolArgument argument, {
    ToolOptions? options,
  }) async =>
      StreamReader.fromIterable([
        ToolResult.text('enhanced:'),
        ToolResult.text(argument.text),
      ]);
}

final class _Interrupted implements InterruptSignal {
  const _Interrupted();
}

/// A tool that asks the run to pause.
final class _InterruptingTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => _info('interrupting');

  @override
  Future<String> invokableRun(
    RunContext ctx,
    String argumentsJson, {
    ToolOptions? options,
  }) async =>
      throw const _Interrupted();
}

/// A tool of the Kortney kind, which records the token it was given.
final class _ContextualProbe extends ContextualTool {
  final List<CancelToken> tokens = [];

  @override
  Future<ToolInfo> info() async => _info('contextual');

  @override
  Future<ToolOutput> runWithContext(
    ToolCallContext context,
    String argumentsJson,
  ) async {
    tokens.add(context.cancelToken);
    return argumentsJson == '"fail"'
        ? const ToolOutput.error('refused')
        : ToolOutput(content: 'contextual:$argumentsJson');
  }
}

/// `implSpecificOptions` of the Go option test.
final class _ImplSpecificOptions {
  const _ImplSpecificOptions({this.conf = '', this.index = 0});

  final String conf;
  final int index;
}

final class _OtherOptions {
  const _OtherOptions(this.flag);

  final bool flag;
}

ToolCall _call(String name, String arguments) => ToolCall(
      id: 'call-$name',
      function: FunctionCall(name: name, arguments: arguments),
    );

void main() {
  final ctx = RunContext.background();

  group('InvokableTool', () {
    test('a tool that only overrides run() works through invokableRun()',
        () async {
      final tool = _OldStyleTool();

      expect(await tool.invokableRun(ctx, '{"text":"a"}'), 'old:{"text":"a"}');
      expect(
        await tool.invokableRun(
          ctx,
          '{}',
          options: const ToolOptions(extensions: ['ignored']),
        ),
        'old:{}',
      );
      // And the way it was always called.
      expect(await tool.run('{"text":"a"}'), 'old:{"text":"a"}');
    });

    test('a tool that only overrides invokableRun() works through the '
        'ToolExecutor', () async {
      final tool = _NewStyleTool();
      final executor = ToolExecutor(registry: ToolRegistry()..register(tool));

      final result = await executor.executeToolCall(
        _call('new_style', '{"text":"a"}'),
      );

      expect(result.error, isNull);
      expect(result.output, 'new:{"text":"a"}');
      expect(result.toMessage().content, 'new:{"text":"a"}');
      // The executor has no run to belong to: the context is a fresh one.
      expect(tool.calls.single.$1.cancelToken.isCancelled, isFalse);
      expect(tool.calls.single.$2, isNull);
    });

    test('the ToolExecutor still runs a tool that only overrides run()',
        () async {
      final executor =
          ToolExecutor(registry: ToolRegistry()..register(_OldStyleTool()));

      final results = await executor.executeToolCalls([
        _call('old_style', '{"n":1}'),
        _call('old_style', '{"n":2}'),
      ]);

      expect(results.map((r) => r.output), ['old:{"n":1}', 'old:{"n":2}']);
    });

    test('a tool that overrides neither fails with UnimplementedError',
        () async {
      final tool = _EmptyTool();

      await expectLater(tool.invokableRun(ctx, '{}'), throwsUnimplementedError);
      await expectLater(tool.run('{}'), throwsUnimplementedError);
    });

    test('the error is a failed future, not a synchronous throw', () {
      // A caller that only attaches an error handler must be reached.
      final future = _EmptyTool().invokableRun(ctx, '{}');
      expect(future, throwsUnimplementedError);
    });

    test('run() of a tool that only overrides invokableRun() says what to '
        'call instead', () async {
      await expectLater(
        _NewStyleTool().run('{}'),
        throwsA(
          isA<UnimplementedError>()
              .having((e) => e.message, 'message', contains('invokableRun')),
        ),
      );
    });

    test('the ToolExecutor reports an unimplemented tool as a failed call',
        () async {
      final executor =
          ToolExecutor(registry: ToolRegistry()..register(_EmptyTool()));

      final result = await executor.executeToolCall(_call('empty', '{}'));

      expect(result.isSuccess, isFalse);
      expect(result.error, contains('Execution failed'));
    });
  });

  group('an interrupt is not a failed tool call', () {
    test('the ToolExecutor throws it on instead of returning an error result',
        () async {
      final executor = ToolExecutor(
        registry: ToolRegistry()..register(_InterruptingTool()),
      );

      await expectLater(
        executor.executeToolCall(_call('interrupting', '{}')),
        throwsA(isA<InterruptSignal>()),
      );
      await expectLater(
        executor.executeToolCalls([_call('interrupting', '{}')]),
        throwsA(isA<InterruptSignal>()),
      );
    });

    test('the Kortney runtime ends the run instead of telling the model',
        () async {
      final model = ScriptedChatModel([
        [
          toolCallDelta(0, id: 'c1', name: 'interrupting', args: '{}'),
          finish('tool_calls'),
        ],
        [text('never reached'), finish('stop')],
      ]);
      final agent = ChatModelAgent(
        ChatModelAgentConfig(name: 'k', model: model, tools: [_InterruptingTool()]),
      );

      final events = await (await agent.run([Message.user('go')])).collectAll();

      expect(model.calls, hasLength(1), reason: 'no second model call');
      expect(events.whereType<ToolResultEvent>(), isEmpty);
      final error = events.whereType<AgentErrorEvent>().single;
      expect(error.isRecoverable, isFalse);
      expect(events.last, same(error));
    });
  });

  group('ContextualTool', () {
    test('invokableRun() hands the cancel token of the context to the tool',
        () async {
      final tool = _ContextualProbe();
      final token = CancelToken();

      final result = await tool.invokableRun(
        RunContext.background(cancelToken: token),
        '{"a":1}',
      );

      expect(result, 'contextual:{"a":1}');
      expect(tool.tokens.single, same(token));
    });

    test('run() still gives it a token of its own', () async {
      final tool = _ContextualProbe();

      expect(await tool.run('{}'), 'contextual:{}');
      expect(tool.tokens.single.isCancelled, isFalse);
    });

    test('an error result is thrown by both entry points, as before',
        () async {
      final tool = _ContextualProbe();

      await expectLater(
        tool.run('"fail"'),
        throwsA(isA<ContextualToolException>()),
      );
      await expectLater(
        tool.invokableRun(ctx, '"fail"'),
        throwsA(
          isA<ContextualToolException>()
              .having((e) => e.message, 'message', 'refused'),
        ),
      );
    });

    test('still runs in the ToolExecutor', () async {
      final executor = ToolExecutor(
        registry: ToolRegistry()..register(_ContextualProbe()),
      );

      final result = await executor.executeToolCall(_call('contextual', '{}'));
      expect(result.output, 'contextual:{}');
    });
  });

  group('StreamableTool', () {
    test('a tool that only overrides streamRun() works through '
        'streamableRun()', () async {
      final reader = await _OldStyleStreamTool().streamableRun(ctx, '{}');
      expect(await reader.collectAll(), ['old', ':', '{}']);
    });

    test('a tool that only overrides streamableRun() works through the '
        'ToolExecutor', () async {
      final executor = ToolExecutor(
        registry: ToolRegistry()..register(_NewStyleStreamTool()),
      );

      final result = await executor.executeToolCall(_call('new_stream', '{}'));

      expect(result.error, isNull);
      expect(result.output, 'new:{}');
    });

    test('the ToolExecutor still runs a tool that only overrides streamRun()',
        () async {
      final executor = ToolExecutor(
        registry: ToolRegistry()..register(_OldStyleStreamTool()),
      );

      final result = await executor.executeToolCall(_call('old_stream', '{}'));

      expect(result.output, 'old:{}');
    });

    test('a tool that overrides neither fails with UnimplementedError',
        () async {
      final tool = _EmptyStreamTool();

      await expectLater(tool.streamableRun(ctx, '{}'), throwsUnimplementedError);
      await expectLater(tool.streamRun('{}'), throwsUnimplementedError);
    });
  });

  group('the Kortney runtime runs tools of both generations', () {
    Future<List<Message>> toolMessages(List<BaseTool> tools, String name) async {
      final model = ScriptedChatModel([
        [
          toolCallDelta(0, id: 'c1', name: name, args: '{"text":"hi"}'),
          finish('tool_calls'),
        ],
        [text('done'), finish('stop')],
      ]);
      final agent = ChatModelAgent(
        ChatModelAgentConfig(name: 'k', model: model, tools: tools),
      );
      final events = await (await agent.run([Message.user('go')])).collectAll();
      return [
        for (final event in events.whereType<AgentMessageEvent>())
          if (event.message.role == RoleType.tool) event.message,
      ];
    }

    test('a tool that only overrides run()', () async {
      final messages = await toolMessages([_OldStyleTool()], 'old_style');
      expect(messages.single.content, 'old:{"text":"hi"}');
    });

    test('a tool that only overrides invokableRun()', () async {
      final tool = _NewStyleTool();
      final messages = await toolMessages([tool], 'new_style');

      expect(messages.single.content, 'new:{"text":"hi"}');
      expect(tool.calls, hasLength(1));
    });

    test('a FunctionTool', () async {
      final tool = FunctionTool<Map<String, Object?>, Map<String, Object?>>(
        name: 'shout',
        description: 'upper-cases text',
        params: const ParamsOneOf.params({
          'text': ParameterInfo(type: DataType.string, required: true),
        }),
        fromJson: (json) => json,
        invoke: (ctx, input, options) =>
            {'text': (input['text']! as String).toUpperCase()},
      );

      final messages = await toolMessages([tool], 'shout');
      expect(jsonDecode(messages.single.content), {'text': 'HI'});
    });

    test('the context of the tool call is cancelled with the run', () async {
      final seen = <RunContext>[];
      final tool = FunctionTool<Map<String, Object?>, String>(
        name: 'probe',
        description: 'records its context',
        params: const ParamsOneOf.params({}),
        fromJson: (json) => json,
        invoke: (ctx, input, options) {
          seen.add(ctx);
          return 'ok';
        },
      );
      final model = ScriptedChatModel([
        [toolCallDelta(0, id: 'c1', name: 'probe', args: '{}'), finish('tool_calls')],
        [text('done'), finish('stop')],
      ]);
      final agent = ChatModelAgent(
        ChatModelAgentConfig(name: 'k', model: model, tools: [tool]),
      );
      final token = CancelToken();

      await (await agent.run(
        [Message.user('go')],
        context: AgentRunScope(cancelToken: token),
      ))
          .collectAll();

      expect(seen.single.cancelToken, same(token));
    });
  });

  group('enhanced tools', () {
    test('one class can implement the plain and the enhanced contract',
        () async {
      final tool = _PlainAndEnhanced();

      expect(tool, isA<InvokableTool>());
      expect(tool, isA<EnhancedInvokableTool>());
      expect(tool, isA<EnhancedStreamableTool>());

      expect(await tool.invokableRun(ctx, '{}'), 'plain');
      expect(
        (await tool.enhancedInvokableRun(ctx, const ToolArgument('{"a":1}')))
            .parts
            .single
            .text,
        'enhanced:{"a":1}',
      );

      final chunks = await (await tool.enhancedStreamableRun(
        ctx,
        const ToolArgument('{"a":1}'),
      ))
          .collectAll();
      expect(concatToolResults(chunks).parts.single.text, 'enhanced:{"a":1}');
    });

    test('an enhanced tool is a BaseTool the model can be told about',
        () async {
      final BaseTool tool = _PlainAndEnhanced();
      expect((await tool.info()).name, 'both');
    });
  });

  group('TestImplSpecificOpts', () {
    test('a tool reads its own options from the extensions', () {
      const options = ToolOptions(
        extensions: [_ImplSpecificOptions(conf: 'test_conf', index: 1)],
      );

      final own = options.extension<_ImplSpecificOptions>();
      expect(own?.conf, 'test_conf');
      expect(own?.index, 1);
    });

    test('an option that is not there is null, so the tool uses its default',
        () {
      const options = ToolOptions(extensions: [_OtherOptions(true)]);

      final own = options.extension<_ImplSpecificOptions>() ??
          const _ImplSpecificOptions();
      expect(own.conf, '');
      expect(own.index, 0);
      expect(const ToolOptions().extension<_ImplSpecificOptions>(), isNull);
      expect(const ToolOptions().extensions, isEmpty);
    });

    test('the options of several tools travel in one object', () {
      const options = ToolOptions(
        extensions: [_OtherOptions(true), _ImplSpecificOptions(conf: 'c')],
      );

      expect(options.extension<_OtherOptions>()?.flag, isTrue);
      expect(options.extension<_ImplSpecificOptions>()?.conf, 'c');
    });

    test('merge prefers the extensions of the options merged in', () {
      const base = ToolOptions(
        extensions: [_ImplSpecificOptions(conf: 'base'), _OtherOptions(false)],
      );
      const call = ToolOptions(extensions: [_ImplSpecificOptions(conf: 'call')]);

      final merged = base.merge(call);
      expect(merged.extension<_ImplSpecificOptions>()?.conf, 'call');
      expect(merged.extension<_OtherOptions>()?.flag, isFalse);
      expect(merged.extensions, hasLength(3));

      expect(base.merge(null), same(base));
      expect(base.merge(const ToolOptions()).extensions, same(base.extensions));
      expect(const ToolOptions().merge(call).extensions, same(call.extensions));
    });

    test('copyWith replaces the extensions', () {
      const options = ToolOptions(extensions: [_OtherOptions(true)]);

      expect(options.copyWith().extensions, same(options.extensions));
      expect(
        options
            .copyWith(extensions: const [_ImplSpecificOptions(index: 3)])
            .extension<_ImplSpecificOptions>()
            ?.index,
        3,
      );
    });
  });

  group('TestConvCallbackInput', () {
    test('accepts what a tool or a graph node reports', () {
      const input = ToolCallbackInput(argumentsJson: '{}');
      expect(ToolCallbackInput.from(input), same(input));
      expect(ToolCallbackInput.from('asd')?.argumentsJson, 'asd');
      expect(ToolCallbackInput.from(123), isNull);
      expect(ToolCallbackInput.from(null), isNull);
    });

    test('reads the text of the argument of an enhanced tool', () {
      expect(
        ToolCallbackInput.from(const ToolArgument('{"q":"x"}'))?.argumentsJson,
        '{"q":"x"}',
      );
    });

    test('carries extra', () {
      const input = ToolCallbackInput(argumentsJson: '{}', extra: {'k': 1});
      expect(input.extra, {'k': 1});
      expect(input.toString(), contains('{}'));
    });
  });

  group('TestConvCallbackOutput', () {
    test('accepts what a tool or a graph node reports', () {
      const output = ToolCallbackOutput(response: 'ok');
      expect(ToolCallbackOutput.from(output), same(output));
      expect(ToolCallbackOutput.from('asd')?.response, 'asd');
      expect(ToolCallbackOutput.from('asd')?.toolOutput, isNull);
      expect(ToolCallbackOutput.from(123), isNull);
      expect(ToolCallbackOutput.from(null), isNull);
    });

    test('keeps the result of an enhanced tool as the tool output', () {
      final result = ToolResult.text('found');
      final output = ToolCallbackOutput.from(result);

      expect(output?.toolOutput, same(result));
      expect(output?.response, isNull);
    });
  });
}
