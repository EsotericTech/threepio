// Port of eino `components/prompt/chat_template_test.go` (TestFormat,
// TestDocumentFormat, TestMultiContentFormat), `option_test.go`
// (TestImplSpecificOption) and `callback_extra_test.go` (TestConvPrompt).
import 'package:test/test.dart';
import 'package:threepio_core/src/components/prompt/chat_prompt_template.dart';
import 'package:threepio_core/threepio_core.dart';

/// `implOption` of the Go option test.
final class _ImplOption {
  const _ImplOption({this.userId = 0, this.name = ''});

  final int userId;
  final String name;
}

/// A template that records the context it is rendered under.
final class _RecordingTemplate implements MessagesTemplate {
  final List<RunContext> contexts = [];
  final List<FormatType> types = [];

  @override
  Future<List<Message>> format(
    RunContext ctx,
    Map<String, Object?> vars,
    FormatType type,
  ) async {
    contexts.add(ctx);
    types.add(type);
    return [Message.user('recorded')];
  }
}

/// A chat template written before `ChatTemplate` had a constructor.
class _HandWritten extends ChatTemplate {
  @override
  Future<List<Message>> format(
    Map<String, dynamic> variables, {
    ChatTemplateOptions? options,
  }) async =>
      [Message.user('Hello ${variables['name']}')];
}

