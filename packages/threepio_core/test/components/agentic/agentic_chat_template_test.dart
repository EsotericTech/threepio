// Port of eino `components/prompt/agentic_chat_template_test.go` (v0.9.22):
// TestFromAgenticMessages, TestDefaultAgenticTemplate_GetType,
// TestDefaultAgenticTemplate_IsCallbacksEnabled and
// TestDefaultAgenticTemplate_Format (2 subtests), and of
// `components/prompt/agentic_callback_extra_test.go` (TestConvAgenticPrompt).
//
// The groups named `… beyond Go` pin behaviour the Go tests leave out: the
// callback payloads, placeholders, the formats and the template as a graph
// node.
import 'package:test/test.dart';
import 'package:threepio_core/callbacks.dart'
    show CallbackContext, CallbackHandlerBuilder, initCallbacks;
import 'package:threepio_core/compose.dart';

/// Go `mockAgenticTemplate`.
final class _MockAgenticTemplate implements AgenticMessagesTemplate {
  _MockAgenticTemplate({this.error});

  final Error? error;
  final List<RunContext> contexts = [];

  @override
  Future<List<AgenticMessage>> format(
    RunContext ctx,
    Map<String, Object?> vars,
    FormatType type,
  ) async {
    contexts.add(ctx);
    if (error case final error?) throw error;
    return [AgenticMessage.user('mocked')];
  }
}

RunInfo _info({String type = 'Default'}) => RunInfo(
      name: '',
      type: type,
      componentType: ComponentType.agenticChatTemplate,
    );

String _textOf(AgenticMessage message) => message.contentBlocks
    .map((b) => b.userInputText?.text ?? b.assistantGenText?.text ?? '')
    .join();

