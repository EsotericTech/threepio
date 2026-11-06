// Port of eino v0.9.22 `adk/middlewares/summarization/finalizer_builder_test.go`.
//
// Ported (12 Go tests): TestNewFinalizer, TestBuildEmpty, TestBuildConfigError,
// TestDefaultFinalizeBasic, TestBuildStepChaining (adapted),
// TestBuildStepError (adapted), TestBuildPostProcessError (adapted),
// TestDefaultFinalizeError, TestPreserveSkillsConfigCheck,
// TestPreserveSkillsViaBuilder, TestBuildPreservedSkillsText.
//
// Not ported:
// * TestBuildHandlerReturnsEmpty: Go appends a custom handler to the private
//   `b.handlers`; the Dart builder's only public step (`preserveSkills`)
//   always returns at least the summary, so the empty result cannot be made.
// * A nil `*PreserveSkillsConfig` is a compile-time error in Dart
//   (non-nullable parameter): TestBuildConfigError "nil config",
//   TestPreserveSkillsConfigCheck "nil config", TestBuildPreservedSkillsText
//   "nil config".
// * No agentic sub-tests in this file.
//
// Go tests that append to the private `b.handlers` (TestBuildStepChaining,
// TestBuildStepError, TestBuildPostProcessError) are adapted to the public
// `preserveSkills` step; `b.handlers` being empty (TestNewFinalizer) is seen
// through `build()`; `PreserveSkillsConfig.check()` is private and seen
// through `build()` too.
import 'dart:convert';

import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/summarization/finalizer_builder.dart';
import 'package:threepio_core/src/adk/middlewares/summarization/summarization.dart';

final RunContext ctx = RunContext.background();

Matcher _throwsContaining(String text) => throwsA(
      predicate((Object? e) => '$e'.contains(text), 'an error containing "$text"'),
    );

/// gomock-free stand-in for the summary model: answers [content].
class _Model extends BaseChatModel {
  _Model(this.content);

  final String content;
  int calls = 0;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) async {
    calls++;
    return Message.assistant(content);
  }

  @override
  Future<StreamReader<Message>> stream(List<Message> input, {ChatModelOptions? options}) =>
      throw UnimplementedError('stream is not used by the summarization middleware');
}

ToolCall _call(String id, String name, String arguments) =>
    ToolCall(id: id, function: FunctionCall(name: name, arguments: arguments));

Message _calls(List<ToolCall> calls) => Message(role: RoleType.assistant, toolCalls: calls);

Message _result(String callId, String content) =>
    Message(role: RoleType.tool, toolCallId: callId, content: content);

SummaryFinalizer _build(PreserveSkillsConfig config) =>
    (SummaryFinalizerBuilder()..preserveSkills(config)).build();

