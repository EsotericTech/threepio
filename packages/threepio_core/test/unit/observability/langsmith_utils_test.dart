// Port of eino-ext `callbacks/langsmith/utils_test.go`: TestRunInfoToName,
// TestRunInfoToRunType, TestConvModelCallbackInput, TestExtractModelInput,
// TestConvModelCallbackOutput, TestExtractModelOutput, TestConcatMessageArray,
// TestGetOrInitState, TestGetState, TestSafeDeepCopySyncMapMetadata, with
// Go's expected values; plus tests of the port (model settings and usage in
// the metadata, the formats of the dotted order and of times).
//
// Not ported: TestSafeDeepCopyMetadata. Go's `SafeDeepCopyMetadata` (a JSON
// round trip) is used by nothing in the package; only the shallow copy of
// `SafeDeepCopySyncMapMetadata` is (`langSmithCopyMetadata`). The "new state
// with options" case of TestGetOrInitState sets `ParentID` and
// `ParentDottedOrder`, which no Go option sets and the port does not have; it
// is ported with the trace id, the one field an option sets.
import 'package:test/test.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_client.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_trace.dart';
import 'package:threepio_core/src/callbacks/handlers/langsmith/langsmith_utils.dart';
import 'package:threepio_core/threepio_core.dart';

void main() {
  group('TestRunInfoToName', () {
    test('with name', () {
      const info = RunInfo(
        name: 'test-name',
        type: 'test-type',
        componentType: ComponentType.custom,
      );
      expect(langSmithRunName(info), 'test-name');
    });

    test('without name', () {
      const info = RunInfo(
        name: '',
        type: 'test-type',
        componentType: ComponentType.chatModel,
      );
      expect(langSmithRunName(info), 'test-typeChatModel');
    });
  });

  group('TestRunInfoToRunType', () {
    RunInfo info(ComponentType type) =>
        RunInfo(name: '', type: 'x', componentType: type);

    test('chat model', () {
      expect(langSmithRunType(info(ComponentType.chatModel)), LangSmithRunType.llm);
    });

    test('tool', () {
      expect(langSmithRunType(info(ComponentType.tool)), LangSmithRunType.tool);
    });

    test('chain', () {
      expect(
        langSmithRunType(info(ComponentType.embedder)),
        LangSmithRunType.chain,
      );
    });

    test('unknown component', () {
      // Go's `Component: "unknown"`: Dart's kinds are an enum, whose catch-all
      // is `custom`.
      expect(
        langSmithRunType(info(ComponentType.custom)),
        LangSmithRunType.chain,
      );
    });

    test('every other kind is a chain run', () {
      for (final type in ComponentType.values) {
        if (type == ComponentType.chatModel || type == ComponentType.tool) {
          continue;
        }
        expect(langSmithRunType(info(type)), LangSmithRunType.chain, reason: '$type');
      }
    });
  });

  group('TestConvModelCallbackInput', () {
    test('empty input', () {
      expect(
        <Object?>[].map(ModelCallbackInput.from).toList(),
        isEmpty,
      );
    });

    test('with valid input', () {
      final result = [
        ModelCallbackInput(messages: [Message.user('test')]),
      ].map(ModelCallbackInput.from).toList();
      expect(result, hasLength(1));
      expect(result.single!.messages.single.content, 'test');
    });
  });

  group('TestExtractModelInput', () {
    test('empty inputs', () {
      final result = langSmithExtractModelInput(const []);
      expect(result.config, isNull);
      expect(result.messages, isEmpty);
      expect(result.extra, isNull);
    });

    test('valid input with messages', () {
      const config = ModelCallbackConfig(model: 'gpt-3.5');
      final result = langSmithExtractModelInput([
        ModelCallbackInput(
          config: config,
          messages: [Message.user('hello')],
          extra: const {'key': 'value'},
        ),
      ]);
      expect(result.config, same(config));
      expect(result.messages, hasLength(1));
      expect(result.extra, {'key': 'value'});
    });

    test('multiple messages', () {
      final result = langSmithExtractModelInput([
        ModelCallbackInput(messages: [Message.user('msg1')]),
        ModelCallbackInput(messages: [Message.user('msg2')]),
      ]);
      expect(result.config, isNull);
      expect(result.messages, hasLength(1));
      expect(result.messages.single.content, 'msg1msg2');
      expect(result.extra, isNull);
    });

    test('the last settings and the last non-empty extra win; null chunks '
        'are skipped', () {
      const first = ModelCallbackConfig(model: 'a');
      const second = ModelCallbackConfig(model: 'b');
      final result = langSmithExtractModelInput([
        const ModelCallbackInput(messages: [], config: first, extra: {'k': 1}),
        null,
        const ModelCallbackInput(messages: [], config: second, extra: {}),
      ]);
      expect(result.config, same(second));
      expect(result.extra, {'k': 1});
      expect(result.messages, isEmpty);
    });

    test('lists of different lengths cannot be joined', () {
      expect(
        () => langSmithExtractModelInput([
          ModelCallbackInput(messages: [Message.user('a')]),
          ModelCallbackInput(messages: [Message.user('b'), Message.user('c')]),
        ]),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            'concat messages failed: unexpected array length. Got 2, '
                'expected 1',
          ),
        ),
      );
    });
  });

  group('TestConvModelCallbackOutput', () {
    test('empty output', () {
      expect(<Object?>[].map(ModelCallbackOutput.from).toList(), isEmpty);
    });

    test('with valid output', () {
      final result = [
        ModelCallbackOutput(message: Message.assistant('response')),
      ].map(ModelCallbackOutput.from).toList();
      expect(result, hasLength(1));
      expect(result.single!.message!.content, 'response');
    });
  });

  group('TestExtractModelOutput', () {
    test('empty outputs', () {
      final result = langSmithExtractModelOutput(const []);
      expect(result.usage, isNull);
      // Go returns an empty message; the port returns `null` for it and the
      // handler writes `langSmithEmptyMessageJson`.
      expect(result.message, isNull);
      expect(langSmithEmptyMessageJson, {'role': '', 'content': ''});
      expect(result.extra, isNull);
    });

    test('valid output with message', () {
      const usage = TokenUsage(
        promptTokens: 0,
        completionTokens: 0,
        totalTokens: 100,
      );
      final result = langSmithExtractModelOutput([
        ModelCallbackOutput(
          tokenUsage: usage,
          message: Message.assistant('response'),
          extra: const {'key': 'value'},
        ),
      ]);
      expect(result.usage, usage);
      expect(result.message!.content, 'response');
      expect(result.extra, {'key': 'value'});
    });

    test('chunks are joined; the last usage and extra win', () {
      const usage = TokenUsage(
        promptTokens: 3,
        completionTokens: 2,
        totalTokens: 5,
      );
      final result = langSmithExtractModelOutput([
        ModelCallbackOutput(
          message: Message.assistant('Hel'),
          extra: const {'a': 1},
        ),
        null,
        ModelCallbackOutput(
          message: Message.assistant('lo'),
          tokenUsage: usage,
          extra: const {},
        ),
      ]);
      expect(result.message!.content, 'Hello');
      expect(result.usage, usage);
      expect(result.extra, isEmpty, reason: 'Go: `out.Extra != nil` wins');
    });

    test('messages that contradict each other cannot be joined', () {
      expect(
        () => langSmithExtractModelOutput([
          ModelCallbackOutput(message: Message.assistant('a')),
          ModelCallbackOutput(message: Message.user('b')),
        ]),
        throwsA(
          isA<ThreepioException>().having(
            (e) => e.message,
            'message',
            'concat message failed: cannot concat messages with different '
                "roles: 'assistant' 'user'",
          ),
        ),
      );
    });
  });

  group('TestConcatMessageArray', () {
    // Go's package-local `concatMessageArray` is eino's
    // `schema.ConcatMessageArray`, which the port uses.
    test('empty arrays', () {
      expect(concatMessageArray(const []), isEmpty);
    });

    test('single array', () {
      final result = concatMessageArray([
        [Message.user('msg1'), Message.user('msg2')],
      ]);
      expect([for (final m in result) m.content], ['msg1', 'msg2']);
    });

    test('multiple arrays', () {
      final result = concatMessageArray([
        [Message.user('msg1'), Message.user('msg2')],
        [Message.user('msg3'), Message.user('msg4')],
      ]);
      expect([for (final m in result) m.content], ['msg1msg3', 'msg2msg4']);
    });

    test('mismatched array lengths', () {
      expect(
        () => concatMessageArray([
          [Message.user('msg1')],
          [Message.user('msg2'), Message.user('msg3')],
        ]),
        throwsA(
          isA<MessageConcatException>().having(
            (e) => e.message,
            'message',
            'unexpected array length. Got 2, expected 1',
          ),
        ),
      );
    });
  });

  group('TestGetOrInitState', () {
    test('existing state', () {
      const existing = LangSmithState(traceId: 'existing');
      final ctx = LangSmithTrace.withState(RunContext.background(), existing);

      final (newCtx, state) = LangSmithTrace.getOrInitState(ctx);
      expect(newCtx, same(ctx));
      expect(state, same(existing));
      expect(state.traceId, 'existing');
    });

    test('new state without options', () {
      final ctx = RunContext.background();
      final (newCtx, state) = LangSmithTrace.getOrInitState(ctx);
      expect(newCtx, isNot(same(ctx)));
      expect(state.traceId, isEmpty);
      expect(LangSmithTrace.stateOf(newCtx), same(state));
    });

    test('new state with options', () {
      final ctx = LangSmithTrace.set(
        RunContext.background(),
        traceId: 'test-trace',
      );
      final (newCtx, state) = LangSmithTrace.getOrInitState(ctx);
      expect(newCtx, isNot(same(ctx)));
      expect(state.traceId, 'test-trace');
      expect(state.parentRunId, isEmpty);
      expect(state.parentDottedOrder, isEmpty);
    });
  });

  group('TestGetState', () {
    test('existing state', () {
      const existing = LangSmithState(traceId: 'existing');
      final ctx = LangSmithTrace.withState(RunContext.background(), existing);
      expect(LangSmithTrace.stateOf(ctx), same(existing));
    });

    test('no state', () {
      expect(LangSmithTrace.stateOf(RunContext.background()), isNull);
    });
  });

  group('TestSafeDeepCopySyncMapMetadata', () {
    test('nil sync map', () {
      final result = langSmithCopyMetadata(null);
      expect(result, contains('metadata'));
      expect(result['metadata'], <String, Object?>{});
    });

    test('empty sync map', () {
      final result = langSmithCopyMetadata(const {});
      expect(result, contains('metadata'));
    });

    test('with data', () {
      final original = <String, Object?>{
        'key1': 'value1',
        'key2': 123,
        'nested': {'key3': true},
      };
      final result = langSmithCopyMetadata(original);
      expect(result['key1'], 'value1');
      expect(result['key2'], 123);
      expect(result['nested'], {'key3': true});
      expect(result, contains('metadata'));
      expect(original, isNot(contains('metadata')), reason: 'a copy');
    });

    test('an existing metadata entry is kept', () {
      final inner = {'cid': 'c1'};
      final result = langSmithCopyMetadata({'metadata': inner});
      expect(result['metadata'], same(inner), reason: 'shallow, as in Go');
    });
  });

  test('error text is the message of a threepio exception', () {
    expect(langSmithErrorText(const ThreepioException('boom')), 'boom');
    expect(langSmithErrorText(StateError('x')), 'Bad state: x');
    expect(langSmithErrorText(null), 'null');
  });

  group('model settings and usage in the metadata', () {
    test('the settings Go writes, in a copy of the metadata map', () {
      final inner = <String, Object?>{'env': 'test'};
      final extra = {'metadata': inner, 'other': 1};
      final result = langSmithWithModelConfig(
        extra,
        const ModelCallbackConfig(
          model: 'gpt-4o',
          maxTokens: 256,
          temperature: 0.5,
          topP: 0.9,
          stop: ['END'],
        ),
      );
      expect(result, {
        'metadata': {
          'env': 'test',
          'ls_model_name': 'gpt-4o',
          'ls_max_tokens': 256,
          'model_conf': {
            'Model': 'gpt-4o',
            'MaxTokens': 256,
            'Temperature': 0.5,
            'TopP': 0.9,
            'Stop': ['END'],
          },
        },
        'other': 1,
      });
      expect(inner, {'env': 'test'}, reason: "the caller's map is not changed");
    });

    test("settings the call left out are Go's zero values", () {
      final result = langSmithWithModelConfig(
        langSmithCopyMetadata(null),
        const ModelCallbackConfig(),
      );
      expect(result['metadata'], {
        'ls_model_name': '',
        'ls_max_tokens': 0,
        'model_conf': {
          'Model': '',
          'MaxTokens': 0,
          'Temperature': 0,
          'TopP': 0,
          'Stop': null,
        },
      });
    });

    test('a metadata entry that is not a map is left alone', () {
      final extra = {'metadata': 'text'};
      expect(
        langSmithWithModelConfig(extra, const ModelCallbackConfig(model: 'm')),
        same(extra),
      );
      expect(
        langSmithWithUsage(
          extra,
          const TokenUsage(promptTokens: 1, completionTokens: 1, totalTokens: 2),
        ),
        same(extra),
      );
    });

    test('usage goes into usage_metadata', () {
      final result = langSmithWithUsage(
        {
          'metadata': {'ls_model_name': 'm'},
        },
        const TokenUsage(promptTokens: 7, completionTokens: 3, totalTokens: 10),
      );
      expect(result['metadata'], {
        'ls_model_name': 'm',
        'usage_metadata': {
          'input_tokens': 7,
          'output_tokens': 3,
          'total_tokens': 10,
        },
      });
    });
  });

  group('time formats', () {
    test('the dotted order has the microseconds, as LangSmith writes it', () {
      final time = DateTime.utc(2025, 10, 10, 9, 4, 5, 123, 456);
      // LangSmith: strftime("%Y%m%dT%H%M%S%fZ") + id. Go's layout
      // "20060102T150405000000" writes literal zeros instead (a Go bug the
      // port fixes; see `langSmithDottedTime`).
      expect(langSmithDottedTime(time), '20251010T090405123456');
      expect(
        langSmithDottedTime(DateTime.utc(2025, 10, 10, 9, 4, 5, 0, 7)),
        '20251010T090405000007',
      );
      expect(
        langSmithDottedOrder('', time, 'run-1'),
        '20251010T090405123456Zrun-1',
      );
      expect(
        langSmithDottedOrder('20251010T090405123456Zrun-1', time, 'run-2'),
        '20251010T090405123456Zrun-1.20251010T090405123456Zrun-2',
      );
    });

    test('runs that start within one second sort by their start', () {
      final base = DateTime.utc(2025, 10, 10, 9, 4, 5);
      // Ids that sort the other way round, as random ids may.
      final first = langSmithDottedOrder('', base, 'ffff');
      final second = langSmithDottedOrder(
        '',
        base.add(const Duration(microseconds: 1)),
        '0000',
      );
      expect(first.compareTo(second), isNegative);
    });

    test('a local time is written in UTC', () {
      final utc = DateTime.utc(2025, 1, 2, 3, 4, 5);
      expect(langSmithDottedTime(utc.toLocal()), '20250102T030405000000');
      expect(langSmithTimeJson(utc.toLocal()), '2025-01-02T03:04:05Z');
    });

    test("JSON times are Go's RFC 3339 without trailing zeros", () {
      expect(
        langSmithTimeJson(DateTime.utc(2025, 10, 10, 12, 34, 56, 123, 456)),
        '2025-10-10T12:34:56.123456Z',
      );
      expect(
        langSmithTimeJson(DateTime.utc(2025, 10, 10, 12, 34, 56, 120)),
        '2025-10-10T12:34:56.12Z',
      );
      expect(
        langSmithTimeJson(DateTime.utc(2025, 10, 10, 12, 34, 56, 0, 5)),
        '2025-10-10T12:34:56.000005Z',
      );
      expect(
        langSmithTimeJson(DateTime.utc(2025, 10, 10, 12, 34, 56)),
        '2025-10-10T12:34:56Z',
      );
      expect(
        langSmithTimeJson(DateTime.utc(987)),
        '0987-01-01T00:00:00Z',
      );
    });
  });
}