void main() {
  group('TestFormat', () {
    final testValues = <String, Object?>{
      'context': "it's beautiful day",
      'question': 'how is the day today',
      'chat_history': [
        Message.user('who are you'),
        Message.assistant("I'm a helpful assistant"),
      ],
    };
    final expected = [
      Message.system(
        'you are a helpful assistant.\n'
        "here is the context: it's beautiful day",
      ),
      Message.user('who are you'),
      Message.assistant("I'm a helpful assistant"),
      Message.user('question: how is the day today'),
    ];

    test('f-string', () async {
      final chatTemplate = ChatTemplate.fromMessages(FormatType.fString, [
        Message.system(
          'you are a helpful assistant.\n'
          'here is the context: {context}',
        ),
        const MessagesPlaceholder('chat_history', optional: true),
        Message.user('question: {question}'),
      ]);

      expect(await chatTemplate.format(testValues), expected);
    });

    test('jinja2', () async {
      final chatTemplate = ChatTemplate.fromMessages(FormatType.jinja2, [
        Message.system(
          'you are a helpful assistant.\n'
          'here is the context: {{context}}',
        ),
        const MessagesPlaceholder('chat_history', optional: true),
        Message.user('question: {{question}}'),
      ]);

      expect(await chatTemplate.format(testValues), expected);
    });

    test('go templates are not available in Dart', () async {
      final chatTemplate = ChatTemplate.fromMessages(FormatType.goTemplate, [
        Message.system(
          'you are a helpful assistant.\n'
          'here is the context: {{.context}}',
        ),
        const MessagesPlaceholder('chat_history', optional: true),
        Message.user('question: {{.question}}'),
      ]);

      await expectLater(chatTemplate.format(testValues), throwsUnsupportedError);
    });

    test('an optional placeholder without a value renders to nothing',
        () async {
      final chatTemplate = ChatTemplate.fromMessages(FormatType.fString, [
        Message.system('context: {context}'),
        const MessagesPlaceholder('chat_history', optional: true),
        Message.user('question: {question}'),
      ]);

      expect(
        await chatTemplate.format({'context': 'c', 'question': 'q'}),
        [Message.system('context: c'), Message.user('question: q')],
      );
    });

    test('a missing variable fails the whole template', () async {
      final chatTemplate = ChatTemplate.fromMessages(FormatType.fString, [
        Message.system('context: {context}'),
        const MessagesPlaceholder('chat_history'),
        Message.user('question: {question}'),
      ]);

      await expectLater(
        chatTemplate.format({'context': 'c', 'question': 'q'}),
        throwsA(
          isA<ThreepioFormatException>().having(
            (e) => e.message,
            'message',
            contains('chat_history not found'),
          ),
        ),
      );
      await expectLater(
        chatTemplate.format({'chat_history': <Message>[], 'question': 'q'}),
        throwsFormatException,
      );
    });
  });

  group('TestDocumentFormat', () {
    test('documents can be used as values', () async {
      const docs = [
        Document(id: '1', content: 'qwe', metadata: {'hello': 888}),
        Document(id: '2', content: 'asd', metadata: {'bye': 111}),
      ];
      final template = ChatTemplate.fromMessages(FormatType.fString, [
        Message.system('all:{all_docs}\nsingle:{single_doc}'),
      ]);

      final messages = await template.format({
        'all_docs': docs,
        'single_doc': docs[0],
      });

      expect(messages, hasLength(1));
      expect(messages.single.role, RoleType.system);
      expect(messages.single.content, startsWith('all:['));
      expect(messages.single.content, contains('qwe'));
      expect(messages.single.content, contains('asd'));
      expect(messages.single.content, contains('\nsingle:'));
    });
  });

  group('TestMultiContentFormat', () {
    // The Go test fills the deprecated `MultiContent` field, which is not
    // ported; its successor is `userInputMultiContent`.
    test('text and media sources of the parts are rendered', () async {
      final template = ChatTemplate.fromMessages(FormatType.fString, [
        Message(
          role: RoleType.user,
          content: '{a}',
          userInputMultiContent: [
            MessageInputPart.text('{b}'),
            MessageInputPart.imageUrl('{c}'),
            MessageInputPart.audio(url: '{d}'),
            MessageInputPart.video(url: '{e}'),
            MessageInputPart.file(url: '{f}'),
          ],
        ),
      ]);

      final result = await template.format({
        'a': 'content',
        'b': 'text',
        'c': 'image url',
        'd': 'audio url',
        'e': 'video url',
        'f': 'file url',
      });

      expect(result, [
        Message(
          role: RoleType.user,
          content: 'content',
          userInputMultiContent: [
            MessageInputPart.text('text'),
            MessageInputPart.imageUrl('image url'),
            MessageInputPart.audio(url: 'audio url'),
            MessageInputPart.video(url: 'video url'),
            MessageInputPart.file(url: 'file url'),
          ],
        ),
      ]);
    });
  });

  group('DefaultChatTemplate', () {
    test('is what ChatTemplate.fromMessages creates', () {
      final template =
          ChatTemplate.fromMessages(FormatType.jinja2, [Message.user('{{q}}')]);

      expect(template, isA<DefaultChatTemplate>());
      final byDefault = template as DefaultChatTemplate;
      expect(byDefault.formatType, FormatType.jinja2);
      expect(byDefault.templates, [Message.user('{{q}}')]);
    });

    test('can be a constant', () {
      const template = ChatTemplate.fromMessages(FormatType.fString, [
        Message(role: RoleType.system, content: 'You are a {role}.'),
        MessagesPlaceholder('history', optional: true),
      ]);
      const direct = DefaultChatTemplate(FormatType.fString, []);

      expect(template, isA<DefaultChatTemplate>());
      expect(direct.templates, isEmpty);
    });

    test('names its type (GetType)', () {
      const template = DefaultChatTemplate(FormatType.fString, []);

      expect(template, isA<TypedComponent>());
      expect(template.componentTypeName, 'Default');
      expect(componentTypeNameOf(template), 'Default');
      expect(template, isA<CallbackAwareComponent>());
    });

    test('no templates render to no messages', () async {
      const template = DefaultChatTemplate(FormatType.fString, []);
      expect(await template.format(const {}), isEmpty);
    });

    test('renders the templates in order and stops at the first failure',
        () async {
      final recording = _RecordingTemplate();
      final template = ChatTemplate.fromMessages(FormatType.fString, [
        Message.user('first'),
        Message.user('{missing}'),
        recording,
      ]);

      await expectLater(template.format(const {}), throwsFormatException);
      expect(recording.contexts, isEmpty);
    });

    test('renders under the run context of the options', () async {
      final recording = _RecordingTemplate();
      final template =
          ChatTemplate.fromMessages(FormatType.jinja2, [recording]);
      final ctx = RunContext.background();

      await template.format(
        const {},
        options: ChatTemplateOptions(runContext: ctx),
      );
      await template.format(const {});

      expect(recording.contexts.first, same(ctx));
      expect(recording.contexts.last, isNot(same(ctx)));
      expect(recording.types, [FormatType.jinja2, FormatType.jinja2]);
    });

    test('the same template can be rendered again with other values',
        () async {
      final template = ChatTemplate.fromMessages(FormatType.fString, [
        Message.user('Hello {name}'),
      ]);

      expect(await template.format({'name': 'Ada'}), [Message.user('Hello Ada')]);
      expect(await template.format({'name': 'Bob'}), [Message.user('Hello Bob')]);
    });
  });

  group('ChatTemplate', () {
    test('can still be extended by a class with no constructor of its own',
        () async {
      final ChatTemplate template = _HandWritten();
      expect(await template.format({'name': 'Ada'}), [Message.user('Hello Ada')]);
    });

    test('the templates threepio already had are unaffected', () async {
      // It implements ChatTemplate instead of extending it.
      final ChatTemplate template = ChatPromptTemplate.fromMessages([
        MessageTemplate.system('You are a {role}.'),
        MessageTemplate.user('{question}'),
      ]);
      expect(
        await template.format({'role': 'poet', 'question': 'Why?'}),
        [Message.system('You are a poet.'), Message.user('Why?')],
      );
    });
  });

  group('TestImplSpecificOption', () {
    test('a template reads its own options from the extensions', () {
      const options = ChatTemplateOptions(
        extensions: [_ImplOption(userId: 101, name: 'Wang')],
      );

      final own = options.extension<_ImplOption>();
      expect(own?.userId, 101);
      expect(own?.name, 'Wang');
    });

    test('an option that is not there is null', () {
      const options = ChatTemplateOptions();
      expect(options.extension<_ImplOption>(), isNull);
      expect(options.extensions, isEmpty);
      expect(options.runContext, isNull);
      expect(options.extra, isNull);
    });

    test('copyWith and merge keep what is not replaced', () {
      final ctx = RunContext.background();
      final options = const ChatTemplateOptions(extra: {'k': 1})
          .copyWith(runContext: ctx, extensions: const [_ImplOption(userId: 1)]);

      expect(options.extra, {'k': 1});
      expect(options.runContext, same(ctx));
      expect(options.extension<_ImplOption>()?.userId, 1);

      final merged = options.merge(
        const ChatTemplateOptions(extensions: [_ImplOption(userId: 2)]),
      );
      expect(merged.extension<_ImplOption>()?.userId, 2);
      expect(merged.extensions, hasLength(2));
      expect(merged.runContext, same(ctx));
      expect(merged.extra, {'k': 1});
      expect(options.merge(null), same(options));
    });
  });

  group('TestConvPrompt', () {
    test('PromptCallbackInput.from', () {
      final input = PromptCallbackInput(
        variables: const {},
        templates: [Message.user('')],
      );
      expect(PromptCallbackInput.from(input), same(input));
      expect(PromptCallbackInput.from(<String, Object?>{}), isNotNull);
      expect(PromptCallbackInput.from('asd'), isNull);
      expect(PromptCallbackInput.from(null), isNull);
    });

    test('PromptCallbackOutput.from', () {
      final output = PromptCallbackOutput(
        result: [Message.user('')],
        templates: [Message.user('')],
      );
      expect(PromptCallbackOutput.from(output), same(output));
      expect(PromptCallbackOutput.from(<Message>[]), isNotNull);
      expect(PromptCallbackOutput.from('asd'), isNull);
    });

    test('the variables a graph node reports become the input', () {
      final variables = <String, dynamic>{'name': 'Ada', 'count': 2};

      final input = PromptCallbackInput.from(variables)!;
      expect(input.variables, same(variables));
      expect(input.templates, isNull);
      expect(input.extra, isNull);
    });

    test('the messages a graph node reports become the output', () {
      final messages = [Message.system('s'), Message.user('u')];

      final output = PromptCallbackOutput.from(messages)!;
      expect(output.result, same(messages));
      expect(output.templates, isNull);

      final List<Object?> untyped = [Message.user('u')];
      expect(PromptCallbackOutput.from(untyped)?.result, [Message.user('u')]);
      expect(PromptCallbackOutput.from(<Object?>['u']), isNull);
    });
  });
}