void main() {
  // `assert.Empty(b.handlers)` → a builder without steps refuses to build.
  test('TestNewFinalizer', () {
    final b = SummaryFinalizerBuilder();
    expect(b, isNotNull);
    expect(b.build, _throwsContaining('at least one handler is required'));

    // NewTypedFinalizer[*schema.Message]() is the same builder in Dart.
    final tb = SummaryFinalizerBuilder();
    expect(tb, isNotNull);
    expect(tb.build, _throwsContaining('at least one handler is required'));
  });

  test('TestBuildEmpty', () {
    expect(() => SummaryFinalizerBuilder().build(), _throwsContaining('at least one handler is required'));
  });

  group('TestBuildConfigError', () {
    test('negative max skills', () {
      expect(
        () => _build(const PreserveSkillsConfig(maxSkills: -1)),
        allOf(_throwsContaining('PreserveSkills:'), _throwsContaining('MaxSkills must be non-negative')),
      );
    });
  });

  test('TestDefaultFinalizeBasic', () async {
    final result = await defaultSummaryFinalize(
      ctx,
      [Message.system('system prompt'), Message.user('original user')],
      Message.assistant('raw summary'),
    );
    expect(result, hasLength(2));
    expect(result[0].role, RoleType.system);
    expect(result[1].role, RoleType.user);
    expect(summarizationContentType(result[1]), contentTypeSummary);
    expect(result[1].content, contains('raw summary'));
  });

  // Adapted: Go chains two custom handlers that append to the summary's
  // content; the Dart builder's public step is `preserveSkills`. Two such
  // steps (for two skill tools) chain the same way: each step's extra message
  // is kept in order, the summary goes through both and is post-processed
  // last.
  test('TestBuildStepChaining', () async {
    final finalizer = (SummaryFinalizerBuilder()
          ..preserveSkills(const PreserveSkillsConfig(skillToolName: 'step1'))
          ..preserveSkills(const PreserveSkillsConfig(skillToolName: 'step2')))
        .build();
    final original = [
      _calls([_call('c1', 'step1', '{"skill": "one"}'), _call('c2', 'step2', '{"skill": "two"}')]),
      _result('c1', 'content one'),
      _result('c2', 'content two'),
    ];
    final result = await finalizer(ctx, original, Message.assistant('start'));
    expect(result, hasLength(3));
    expect(result[0].content, contains('content one'));
    expect(result[1].content, contains('content two'));
    expect(result[2].role, RoleType.user);
    expect(result[2].content, contains('start'));
  });

  // Adapted: Go's custom handler returns `errors.New("step failed")`; here
  // the `preserveSkills` step fails (invalid skill arguments) and its error
  // propagates out of the finalizer the same way.
  test('TestBuildStepError', () async {
    final finalizer = _build(const PreserveSkillsConfig(skillToolName: 'load_skill'));
    final original = [
      _calls([_call('call_1', 'load_skill', 'invalid json')]),
      _result('call_1', 'content'),
    ];
    await expectLater(
      finalizer(ctx, original, Message.user('test')),
      _throwsContaining('failed to parse skill arguments'),
    );
  });

  // Adapted: Go's custom handler replaces the summary with a user message;
  // here the `preserveSkills` step passes a user-message summary through,
  // and post-processing finds no assistant text, as in Go.
  test('TestBuildPostProcessError', () async {
    final finalizer = _build(const PreserveSkillsConfig());
    await expectLater(
      finalizer(ctx, const [], Message.user('not assistant')),
      _throwsContaining('summary content is empty'),
    );
  });

  test('TestDefaultFinalizeError', () async {
    await expectLater(
      defaultSummaryFinalize(ctx, [Message.user('original')], Message.user('not an assistant message')),
      _throwsContaining('summary content is empty'),
    );
  });

  // `PreserveSkillsConfig.check()` is private: an invalid config makes
  // `build()` throw with its text, a valid one builds.
  group('TestPreserveSkillsConfigCheck', () {
    test('valid config', () {
      expect(() => _build(const PreserveSkillsConfig(maxSkills: 5, skillToolName: 'load_skill')), returnsNormally);
    });

    test('zero max skills', () {
      expect(() => _build(const PreserveSkillsConfig(maxSkills: 0)), returnsNormally);
    });

    test('negative max skills', () {
      expect(
        () => _build(const PreserveSkillsConfig(maxSkills: -1)),
        _throwsContaining('MaxSkills must be non-negative'),
      );
    });

    test('nil max skills', () {
      expect(() => _build(const PreserveSkillsConfig()), returnsNormally);
    });

    test('negative max tokens per skill', () {
      expect(
        () => _build(const PreserveSkillsConfig(maxTokensPerSkill: -1)),
        _throwsContaining('MaxTokensPerSkill must be non-negative'),
      );
    });

    test('negative skills token budget', () {
      expect(
        () => _build(const PreserveSkillsConfig(skillsTokenBudget: -1)),
        _throwsContaining('SkillsTokenBudget must be non-negative'),
      );
    });
  });

  // Go puts the model input in the context with the private `ctxKeyModelInput`;
  // in Dart only the middleware sets it, so the finalizer runs inside
  // `summarize` with a `genModelInput` that returns Go's `modelInput`.
  test('TestPreserveSkillsViaBuilder', () async {
    final finalizer = _build(const PreserveSkillsConfig(maxSkills: 2, skillToolName: 'load_skill'));
    final originalMessages = [Message.system('system prompt'), Message.user('original')];
    final modelInput = [
      _calls([_call('call_1', 'load_skill', '{"skill": "test-skill"}')]),
      _result('call_1', 'skill content 1'),
    ];
    final model = _Model('test summary');
    final mw = SummarizationMiddleware(
      model: model,
      genModelInput: (ctx, system, user, original) => modelInput,
      finalize: finalizer,
    );

    final result = await mw.summarize(ctx, ChatModelAgentState(messages: originalMessages));
    expect(model.calls, 1);
    expect(result, hasLength(3));

    expect(result[0].role, RoleType.system);
    expect(result[0].content, 'system prompt');

    expect(result[1].role, RoleType.user);
    expect(summarizationContentType(result[1]), contentTypeSkills);
    expect(result[1].content, contains('test-skill'));
    expect(result[1].content, contains('skill content 1'));

    expect(result[2].role, RoleType.user);
    expect(summarizationContentType(result[2]), contentTypeSummary);
    expect(result[2].content, contains('test summary'));
  });

  group('TestBuildPreservedSkillsText', () {
    test('zero max skills', () {
      expect(buildPreservedSkillsText(const [], const PreserveSkillsConfig(maxSkills: 0)), isEmpty);
    });

    test('no matching skills', () {
      final text = buildPreservedSkillsText(
        [Message.user('hi')],
        const PreserveSkillsConfig(maxSkills: 5, skillToolName: 'load_skill'),
      );
      expect(text, isEmpty);
    });

    test('with default skill tool name', () {
      final messages = [
        _calls([_call('call_1', 'skill', '{"skill": "test-skill"}')]),
        _result('call_1', 'skill content 1'),
      ];
      final text = buildPreservedSkillsText(messages, const PreserveSkillsConfig(maxSkills: 2));
      expect(text, contains('test-skill'));
      expect(text, contains('skill content 1'));
    });

    test('parse error', () {
      final messages = [
        _calls([_call('call_1', 'load_skill', 'invalid json')]),
        _result('call_1', 'content'),
      ];
      expect(
        () => buildPreservedSkillsText(
          messages,
          const PreserveSkillsConfig(maxSkills: 2, skillToolName: 'load_skill'),
        ),
        _throwsContaining('failed to parse skill arguments'),
      );
    });

    test('max skills truncation and deduplication', () {
      final messages = [
        _calls([
          _call('call_1', 'load_skill', '{"skill": "skill1"}'),
          _call('call_2', 'load_skill', '{"skill": "skill2"}'),
          _call('call_3', 'load_skill', '{"skill": "skill1"}'),
          _call('call_4', 'load_skill', '{"skill": "skill3"}'),
        ]),
        _result('call_1', 'c1'),
        _result('call_2', 'c2'),
        _result('call_3', 'c3'),
        _result('call_4', 'c4'),
      ];
      final text = buildPreservedSkillsText(
        messages,
        const PreserveSkillsConfig(maxSkills: 2, skillToolName: 'load_skill'),
      );
      expect(text, contains('skill1'));
      expect(text, contains('c3'));
      expect(text, contains('skill3'));
      expect(text, contains('c4'));
      expect(text, isNot(contains('c1')));
      expect(text, isNot(contains('skill2')));
      expect(text, isNot(contains('c2')));
    });

    test('per skill token limit truncates large skills', () {
      final largeContent = 'x' * 100;
      final messages = [
        _calls([
          _call('call_1', 'load_skill', '{"skill": "small"}'),
          _call('call_2', 'load_skill', '{"skill": "large"}'),
        ]),
        _result('call_1', 'short'),
        _result('call_2', largeContent),
      ];
      final text = buildPreservedSkillsText(
        messages,
        const PreserveSkillsConfig(maxSkills: 10, maxTokensPerSkill: 10, skillToolName: 'load_skill'),
      );
      expect(text, contains('small'));
      expect(text, contains('short'));
      expect(text, contains('large'));
      expect(text, isNot(contains(largeContent)));
      expect(text, contains('skill content truncated for compaction'));
    });

    test('total token budget drops excess skills', () {
      final content = 'a' * 40;
      final messages = [
        _calls([
          _call('call_1', 'load_skill', '{"skill": "skill1"}'),
          _call('call_2', 'load_skill', '{"skill": "skill2"}'),
          _call('call_3', 'load_skill', '{"skill": "skill3"}'),
        ]),
        _result('call_1', content),
        _result('call_2', content),
        _result('call_3', content),
      ];
      final text = buildPreservedSkillsText(
        messages,
        const PreserveSkillsConfig(maxSkills: 10, skillsTokenBudget: 15, skillToolName: 'load_skill'),
      );
      expect(text, contains('skill3'));
      expect(text, isNot(contains('skill1')));
      expect(text, isNot(contains('skill2')));
    });

    test('token budget and per-skill limit combined', () {
      final messages = [
        _calls([
          _call('call_1', 'load_skill', '{"skill": "s1"}'),
          _call('call_2', 'load_skill', '{"skill": "s2"}'),
          _call('call_3', 'load_skill', '{"skill": "s3"}'),
          _call('call_4', 'load_skill', '{"skill": "s4"}'),
        ]),
        _result('call_1', 'a' * 16),
        _result('call_2', 'b' * 200),
        _result('call_3', 'c' * 24),
        _result('call_4', 'd' * 24),
      ];
      final text = buildPreservedSkillsText(
        messages,
        const PreserveSkillsConfig(
          maxSkills: 10,
          maxTokensPerSkill: 20,
          skillsTokenBudget: 30,
          skillToolName: 'load_skill',
        ),
      );
      expect(text, contains('s3'));
      expect(text, contains('s4'));
      expect(text, isNot(contains('"s1"')));
      expect(text, isNot(contains('"s2"')));
    });

    test('truncated skill content preserves only prefix', () {
      final content = 'abcdefghij' * 100;
      final truncated = truncateSkillContent(content, 125);
      expect(truncated.startsWith('abcdefghij'), isTrue);
      expect(truncated, contains('skill content truncated for compaction'));
      expect(truncated, isNot(content));
      expect(truncated.endsWith(']'), isTrue);
      expect(truncated.endsWith('abcdefghij]'), isFalse);
    });

    test('truncated multibyte content does not produce invalid utf8', () {
      final content = '中' * 334;
      final truncated = truncateSkillContent(content, 125);
      // Go's utf8.ValidString: no replacement character, and a UTF-8 round
      // trip gives the same string (no lone surrogate).
      expect(truncated, isNot(contains('�')));
      expect(utf8.decode(utf8.encode(truncated)), truncated);
      expect(truncated.startsWith('中中中'), isTrue);
      expect(truncated, contains('skill content truncated for compaction'));
    });
  });
}