void main() {
  test('TestFromAgenticMessages', () {
    final tpl = AgenticMessage.user('hello');
    const ft = FormatType.fString;
    final at = AgenticChatTemplate.fromAgenticMessages(ft, [tpl]);

    expect(at, isA<DefaultAgenticChatTemplate>());
    final template = at as DefaultAgenticChatTemplate;
    expect(template.formatType, ft);
    expect(template.templates, hasLength(1));
    expect(identical(template.templates[0], tpl), isTrue);
  });

  test('TestDefaultAgenticTemplate_GetType', () {
    const at = DefaultAgenticChatTemplate(FormatType.fString, []);
    expect(at.componentTypeName, 'Default');
    expect(componentTypeNameOf(at), 'Default');
  });

  test('TestDefaultAgenticTemplate_IsCallbacksEnabled', () {
    const at = DefaultAgenticChatTemplate(FormatType.fString, []);
    expect(at.isCallbacksEnabled, isTrue);
    expect(isCallbacksEnabled(at), isTrue);
  });

  group('TestDefaultAgenticTemplate_Format', () {
    test('success', () async {
      final types = <String>[];
      final cb = CallbackHandlerBuilder()
          .onStart((ctx, info, input) {
            types.add(info.type);
            return ctx;
          })
          .onEnd((ctx, info, output) {
            types.add(info.type);
            return ctx;
          })
          .onError((ctx, info, error, stackTrace) {
            fail('unexpected error callback');
          })
          .build();

      final tpl = AgenticMessage.user('hello {val}');
      final at = AgenticChatTemplate.fromAgenticMessages(
        FormatType.fString,
        [tpl],
      );

      final ctx = initCallbacks(RunContext.background(), _info(), [cb]);

      final res = await at.format(ctx, {'val': 'world'});
      expect(res, hasLength(1));
      expect(res[0].contentBlocks[0].userInputText!.text, 'hello world');
      expect(types, ['Default', 'Default']);
    });

    test('template format error', () async {
      final mockErr = StateError('mock error');
      final mockTpl = _MockAgenticTemplate(error: mockErr);
      final at = AgenticChatTemplate.fromAgenticMessages(
        FormatType.fString,
        [mockTpl],
      );

      final errors = <Object>[];
      final cb = CallbackHandlerBuilder().onError((ctx, info, error, st) {
        errors.add(error);
        return ctx;
      }).build();

      final ctx = initCallbacks(RunContext.background(), _info(), [cb]);

      await expectLater(
        at.format(ctx, {}),
        throwsA(same(mockErr)),
      );
      expect(errors, [same(mockErr)]);
    });
  });

  group('DefaultAgenticChatTemplate: beyond Go', () {
    test('placeholders and messages render in order', () async {
      final template = AgenticChatTemplate.fromAgenticMessages(
        FormatType.fString,
        [
          AgenticMessage.system('you are a {role}'),
          const AgenticMessagesPlaceholder('history', optional: true),
          AgenticMessage.user('question: {question}'),
        ],
      );
      final messages = await template.format(RunContext.background(), {
        'role': 'helper',
        'question': 'why?',
        'history': [AgenticMessage.user('before')],
      });
      expect(messages.map(_textOf), [
        'you are a helper',
        'before',
        'question: why?',
      ]);
      expect(messages.map((m) => m.role), [
        AgenticRoleType.system,
        AgenticRoleType.user,
        AgenticRoleType.user,
      ]);
    });

    test('jinja2 renders too; go templates are not available', () async {
      final jinja = AgenticChatTemplate.fromAgenticMessages(
        FormatType.jinja2,
        [AgenticMessage.user('hi {{name}}')],
      );
      final messages =
          await jinja.format(RunContext.background(), {'name': 'eino'});
      expect(_textOf(messages.single), 'hi eino');

      final go = AgenticChatTemplate.fromAgenticMessages(
        FormatType.goTemplate,
        [AgenticMessage.user('hi {{.name}}')],
      );
      await expectLater(
        go.format(RunContext.background(), {'name': 'eino'}),
        throwsUnsupportedError,
      );
    });

    test('a missing placeholder fails with a format exception', () async {
      final template = AgenticChatTemplate.fromAgenticMessages(
        FormatType.fString,
        [const AgenticMessagesPlaceholder('history')],
      );
      await expectLater(
        template.format(RunContext.background(), {}),
        throwsA(isA<ThreepioFormatException>()),
      );
    });

    test('the callbacks get the agentic payloads', () async {
      final payloads = <Object?>[];
      final cb = CallbackHandlerBuilder()
          .onStart((ctx, info, input) {
            payloads.add(info.componentType);
            payloads.add(input);
            return ctx;
          })
          .onEnd((ctx, info, output) {
            payloads.add(output);
            return ctx;
          })
          .build();
      final templates = <AgenticMessagesTemplate>[AgenticMessage.user('{a}')];
      final template = AgenticChatTemplate.fromAgenticMessages(
        FormatType.fString,
        templates,
      );
      await template.format(
        RunContext.background().withHandlers([cb]),
        {'a': 'x'},
      );

      expect(payloads[0], ComponentType.agenticChatTemplate);
      final input = payloads[1]! as AgenticPromptCallbackInput;
      expect(input.variables, {'a': 'x'});
      expect(input.templates, same(templates));
      final output = payloads[2]! as AgenticPromptCallbackOutput;
      expect(output.result.map(_textOf), ['x']);
      expect(output.templates, same(templates));
    });

    test('the templates are rendered under the context of the start '
        'callback', () async {
      final key = ContextKey<String>('agentic-template-test');
      final cb = CallbackHandlerBuilder()
          .onStart((ctx, info, input) => ctx.withValue(key, 'seen'))
          .build();
      final mock = _MockAgenticTemplate();
      await AgenticChatTemplate.fromAgenticMessages(FormatType.fString, [mock])
          .format(RunContext.background().withHandlers([cb]), {});
      expect(mock.contexts.single.value(key), 'seen');
    });

    test('as a graph node it reports itself, not the graph', () async {
      final events = <(String, ComponentType, String)>[];
      final cb = CallbackHandlerBuilder()
          .onStart((ctx, info, input) {
            events.add(('start', info.componentType, info.type));
            return ctx;
          })
          .onEnd((ctx, info, output) {
            events.add(('end', info.componentType, info.type));
            return ctx;
          })
          .build();
      final graph = Graph<Map<String, Object?>, List<AgenticMessage>>()
        ..addAgenticChatTemplateNode(
          'prompt',
          AgenticChatTemplate.fromAgenticMessages(
            FormatType.fString,
            [AgenticMessage.user('{q}')],
          ),
        )
        ..addEdge(Graph.start, 'prompt')
        ..addEdge('prompt', Graph.end);
      final runnable = await graph.compile(RunContext.background());
      final messages = await runnable.invoke(
        RunContext.background(),
        {'q': 'node'},
        options: [
          CallOption.callbacks([cb]),
        ],
      );
      expect(messages.map(_textOf), ['node']);
      final template = events
          .where((e) => e.$2 == ComponentType.agenticChatTemplate)
          .toList();
      // Once each: the graph leaves a callback-aware component alone.
      expect(template, [
        ('start', ComponentType.agenticChatTemplate, 'Default'),
        ('end', ComponentType.agenticChatTemplate, 'Default'),
      ]);
    });
  });

  test('TestConvAgenticPrompt', () {
    expect(
      AgenticPromptCallbackInput.from(
        AgenticPromptCallbackInput(
          variables: const {},
          templates: [AgenticMessage(role: AgenticRoleType.user)],
        ),
      ),
      isNotNull,
    );
    expect(AgenticPromptCallbackInput.from(<String, Object?>{}), isNotNull);
    expect(AgenticPromptCallbackInput.from('asd'), isNull);

    expect(
      AgenticPromptCallbackOutput.from(
        AgenticPromptCallbackOutput(
          result: [AgenticMessage(role: AgenticRoleType.user)],
          templates: [AgenticMessage(role: AgenticRoleType.user)],
        ),
      ),
      isNotNull,
    );
    expect(AgenticPromptCallbackOutput.from(<AgenticMessage>[]), isNotNull);
  });

  group('agentic prompt payload conversion: beyond Go', () {
    test('a map of variables keeps its values', () {
      final input = AgenticPromptCallbackInput.from({'a': 1});
      expect(input!.variables, {'a': 1});
      expect(input.templates, isNull);
    });

    test('a list holding only agentic messages is an output', () {
      final output = AgenticPromptCallbackOutput.from(
        <Object?>[AgenticMessage.user('x')],
      );
      expect(output!.result, hasLength(1));
      expect(AgenticPromptCallbackOutput.from(<Object?>[1]), isNull);
      expect(AgenticPromptCallbackOutput.from([Message.user('x')]), isNull);
      expect(AgenticPromptCallbackOutput.from('asd'), isNull);
    });
  });
}
