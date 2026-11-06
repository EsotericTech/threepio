// Port of eino-ext components/model/agenticopenai/option_test.go (all of it
// is about the Responses options): TestWithResponsesStore,
// TestWithResponsesPromptCacheKey, TestWithResponsesReasoning,
// TestWithResponsesText, TestWithResponsesMaxToolCalls,
// TestWithResponsesParallelToolCalls, TestWithResponsesServerTools,
// TestWithResponsesMCPTools, TestWithCustomHeaders, TestWithExtraFields.
//
// Go applies `WithX` functions to its private `options` struct; here an
// `OpenAIResponsesOptions` in `ChatModelOptions.extensions` is resolved
// against the config (`ResolvedResponsesOptions.resolve`). The "set nil …"
// cases become "not set" (null means "keep the config's value" here; pass
// an empty map or list to clear one, as the "set empty" cases show).
import 'package:test/test.dart';
import 'package:threepio_core/components.dart' show ChatModelOptions;
import 'package:threepio_core/schema.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_config.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_options.dart';
import 'package:threepio_core/src/components/model/providers/openai_responses/openai_responses_request.dart';

ResolvedResponsesOptions _resolve(
  OpenAIResponsesOptions? call, {
  OpenAIResponsesConfig config = const OpenAIResponsesConfig(),
}) =>
    ResolvedResponsesOptions.resolve(
      config,
      call == null ? null : ChatModelOptions(extensions: [call]),
    );

