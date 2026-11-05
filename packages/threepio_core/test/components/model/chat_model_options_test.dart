// Port of eino `components/model/option_test.go` (TestOptions,
// TestImplSpecificOption), and tests for what ChatModelOptions adds to it.
import 'package:test/test.dart';
import 'package:threepio_core/threepio_core.dart';

/// The implementation-specific options of the Go test (`implOption`).
final class _ImplOption {
  const _ImplOption({this.userId = 0, this.name = ''});

  final int userId;
  final String name;
}

final class _OtherOption {
  const _OtherOption(this.value);

  final String value;
}

final class _SubImplOption extends _ImplOption {
  const _SubImplOption({super.userId});
}

ToolInfo _tool(String name) =>
    ToolInfo.fromParams(name: name, params: const {});

void main() {
  group('TestOptions', () {
    test('later options override the defaults they are merged into', () {
      final tools = [_tool('asd'), _tool('qwe')];

      final options = const ChatModelOptions(
        model: 'default_model',
        temperature: 1,
        maxTokens: 1000,
        topP: 0.5,
      ).merge(
        ChatModelOptions(
          model: 'model',
          temperature: 0.9,
          maxTokens: 5000,
          topP: 0.8,
          stop: const ['hello', 'bye'],
          tools: tools,
          toolChoice: ToolChoice.forced,
          allowedToolNames: const ['web_search'],
        ),
      );

      expect(options.model, 'model');
      expect(options.temperature, 0.9);
      expect(options.maxTokens, 5000);
      expect(options.topP, 0.8);
      expect(options.stop, ['hello', 'bye']);
      expect(options.tools, same(tools));
      expect(options.toolChoice, ToolChoice.forced);
      expect(options.allowedToolNames, ['web_search']);
    });

    test('what the later options leave unset keeps its default', () {
      final options = const ChatModelOptions(
        model: 'default_model',
        temperature: 1,
        maxTokens: 1000,
      ).merge(const ChatModelOptions(temperature: 0.2));

      expect(options.model, 'default_model');
      expect(options.temperature, 0.2);
      expect(options.maxTokens, 1000);
    });

    test('an empty tool list overrides bound tools (WithTools(nil))', () {
      final options = ChatModelOptions(tools: [_tool('asd'), _tool('qwe')])
          .merge(const ChatModelOptions(tools: []));

      expect(options.tools, isNotNull);
      expect(options.tools, isEmpty);
    });

    test('merging null changes nothing', () {
      const options = ChatModelOptions(model: 'm');
      expect(options.merge(null), same(options));
    });
  });

  group('allowed tool names go with their tool choice', () {
    test('a tool choice without names clears the names of the base', () {
      final options = const ChatModelOptions(
        toolChoice: ToolChoice.forced,
        allowedToolNames: ['web_search'],
      ).merge(const ChatModelOptions(toolChoice: ToolChoice.allowed));

      expect(options.toolChoice, ToolChoice.allowed);
      expect(options.allowedToolNames, isNull);
    });

    test('options without a tool choice keep the names of the base', () {
      final options = const ChatModelOptions(
        toolChoice: ToolChoice.forced,
        allowedToolNames: ['web_search'],
      ).merge(const ChatModelOptions(temperature: 0.1));

      expect(options.toolChoice, ToolChoice.forced);
      expect(options.allowedToolNames, ['web_search']);
    });
  });

  group('deferred tools and the tool search tool', () {
    test('are carried and merged like the other fields', () {
      final deferred = [_tool('rarely_used')];
      final search = _tool('tool_search');

      final options = const ChatModelOptions(model: 'm').merge(
        ChatModelOptions(deferredTools: deferred, toolSearchTool: search),
      );

      expect(options.deferredTools, same(deferred));
      expect(options.toolSearchTool, same(search));
      expect(
        options.merge(const ChatModelOptions(deferredTools: [])).deferredTools,
        isEmpty,
      );
    });

    test('are unset by default', () {
      const options = ChatModelOptions();
      expect(options.deferredTools, isNull);
      expect(options.toolSearchTool, isNull);
      expect(options.allowedToolNames, isNull);
      expect(options.runContext, isNull);
      expect(options.extensions, isEmpty);
    });
  });

  group('TestImplSpecificOption', () {
    test('a model reads its own options from the extensions', () {
      const options = ChatModelOptions(
        extensions: [_ImplOption(userId: 101, name: 'Wang')],
      );

      final own = options.extension<_ImplOption>();
      expect(own?.userId, 101);
      expect(own?.name, 'Wang');
    });

    test('an option that is not there is null, so the model uses its default',
        () {
      const options = ChatModelOptions(extensions: [_OtherOption('x')]);

      final own = options.extension<_ImplOption>() ?? const _ImplOption();
      expect(own.userId, 0);
      expect(own.name, '');
    });

    test('options of several implementations travel together', () {
      const options = ChatModelOptions(
        extensions: [_OtherOption('x'), _ImplOption(userId: 7)],
      );

      expect(options.extension<_OtherOption>()?.value, 'x');
      expect(options.extension<_ImplOption>()?.userId, 7);
    });

    test('a subclass of the requested type is found', () {
      const options = ChatModelOptions(
        extensions: [_SubImplOption(userId: 9)],
      );
      expect(options.extension<_ImplOption>()?.userId, 9);
    });

    test('of two options of one type the first is used', () {
      const options = ChatModelOptions(
        extensions: [_ImplOption(userId: 1), _ImplOption(userId: 2)],
      );
      expect(options.extension<_ImplOption>()?.userId, 1);
    });

    test('merge puts the extensions of the later options first', () {
      final options = const ChatModelOptions(
        extensions: [_ImplOption(userId: 1), _OtherOption('base')],
      ).merge(const ChatModelOptions(extensions: [_ImplOption(userId: 2)]));

      expect(options.extension<_ImplOption>()?.userId, 2);
      expect(options.extension<_OtherOption>()?.value, 'base');
      expect(options.extensions, hasLength(3));
    });

    test('merge keeps the list of the side that has extensions', () {
      const withExtensions =
          ChatModelOptions(extensions: [_ImplOption(userId: 1)]);
      const without = ChatModelOptions(model: 'm');

      expect(
        withExtensions.merge(without).extensions,
        same(withExtensions.extensions),
      );
      expect(
        without.merge(withExtensions).extensions,
        same(withExtensions.extensions),
      );
    });
  });

  group('runContext', () {
    test('is carried by copyWith and merge', () {
      final ctx = RunContext.background();
      final other = RunContext.background();

      final options = const ChatModelOptions(model: 'm').copyWith(runContext: ctx);
      expect(options.runContext, same(ctx));
      expect(options.model, 'm');

      expect(
        options.merge(const ChatModelOptions(temperature: 0.3)).runContext,
        same(ctx),
      );
      expect(
        options.merge(ChatModelOptions(runContext: other)).runContext,
        same(other),
      );
    });
  });

  group('copyWith', () {
    test('replaces the new fields and keeps the rest', () {
      final search = _tool('tool_search');
      final copy = const ChatModelOptions(
        model: 'm',
        maxTokens: 10,
        allowedToolNames: ['a'],
      ).copyWith(
        allowedToolNames: const ['b'],
        deferredTools: [_tool('x')],
        toolSearchTool: search,
        extensions: const [_OtherOption('y')],
      );

      expect(copy.model, 'm');
      expect(copy.maxTokens, 10);
      expect(copy.allowedToolNames, ['b']);
      expect(copy.deferredTools, hasLength(1));
      expect(copy.toolSearchTool, same(search));
      expect(copy.extension<_OtherOption>()?.value, 'y');
    });

    test('keeps the fields that existed before', () {
      final token = CancelToken();
      final copy = ChatModelOptions(
        temperature: 0.4,
        cancelToken: token,
        extra: const {'seed': 1},
        metadata: const {'trace': 't'},
      ).copyWith(model: 'other');

      expect(copy.model, 'other');
      expect(copy.temperature, 0.4);
      expect(copy.cancelToken, same(token));
      expect(copy.extra, {'seed': 1});
      expect(copy.metadata, {'trace': 't'});
    });
  });
}