void main() {
  group('TestWithResponsesStore', () {
    test('set store to true', () {
      expect(_resolve(const OpenAIResponsesOptions(store: true)).store, isTrue);
    });
    test('set store to false', () {
      expect(
        _resolve(const OpenAIResponsesOptions(store: false)).store,
        isFalse,
      );
    });
  });

  group('TestWithResponsesPromptCacheKey', () {
    test('set cache key', () {
      expect(
        _resolve(const OpenAIResponsesOptions(promptCacheKey: 'test-cache-key'))
            .promptCacheKey,
        'test-cache-key',
      );
    });
    test('set empty cache key', () {
      expect(
        _resolve(const OpenAIResponsesOptions(promptCacheKey: '')).promptCacheKey,
        '',
      );
    });
  });

  group('TestWithResponsesReasoning', () {
    test('set reasoning param', () {
      const reasoning =
          OpenAIResponsesReasoning(effort: OpenAIReasoningEffort.low);
      expect(
        _resolve(const OpenAIResponsesOptions(reasoning: reasoning)).reasoning,
        reasoning,
      );
    });
    test('set nil reasoning', () {
      expect(_resolve(const OpenAIResponsesOptions()).reasoning, isNull);
    });
  });

  group('TestWithResponsesText', () {
    test('set text config', () {
      const text =
          OpenAIResponsesTextConfig(verbosity: OpenAIResponsesTextVerbosity.low);
      expect(_resolve(const OpenAIResponsesOptions(text: text)).text, text);
    });
    test('set nil text', () {
      expect(_resolve(const OpenAIResponsesOptions()).text, isNull);
    });
  });

  group('TestWithResponsesMaxToolCalls', () {
    test('set positive value', () {
      expect(
        _resolve(const OpenAIResponsesOptions(maxToolCalls: 5)).maxToolCalls,
        5,
      );
    });
    test('set zero value', () {
      expect(
        _resolve(const OpenAIResponsesOptions(maxToolCalls: 0)).maxToolCalls,
        0,
      );
    });
  });

  group('TestWithResponsesParallelToolCalls', () {
    test('set to true', () {
      expect(
        _resolve(const OpenAIResponsesOptions(parallelToolCalls: true))
            .parallelToolCalls,
        isTrue,
      );
    });
    test('set to false', () {
      expect(
        _resolve(const OpenAIResponsesOptions(parallelToolCalls: false))
            .parallelToolCalls,
        isFalse,
      );
    });
  });

  group('TestWithResponsesServerTools', () {
    test('set server tools', () {
      const tools = [OpenAIResponsesWebSearchTool()];
      final resolved =
          _resolve(const OpenAIResponsesOptions(serverTools: tools));
      expect(resolved.serverTools, hasLength(1));
      expect(identical(resolved.serverTools, tools), isTrue);
    });
    test('set empty tools', () {
      final resolved = _resolve(const OpenAIResponsesOptions(serverTools: []));
      expect(resolved.serverTools, isNotNull);
      expect(resolved.serverTools, isEmpty);
    });
    test('set nil tools', () {
      expect(_resolve(const OpenAIResponsesOptions()).serverTools, isNull);
    });
  });

  group('TestWithResponsesMCPTools', () {
    test('set mcp tools', () {
      const tools = [OpenAIResponsesMcpTool(serverLabel: 'test-server')];
      final resolved = _resolve(const OpenAIResponsesOptions(mcpTools: tools));
      expect(resolved.mcpTools, hasLength(1));
      expect(resolved.mcpTools!.single.serverLabel, 'test-server');
    });
    test('set empty tools', () {
      final resolved = _resolve(const OpenAIResponsesOptions(mcpTools: []));
      expect(resolved.mcpTools, isNotNull);
      expect(resolved.mcpTools, isEmpty);
    });
    test('set nil tools', () {
      expect(_resolve(const OpenAIResponsesOptions()).mcpTools, isNull);
    });
  });

  group('TestWithCustomHeaders', () {
    test('set custom headers', () {
      final resolved = _resolve(
        const OpenAIResponsesOptions(
          customHeaders: {'X-Custom-Header': 'value', 'X-Another': 'another'},
        ),
      );
      expect(resolved.customHeaders, {
        'X-Custom-Header': 'value',
        'X-Another': 'another',
      });
    });
    test('set empty headers', () {
      final resolved =
          _resolve(const OpenAIResponsesOptions(customHeaders: {}));
      expect(resolved.customHeaders, isNotNull);
      expect(resolved.customHeaders, isEmpty);
    });
    test('set nil headers', () {
      expect(_resolve(const OpenAIResponsesOptions()).customHeaders, isNull);
    });
  });

  group('TestWithExtraFields', () {
    test('set extra fields', () {
      final resolved = _resolve(
        const OpenAIResponsesOptions(
          extraFields: {'reasoning_effort': 'high', 'n': 1},
        ),
      );
      expect(resolved.extraFields, {'reasoning_effort': 'high', 'n': 1});
    });
    test('set empty fields', () {
      final resolved = _resolve(const OpenAIResponsesOptions(extraFields: {}));
      expect(resolved.extraFields, isNotNull);
      expect(resolved.extraFields, isEmpty);
    });
    test('set nil fields', () {
      expect(_resolve(const OpenAIResponsesOptions()).extraFields, isNull);
    });
    test('replace fields set by an earlier option', () {
      // Go applies options in order, so the later one replaces the earlier
      // one; merged options put the call's extensions first, and the first
      // one that sets a field wins.
      final resolved = ResolvedResponsesOptions.resolve(
        const OpenAIResponsesConfig(),
        const ChatModelOptions(
          extensions: [OpenAIResponsesOptions(extraFields: {'a': 1})],
        ).merge(
          const ChatModelOptions(
            extensions: [OpenAIResponsesOptions(extraFields: {'b': 2})],
          ),
        ),
      );
      expect(resolved.extraFields, {'b': 2});
    });
  });

  group('config defaults', () {
    test('the config is the default of every field the options leave unset',
        () {
      const config = OpenAIResponsesConfig(
        store: false,
        maxToolCalls: 3,
        parallelToolCalls: true,
        truncation: OpenAIResponsesTruncation.auto,
        customHeaders: {'h': 'v'},
        extraFields: {'x': 1},
        reasoning: OpenAIResponsesReasoning(effort: OpenAIReasoningEffort.high),
      );
      final resolved = _resolve(
        const OpenAIResponsesOptions(store: true, headPreviousResponseId: 'r'),
        config: config,
      );
      expect(resolved.store, isTrue);
      expect(resolved.maxToolCalls, 3);
      expect(resolved.parallelToolCalls, isTrue);
      expect(resolved.truncation, OpenAIResponsesTruncation.auto);
      expect(resolved.customHeaders, {'h': 'v'});
      expect(resolved.extraFields, {'x': 1});
      expect(resolved.reasoning!.effort, OpenAIReasoningEffort.high);
      expect(resolved.headPreviousResponseId, 'r');
    });

    test('several options fill each other in, the first one wins', () {
      final resolved = ResolvedResponsesOptions.resolve(
        const OpenAIResponsesConfig(),
        const ChatModelOptions(
          extensions: [
            OpenAIResponsesOptions(store: true),
            OpenAIResponsesOptions(store: false, maxToolCalls: 2),
          ],
        ),
      );
      expect(resolved.store, isTrue);
      expect(resolved.maxToolCalls, 2);
    });

    test('toOptions carries the options in extensions', () {
      final options = const OpenAIResponsesOptions(store: true)
          .toOptions(model: 'm', temperature: 0.5);
      expect(options.model, 'm');
      expect(options.temperature, 0.5);
      expect(options.extension<OpenAIResponsesOptions>()!.store, isTrue);
    });
  });
}
