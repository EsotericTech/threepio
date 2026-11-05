// Ports of eino v0.9.22 `adk/chatmodel_retry_test.go`,
// `adk/failover_chatmodel_test.go` and `adk/wrappers_retry_failover_test.go`.
//
// From chatmodel_retry_test.go:
//   TestChatModelAgentRetry_NoTools_DirectError_Generate,
//   TestChatModelAgentRetry_NoTools_DirectError_Stream,
//   TestChatModelAgentRetry_StreamError,
//   TestChatModelAgentRetry_WithTools_DirectError_Generate,
//   TestChatModelAgentRetry_NonRetryableError,
//   TestChatModelAgentRetry_MaxRetriesExhausted,
//   TestChatModelAgentRetry_BackoffFunction,
//   TestChatModelAgentRetry_NoRetryConfig,
//   TestChatModelAgentRetry_WithTools_NonRetryAbleStreamError,
//   TestChatModelAgentRetry_NoTools_NonRetryAbleStreamError,
//   TestChatModelAgentRetry_DefaultIsRetryAble,
//   TestChatModelAgentRetry_ShouldRetry_RejectMessage_Stream,
//   TestShouldRetry_Generate, TestShouldRetry_Stream,
//   TestRejectReason_StreamPath, TestWillRetryError_RejectReason,
//   TestWillRetryError_Unwrap, TestDefaultBackoff.
// From failover_chatmodel_test.go:
//   TestFailoverModelWrapper_Generate, TestFailoverModelWrapper_Stream.
// From wrappers_retry_failover_test.go:
//   TestRetryThenFailover.
//
// Not portable (listed, not written):
// * TestFailoverModelWrapper_Generate/"delegates when GetFailoverModel nil":
//   `getFailoverModel` is a required, non-nullable parameter in Dart.
// * TestFailoverModelWrapper_{Generate,Stream}/"stops when GetFailoverModel
//   returns nil model" and TestRetryThenFailover/
//   Stream_GetFailoverModelReturnsNilModel: `getFailoverModel` returns a
//   non-nullable model in Dart, so "nil model" cannot be expressed.
//
// eino's deprecated `IsRetryAble` is not ported. Tests that used it only with
// errors it accepted port without it; tests that relied on it rejecting an
// error use an equivalent `shouldRetry` (commented where they do).
// Backoffs never wait on real time: Go's default backoff (100 ms and more) is
// replaced by an injected zero backoff, Go's `instantBackoff` (1 ms) is kept,
// and the two tests that measure a backoff run under `fake_async`.

import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/eino/agent_context.dart'
    show ChatModelAgentExecContext, withExecContext;
import 'package:threepio_core/src/adk/eino/model_failover.dart'
    show FailoverModel, FailoverProxyModel;
import 'package:threepio_core/src/adk/eino/model_retry.dart'
    show RetryModel, defaultBackoff;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A Go `errors.New` value: compared by identity.
class _Err implements Exception {
  _Err(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Go's `customError` (TestWillRetryError_Unwrap).
class _CustomError implements Exception {
  _CustomError(this.code, this.msg);

  final int code;
  final String msg;

  @override
  String toString() => msg;
}

final _errRetryAble = _Err('retry-able error');
final _errNonRetryAble = _Err('non-retry-able error');

Duration _zeroBackoff(RunContext _, int __) => Duration.zero;

// Go's `instantBackoff`.
Duration _instantBackoff(RunContext _, int __) =>
    const Duration(milliseconds: 1);

/// Go's `errors.Is(error, target)` for sentinel errors: [target] is [error]
/// or one of its causes.
bool _errorsIs(Object? error, Object target) {
  var current = error;
  for (var depth = 0; depth < 64 && current != null; depth++) {
    if (identical(current, target)) return true;
    current = current is ThreepioException ? current.cause : null;
  }
  return false;
}

bool _isWillRetry(Object? error) =>
    ThreepioException.findCause<WillRetryException>(error) != null;

bool _isExhausted(Object? error) =>
    ThreepioException.findCause<RetryExhaustedException>(error) != null;

/// The equivalent of `IsRetryAble: errors.Is(err, errRetryAble)`.
RetryDecision _retryOnlyRetryAble(RunContext _, RetryContext rc) =>
    RetryDecision(retry: rc.error != null && _errorsIs(rc.error, _errRetryAble));

typedef _GenerateFn = Future<Message> Function(
  List<Message> input,
  ChatModelOptions? options,
);
typedef _StreamFn = Future<StreamReader<Message>> Function(
  List<Message> input,
  ChatModelOptions? options,
);

/// Go's `mockModel.NewMockToolCallingChatModel`: a call without a scripted
/// answer fails like an unexpected gomock call.
class _MockModel extends ToolCallingChatModel {
  _MockModel({_GenerateFn? generate, _StreamFn? stream})
      : _generate = generate,
        _stream = stream;

  final _GenerateFn? _generate;
  final _StreamFn? _stream;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) {
    final fn = _generate;
    if (fn == null) throw StateError('unexpected call to Generate');
    return fn(input, options);
  }

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) {
    final fn = _stream;
    if (fn == null) throw StateError('unexpected call to Stream');
    return fn(input, options);
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) => this;
}

/// Go's `fakeChatModel` (failover tests), always with callbacks enabled.
class _FakeChatModel extends BaseChatModel implements CallbackAwareComponent {
  _FakeChatModel({_GenerateFn? generate, _StreamFn? stream})
      : _generate = generate ?? ((_, __) async => throw _Err('unused')),
        _stream = stream ?? ((_, __) async => throw _Err('unused'));

  final _GenerateFn _generate;
  final _StreamFn _stream;

  @override
  Future<Message> generate(List<Message> input, {ChatModelOptions? options}) =>
      _generate(input, options);

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) =>
      _stream(input, options);

  @override
  bool get isCallbacksEnabled => true;
}

/// Go's `fakeToolForTest`.
class _FakeTool extends InvokableTool {
  @override
  Future<ToolInfo> info() async => ToolInfo.fromParams(
        name: 'test_tool',
        desc: 'test tool for unit testing',
        params: const {
          'name': ParameterInfo(
            type: DataType.string,
            desc: 'user name for testing',
            required: true,
          ),
        },
      );

  @override
  Future<String> run(String argumentsJson) async => 'ok';
}

/// Go's `streamErrorModel`. Its `returnTool` (false in every ported test)
/// is left out.
class _StreamErrorModel extends ToolCallingChatModel {
  _StreamErrorModel({required this.failAtChunk, required this.maxFailures});

  final int failAtChunk;
  final int maxFailures;
  int callCount = 0;
  List<ToolInfo>? tools;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      Message.assistant('Generated');

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async {
    final count = ++callCount;
    Stream<Message> chunks() async* {
      for (var i = 0; i < 5; i++) {
        if (i == failAtChunk && count <= maxFailures) throw _errRetryAble;
        yield Message.assistant('chunk');
      }
    }

    return StreamReader.fromStream(chunks());
  }

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) {
    this.tools = tools;
    return this;
  }
}

/// Go's `nonRetryAbleStreamErrorModel`.
class _NonRetryAbleStreamErrorModel extends ToolCallingChatModel {
  List<ToolInfo>? tools;

  @override
  Future<Message> generate(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      Message.assistant('Generated');

  @override
  Future<StreamReader<Message>> stream(
    List<Message> input, {
    ChatModelOptions? options,
  }) async =>
      _streamOf([Message.assistant('chunk1')], error: _errNonRetryAble);

  @override
  ToolCallingChatModel withTools(List<ToolInfo> tools) {
    this.tools = tools;
    return this;
  }
}

/// Go's `schema.StreamReaderFromArray` and `streamWithMidError`: [chunks],
/// then [error] if given.
StreamReader<Message> _streamOf(List<Message> chunks, {Object? error}) {
  Stream<Message> emit() async* {
    for (final chunk in chunks) {
      yield chunk;
    }
    // ignore: only_throw_errors
    if (error != null) throw error;
  }

  return StreamReader.fromStream(emit());
}

/// Go's `agentEvent` of `drainStreamingAgentEvents`.
class _Drained {
  _Drained(this.event, this.streamContent);

  final AgentEvent event;
  final String streamContent;
}

/// Go's `drainStreamingAgentEvents`: every event, with the joined content of
/// its message stream, and what each stream ended with (`null` for EOF).
Future<(List<_Drained>, List<Object?>)> _drainStreaming(
  StreamReader<AgentEvent> events,
) async {
  final drained = <_Drained>[];
  final termErrors = <Object?>[];
  for (var event = await events.nextOrNull();
      event != null;
      event = await events.nextOrNull()) {
    var content = '';
    final variant = event.output?.messageOutput;
    final stream = variant?.messageStream;
    if (variant != null && variant.isStreaming && stream != null) {
      content = (await _readStream(stream, termErrors)).join();
    }
    drained.add(_Drained(event, content));
  }
  return (drained, termErrors);
}

/// Reads [stream] to its end; adds what it ended with to [ends] (`null` for
/// EOF) and returns the contents of its chunks.
Future<List<String>> _readStream(
  StreamReader<Message> stream,
  List<Object?> ends,
) async {
  final contents = <String>[];
  try {
    for (var chunk = await stream.nextOrNull();
        chunk != null;
        chunk = await stream.nextOrNull()) {
      contents.add(chunk.content);
    }
    ends.add(null);
    // The error a stream ends with is what the tests look at.
    // ignore: avoid_catches_without_on_clauses
  } catch (error) {
    ends.add(error);
  }
  return contents;
}

/// Go's `drainMessageStream`.
Future<(List<Message>, Object?)> _drainMessageStream(
  StreamReader<Message> stream,
) async {
  final out = <Message>[];
  try {
    for (var chunk = await stream.nextOrNull();
        chunk != null;
        chunk = await stream.nextOrNull()) {
      out.add(chunk);
    }
    return (out, null);
    // The error is part of the result.
    // ignore: avoid_catches_without_on_clauses
  } catch (error) {
    return (out, error);
  } finally {
    await stream.close();
  }
}

/// A call's value or what it threw (Go's `(value, err)`).
Future<(T?, Object?)> _result<T>(Future<T> call) async {
  try {
    return (await call, null);
    // Every failure is a result.
    // ignore: avoid_catches_without_on_clauses
  } catch (error) {
    return (null, error);
  }
}

ChatModelAgent _agent(
  BaseChatModel model, {
  required String name,
  required String description,
  ModelRetryConfig? retry,
  List<BaseTool> tools = const [],
}) =>
    ChatModelAgent(
      ChatModelAgentConfig(
        name: name,
        description: description,
        instruction: 'You are a helpful assistant.',
        model: model,
        toolsConfig: ToolsConfig(toolsNode: ToolsNodeConfig(tools: tools)),
        modelRetryConfig: retry,
      ),
    );

AgentInput _hello({bool streaming = false}) =>
    AgentInput(messages: [Message.user('Hello')], enableStreaming: streaming);

/// Go's `withTypedChatModelAgentExecCtx(ctx, &chatModelAgentExecCtx{
/// failoverLastSuccessModel: m})`, as call options.
ChatModelOptions _execOptions(
  BaseChatModel lastSuccess, {
  CancelToken? cancelToken,
}) {
  final (_, writer) = pipe<AgentEvent>();
  return ChatModelOptions(
    runContext: withExecContext(
      RunContext.background(cancelToken: cancelToken),
      ChatModelAgentExecContext(
        writer: writer,
        failoverLastSuccessModel: lastSuccess,
      ),
    ),
  );
}

/// Go's `buildModelWrappers(m1, &modelWrapperConfig{retryConfig,
/// failoverConfig})` called outside a graph. The Dart state wrapper reads and
/// writes the agent's graph state (Go ignores the error of `ProcessState`
/// there) and sends events whenever an exec context is present (Go only with
/// a generator), so the test builds the chain below it: failover → retry →
/// failover proxy.
BaseChatModel _retryThenFailover(
  ModelRetryConfig retry,
  ModelFailoverConfig failover,
) =>
    FailoverModel(RetryModel(FailoverProxyModel(), retry), failover);

final _hi = [Message.user('hi')];

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  test('TestChatModelAgentRetry_NoTools_DirectError_Generate', () async {
    var callCount = 0;
    final cm = _MockModel(
      generate: (_, __) async {
        callCount++;
        if (callCount < 3) throw _errRetryAble;
        return Message.assistant('Success after retry');
      },
    );
    final agent = _agent(
      cm,
      name: 'RetryTestAgent',
      description: 'Test agent for retry functionality',
      // IsRetryAble (not ported) accepted every error this model throws.
      retry: const ModelRetryConfig(maxRetries: 3, backoff: _zeroBackoff),
    );

    final iterator = agent.run(RunContext.background(), _hello());
    final event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(event.output, isNotNull);
    expect(event.output!.messageOutput!.message!.content, 'Success after retry');
    expect(await iterator.nextOrNull(), isNull);
    expect(callCount, 3);
  });

  test('TestChatModelAgentRetry_NoTools_DirectError_Stream', () async {
    var callCount = 0;
    final cm = _MockModel(
      stream: (_, __) async {
        callCount++;
        if (callCount < 2) throw _errRetryAble;
        return StreamReader.fromIterable([Message.assistant('Success')]);
      },
    );
    final agent = _agent(
      cm,
      name: 'RetryTestAgent',
      description: 'Test agent for retry functionality',
      // IsRetryAble (not ported) accepted every error this model throws.
      retry: const ModelRetryConfig(maxRetries: 3, backoff: _zeroBackoff),
    );

    final iterator =
        agent.run(RunContext.background(), _hello(streaming: true));
    final event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(event.output, isNotNull);
    expect(event.output!.messageOutput!.isStreaming, isTrue);
    expect(await iterator.nextOrNull(), isNull);
    expect(callCount, 2);
  });

  group('TestChatModelAgentRetry_StreamError', () {
    for (final withTools in [true, false]) {
      test(withTools ? 'WithTools' : 'NoTools', () async {
        final m = _StreamErrorModel(failAtChunk: 2, maxFailures: 2);
        final agent = _agent(
          m,
          name: 'RetryTestAgent',
          description: 'Test agent for retry functionality',
          // IsRetryAble (not ported) accepted every error this model throws.
          retry: const ModelRetryConfig(maxRetries: 3, backoff: _zeroBackoff),
          tools: withTools ? [_FakeTool()] : const [],
        );

        final events = await agent
            .run(RunContext.background(), _hello(streaming: true))
            .collectAll();
        expect(events, hasLength(3));

        final ends = <Object?>[];
        for (final event in events) {
          final variant = event.output?.messageOutput;
          if (variant != null && variant.isStreaming) {
            await _readStream(variant.messageStream!, ends);
          }
        }
        final errs = ends.whereType<Object>().toList();
        expect(errs, hasLength(2));
        expect(_isWillRetry(errs[0]), isTrue, reason: '${errs[0]}');
        expect(_isWillRetry(errs[1]), isTrue, reason: '${errs[1]}');
        expect(m.callCount, 3);
      });
    }
  });

  test('TestChatModelAgentRetry_WithTools_DirectError_Generate', () async {
    var callCount = 0;
    final cm = _MockModel(
      generate: (_, __) async {
        callCount++;
        if (callCount < 2) throw _errRetryAble;
        return Message.assistant('Success after retry');
      },
    );
    final agent = _agent(
      cm,
      name: 'RetryTestAgent',
      description: 'Test agent for retry functionality',
      tools: [_FakeTool()],
      // IsRetryAble (not ported) accepted every error this model throws.
      retry: const ModelRetryConfig(maxRetries: 3, backoff: _zeroBackoff),
    );

    final iterator = agent.run(RunContext.background(), _hello());
    final event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(event.output, isNotNull);
    expect(event.output!.messageOutput!.message!.content, 'Success after retry');
    expect(await iterator.nextOrNull(), isNull);
    expect(callCount, 2);
  });

  test('TestChatModelAgentRetry_NonRetryableError', () async {
    var callCount = 0;
    final cm = _MockModel(
      generate: (_, __) async {
        callCount++;
        throw _errNonRetryAble;
      },
    );
    final agent = _agent(
      cm,
      name: 'RetryTestAgent',
      description: 'Test agent for retry functionality',
      // IsRetryAble (not ported) rejected errNonRetryAble: the equivalent
      // shouldRetry retries errRetryAble only.
      retry: const ModelRetryConfig(
        maxRetries: 3,
        shouldRetry: _retryOnlyRetryAble,
        backoff: _zeroBackoff,
      ),
    );

    final iterator = agent.run(RunContext.background(), _hello());
    final event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNotNull);
    expect(_errorsIs(event.error, _errNonRetryAble), isTrue,
        reason: '${event.error}');
    expect(await iterator.nextOrNull(), isNull);
    expect(callCount, 1);
  });

  test('TestChatModelAgentRetry_MaxRetriesExhausted', () async {
    var callCount = 0;
    final cm = _MockModel(
      generate: (_, __) async {
        callCount++;
        throw _errRetryAble;
      },
    );
    final agent = _agent(
      cm,
      name: 'RetryTestAgent',
      description: 'Test agent for retry functionality',
      // IsRetryAble (not ported) accepted every error this model throws.
      retry: const ModelRetryConfig(maxRetries: 3, backoff: _zeroBackoff),
    );

    final iterator = agent.run(RunContext.background(), _hello());
    final event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNotNull);
    expect(_isExhausted(event.error), isTrue, reason: '${event.error}');
    final retryErr =
        ThreepioException.findCause<RetryExhaustedException>(event.error)!;
    expect(_errorsIs(retryErr.lastError, _errRetryAble), isTrue);
    expect(await iterator.nextOrNull(), isNull);
    expect(callCount, 4);
  });

  test('TestChatModelAgentRetry_BackoffFunction', () async {
    final backoffCalls = <int>[];
    var callCount = 0;
    final cm = _MockModel(
      generate: (_, __) async {
        callCount++;
        if (callCount < 3) throw _errRetryAble;
        return Message.assistant('Success');
      },
    );
    final agent = _agent(
      cm,
      name: 'RetryTestAgent',
      description: 'Test agent for retry functionality',
      // IsRetryAble (not ported) accepted every error this model throws.
      retry: ModelRetryConfig(
        maxRetries: 3,
        backoff: (_, attempt) {
          backoffCalls.add(attempt);
          return const Duration(milliseconds: 1);
        },
      ),
    );

    final iterator = agent.run(RunContext.background(), _hello());
    final event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(await iterator.nextOrNull(), isNull);
    expect(backoffCalls, [1, 2]);
    expect(callCount, 3);
  });

  test('TestChatModelAgentRetry_NoRetryConfig', () async {
    var callCount = 0;
    final cm = _MockModel(
      generate: (_, __) async {
        callCount++;
        throw _errRetryAble;
      },
    );
    final agent = _agent(
      cm,
      name: 'TestAgent',
      description: 'Test agent without retry config',
    );

    final iterator = agent.run(RunContext.background(), _hello());
    final event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNotNull);
    expect(_errorsIs(event.error, _errRetryAble), isTrue,
        reason: '${event.error}');
    expect(await iterator.nextOrNull(), isNull);
    expect(callCount, 1);
  });

  test('TestChatModelAgentRetry_WithTools_NonRetryAbleStreamError', () async {
    var callCount = 0;
    final cm = _MockModel(
      stream: (_, __) async {
        callCount++;
        throw _errNonRetryAble;
      },
    );
    final agent = _agent(
      cm,
      name: 'RetryTestAgent',
      description: 'Test agent for retry functionality',
      tools: [_FakeTool()],
      // IsRetryAble (not ported) rejected errNonRetryAble: the equivalent
      // shouldRetry retries errRetryAble only.
      retry: const ModelRetryConfig(
        maxRetries: 3,
        shouldRetry: _retryOnlyRetryAble,
        backoff: _zeroBackoff,
      ),
    );

    final iterator =
        agent.run(RunContext.background(), _hello(streaming: true));
    final event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNotNull);
    expect(_errorsIs(event.error, _errNonRetryAble), isTrue,
        reason: '${event.error}');
    expect(await iterator.nextOrNull(), isNull);
    expect(callCount, 1);
  });

  test('TestChatModelAgentRetry_NoTools_NonRetryAbleStreamError', () async {
    final m = _NonRetryAbleStreamErrorModel();
    final agent = _agent(
      m,
      name: 'RetryTestAgent',
      description: 'Test agent for retry functionality',
      // IsRetryAble (not ported) rejected errNonRetryAble: the equivalent
      // shouldRetry retries errRetryAble only.
      retry: const ModelRetryConfig(
        maxRetries: 3,
        shouldRetry: _retryOnlyRetryAble,
        backoff: _zeroBackoff,
      ),
    );

    final events = await agent
        .run(RunContext.background(), _hello(streaming: true))
        .collectAll();
    expect(events, hasLength(2));

    final event0 = events[0];
    expect(event0.output, isNotNull);
    expect(event0.output!.messageOutput, isNotNull);
    expect(event0.output!.messageOutput!.isStreaming, isTrue);
    final ends = <Object?>[];
    await _readStream(event0.output!.messageOutput!.messageStream!, ends);
    final streamErr = ends.single;
    expect(streamErr, isNotNull);
    expect(_errorsIs(streamErr, _errNonRetryAble), isTrue,
        reason: 'Stream error should be the original error, got $streamErr');

    final event1 = events[1];
    expect(event1.error, isNotNull);
    expect(_errorsIs(event1.error, _errNonRetryAble), isTrue,
        reason: '${event1.error}');
  });

  test('TestDefaultBackoff', () {
    final ctx = RunContext.background();
    const ms = Duration(milliseconds: 1);
    const s = Duration(seconds: 1);

    final d1 = defaultBackoff(ctx, 1);
    final d2 = defaultBackoff(ctx, 2);
    final d3 = defaultBackoff(ctx, 3);
    expect(d1 >= ms * 100 && d1 < ms * 150, isTrue,
        reason: 'First retry should be ~100ms + jitter (0-50ms), got $d1');
    expect(d2 >= ms * 200 && d2 < ms * 300, isTrue,
        reason: 'Second retry should be ~200ms + jitter (0-100ms), got $d2');
    expect(d3 >= ms * 400 && d3 < ms * 600, isTrue,
        reason: 'Third retry should be ~400ms + jitter (0-200ms), got $d3');

    final d10 = defaultBackoff(ctx, 10);
    expect(d10 >= s * 10 && d10 <= s * 15, isTrue,
        reason: 'Delay should be capped at 10s + jitter (0-5s), got $d10');

    final d100 = defaultBackoff(ctx, 100);
    expect(d100 >= s * 10 && d100 <= s * 15, isTrue,
        reason: 'Delay should still be capped at 10s + jitter for very high '
            'attempts, got $d100');
  });

  test('TestWillRetryError_Unwrap', () {
    final originalErr = _CustomError(500, 'internal error');
    final willRetry = WillRetryException(
      errorText: originalErr.toString(),
      retryAttempt: 1,
      cause: originalErr,
    );

    expect(_errorsIs(willRetry, originalErr), isTrue);

    final targetErr = ThreepioException.findCause<_CustomError>(willRetry);
    expect(targetErr, isNotNull);
    expect(targetErr!.code, 500);
    expect(targetErr.msg, 'internal error');
  });

  test('TestChatModelAgentRetry_DefaultIsRetryAble', () async {
    var callCount = 0;
    final cm = _MockModel(
      generate: (_, __) async {
        callCount++;
        if (callCount < 2) throw _Err('any error should be retried');
        return Message.assistant('Success');
      },
    );
    final agent = _agent(
      cm,
      name: 'RetryTestAgent',
      description: 'Test agent with default IsRetryAble',
      retry: const ModelRetryConfig(maxRetries: 3, backoff: _zeroBackoff),
    );

    final iterator = agent.run(RunContext.background(), _hello());
    final event = await iterator.nextOrNull();
    expect(event, isNotNull);
    expect(event!.error, isNull);
    expect(event.output!.messageOutput!.message!.content, 'Success');
    expect(await iterator.nextOrNull(), isNull);
    expect(callCount, 2);
  });

  test('TestChatModelAgentRetry_ShouldRetry_RejectMessage_Stream', () async {
    var callCount = 0;
    final cm = _MockModel(
      stream: (_, __) async {
        callCount++;
        return _streamOf([
          Message.assistant(
            callCount < 2 ? 'bad stream content' : 'good stream content',
          ),
        ]);
      },
    );
    final agent = _agent(
      cm,
      name: 'ShouldRetryStreamTestAgent',
      description: 'Test ShouldRetry message rejection in stream mode',
      retry: ModelRetryConfig(
        maxRetries: 3,
        shouldRetry: (_, rc) {
          if (rc.error != null) return const RetryDecision(retry: true);
          if (rc.outputMessage != null &&
              rc.outputMessage!.content.contains('bad')) {
            return const RetryDecision(retry: true);
          }
          return const RetryDecision();
        },
        backoff: _instantBackoff,
      ),
    );

    final (events, _) = await _drainStreaming(
      agent.run(RunContext.background(), _hello(streaming: true)),
    );
    expect(
      events.any((e) => e.streamContent == 'good stream content'),
      isTrue,
      reason: 'should have received good stream content',
    );
    expect(callCount, 2);
  });

  group('TestShouldRetry_Generate', () {
    test('RetryContext_Fields', () async {
      var callCount = 0;
      final cm = _MockModel(
        generate: (_, __) async {
          callCount++;
          return Message.assistant(callCount < 2 ? 'bad' : 'good');
        },
      );
      final captured = <RetryContext>[];
      final agent = _agent(
        cm,
        name: 'RetryContextFieldsAgent',
        description: 'Test that RetryContext fields are correctly populated',
        retry: ModelRetryConfig(
          maxRetries: 3,
          shouldRetry: (_, rc) {
            captured.add(rc);
            return RetryDecision(retry: rc.outputMessage?.content == 'bad');
          },
          backoff: _instantBackoff,
        ),
      );

      await agent.run(RunContext.background(), _hello()).collectAll();

      expect(captured, hasLength(2), reason: 'ShouldRetry should be called twice');
      expect(captured[0].retryAttempt, 1);
      expect(captured[0].inputMessages, hasLength(2));
      // Go: len(Options) > 0. The options are one object here.
      expect(captured[0].options, isNotNull, reason: 'should have default options');
      expect(captured[0].outputMessage!.content, 'bad');
      expect(captured[0].error, isNull);

      expect(captured[1].retryAttempt, 2);
      expect(captured[1].outputMessage!.content, 'good');
      expect(captured[1].error, isNull);
      expect(callCount, 2);
    });

    test('RewriteError_OnMessage', () async {
      var callCount = 0;
      final cm = _MockModel(
        generate: (_, __) async {
          callCount++;
          return Message.assistant('unrecoverable bad message');
        },
      );
      final fatalErr = _Err('fatal: unrecoverable model output');
      final agent = _agent(
        cm,
        name: 'RewriteErrorTestAgent',
        description: 'Test ShouldRetry RewriteError on message',
        retry: ModelRetryConfig(
          maxRetries: 2,
          shouldRetry: (_, rc) {
            if (rc.outputMessage != null &&
                rc.outputMessage!.content.contains('unrecoverable')) {
              return RetryDecision(rewriteError: fatalErr);
            }
            return const RetryDecision();
          },
          backoff: _instantBackoff,
        ),
      );

      final events =
          await agent.run(RunContext.background(), _hello()).collectAll();
      expect(events, isNotEmpty);
      expect(
        events.any((e) => _errorsIs(e.error, fatalErr)),
        isTrue,
        reason: 'should have received the fatal rewrite error',
      );
      expect(callCount, 1);
    });

    test('RewriteError_OnError', () async {
      final origErr = _Err('original transient error');
      var callCount = 0;
      final cm = _MockModel(
        generate: (_, __) async {
          callCount++;
          throw origErr;
        },
      );
      final wrappedErr =
          _Err('wrapped: original transient error with more context');
      final agent = _agent(
        cm,
        name: 'RewriteErrorOnErrorTestAgent',
        description: 'Test ShouldRetry RewriteError replacing original error',
        retry: ModelRetryConfig(
          maxRetries: 2,
          shouldRetry: (_, rc) => rc.error != null
              ? RetryDecision(rewriteError: wrappedErr)
              : const RetryDecision(),
          backoff: _instantBackoff,
        ),
      );

      final events =
          await agent.run(RunContext.background(), _hello()).collectAll();
      expect(events, isNotEmpty);
      expect(
        events.any((e) => _errorsIs(e.error, wrappedErr)),
        isTrue,
        reason: 'should have received the wrapped rewrite error',
      );
      expect(callCount, 1);
    });

    test('AdditionalOptions', () async {
      var callCount = 0;
      final capturedOpts = <ChatModelOptions?>[];
      final cm = _MockModel(
        generate: (_, options) async {
          callCount++;
          capturedOpts.add(options);
          if (callCount < 2) throw _errRetryAble;
          return Message.assistant('success');
        },
      );
      final agent = _agent(
        cm,
        name: 'AdditionalOptionsTestAgent',
        description: 'Test ShouldRetry AdditionalOptions',
        retry: ModelRetryConfig(
          maxRetries: 3,
          shouldRetry: (_, rc) => rc.error != null
              ? const RetryDecision(
                  retry: true,
                  additionalOptions: ChatModelOptions(maxTokens: 8192),
                )
              : const RetryDecision(),
          backoff: _instantBackoff,
        ),
      );

      final event =
          await agent.run(RunContext.background(), _hello()).nextOrNull();
      expect(event, isNotNull);
      expect(event!.error, isNull);
      expect(callCount, 2);
      expect(capturedOpts, hasLength(2));
      // Go: len(opts[1]) == len(opts[0]) + 1 (the option is appended). The
      // options are one object here: the second call carries the added
      // option, the first does not.
      expect(capturedOpts[0]?.maxTokens, isNull);
      expect(capturedOpts[1]?.maxTokens, 8192);
    });

    test('ModifiedInputMessages_NoPersist', () async {
      var callCount = 0;
      final capturedInputs = <List<Message>>[];
      final cm = _MockModel(
        generate: (input, _) async {
          callCount++;
          capturedInputs.add(List.of(input));
          if (callCount < 2) throw _errRetryAble;
          return Message.assistant('success');
        },
      );
      final agent = _agent(
        cm,
        name: 'ModifiedInputNoPersistAgent',
        description:
            'Test ShouldRetry ModifiedInputMessages without persistence',
        retry: ModelRetryConfig(
          maxRetries: 3,
          shouldRetry: (_, rc) => rc.error != null
              ? RetryDecision(
                  retry: true,
                  modifiedInputMessages: [
                    Message.system('compressed instruction'),
                    Message.user('Hello'),
                  ],
                )
              : const RetryDecision(),
          backoff: _instantBackoff,
        ),
      );

      final event =
          await agent.run(RunContext.background(), _hello()).nextOrNull();
      expect(event, isNotNull);
      expect(event!.error, isNull);
      expect(callCount, 2);
      expect(capturedInputs, hasLength(2));
      expect(capturedInputs[1][0].content, 'compressed instruction',
          reason: 'second call should use modified input');
    });

    // Go measures the wall time (>= 50 ms, < 250 ms); here fake time.
    test('Backoff', () {
      fakeAsync((async) {
        var callCount = 0;
        final cm = _MockModel(
          generate: (_, __) async {
            callCount++;
            if (callCount < 2) throw _errRetryAble;
            return Message.assistant('success');
          },
        );
        const customBackoff = Duration(milliseconds: 50);
        final agent = _agent(
          cm,
          name: 'BackoffTestAgent',
          description: 'Test ShouldRetry custom Backoff in decision',
          retry: ModelRetryConfig(
            maxRetries: 3,
            shouldRetry: (_, rc) => rc.error != null
                ? const RetryDecision(retry: true, backoff: customBackoff)
                : const RetryDecision(),
          ),
        );

        AgentEvent? event;
        var done = false;
        unawaited(
          agent.run(RunContext.background(), _hello()).nextOrNull().then((e) {
            event = e;
            done = true;
          }),
        );

        async.elapse(customBackoff - const Duration(milliseconds: 1));
        expect(done, isFalse, reason: 'expected backoff ~$customBackoff');
        expect(callCount, 1);

        async.elapse(const Duration(milliseconds: 200));
        expect(done, isTrue, reason: 'expected backoff ~$customBackoff');
        expect(event, isNotNull);
        expect(event!.error, isNull);
        expect(callCount, 2);
      });
    });

    test('SuppressFlag_Rejected_NoEvent', () async {
      var callCount = 0;
      final cm = _MockModel(
        generate: (_, __) async {
          callCount++;
          return Message.assistant(callCount == 1 ? 'bad' : 'good');
        },
      );
      final agent = _agent(
        cm,
        name: 'SuppressRejected',
        description: 'Test suppress flag rejects first then accepts',
        retry: ModelRetryConfig(
          maxRetries: 1,
          shouldRetry: (_, rc) =>
              RetryDecision(retry: rc.outputMessage?.content == 'bad'),
          backoff: _instantBackoff,
        ),
      );

      final events =
          await agent.run(RunContext.background(), _hello()).collectAll();
      final msgEvents =
          events.where((e) => e.output?.messageOutput != null).toList();
      expect(msgEvents, hasLength(1),
          reason: 'should have exactly 1 message event (suppressed rejected)');
      expect(msgEvents[0].output!.messageOutput!.message!.content, 'good');
      expect(callCount, 2);
    });

    test('SuppressFlag_AllRejected_NoEvents', () async {
      var callCount = 0;
      final cm = _MockModel(
        generate: (_, __) async {
          callCount++;
          return Message.assistant('always bad');
        },
      );
      final agent = _agent(
        cm,
        name: 'SuppressAllRejected',
        description: 'Test suppress flag all rejected no events',
        retry: ModelRetryConfig(
          maxRetries: 2,
          shouldRetry: (_, __) => const RetryDecision(retry: true),
          backoff: _instantBackoff,
        ),
      );

      final events =
          await agent.run(RunContext.background(), _hello()).collectAll();
      final msgEventCount =
          events.where((e) => e.output?.messageOutput != null).length;
      expect(msgEventCount, 0,
          reason: 'no message events should be emitted when all are rejected');
      expect(events.any((e) => _isExhausted(e.error)), isTrue,
          reason: 'final event should have RetryExhaustedError');
      expect(callCount, 3);
    });

    test('SuppressFlag_Accepted_FirstAttempt', () async {
      var callCount = 0;
      final cm = _MockModel(
        generate: (_, __) async {
          callCount++;
          return Message.assistant('perfect');
        },
      );
      final agent = _agent(
        cm,
        name: 'SuppressAcceptedFirst',
        description: 'Test suppress flag accepted first attempt',
        retry: ModelRetryConfig(
          maxRetries: 2,
          shouldRetry: (_, __) => const RetryDecision(),
          backoff: _instantBackoff,
        ),
      );

      final events =
          await agent.run(RunContext.background(), _hello()).collectAll();
      final msgEvents =
          events.where((e) => e.output?.messageOutput != null).toList();
      expect(msgEvents, hasLength(1), reason: 'should have exactly 1 event');
      expect(msgEvents[0].output!.messageOutput!.message!.content, 'perfect');
      expect(callCount, 1);
    });

    // Go cancels after 50 ms of wall time and requires the run to end within
    // 2 s despite a 10 s backoff; here fake time. Go's context.Canceled is a
    // CancelledException.
    test('ContextCanceled_DuringSleep', () {
      fakeAsync((async) {
        final token = CancelToken();
        var callCount = 0;
        final cm = _MockModel(
          generate: (_, __) async {
            callCount++;
            throw _Err('transient');
          },
        );
        final agent = _agent(
          cm,
          name: 'ContextCancelDuringSleep',
          description: 'Test context cancellation during backoff sleep',
          retry: ModelRetryConfig(
            maxRetries: 5,
            shouldRetry: (_, __) => const RetryDecision(retry: true),
            backoff: (_, __) => const Duration(seconds: 10),
          ),
        );

        List<AgentEvent>? events;
        unawaited(
          agent
              .run(RunContext.background(cancelToken: token), _hello())
              .collectAll()
              .then((e) => events = e),
        );

        async.elapse(const Duration(milliseconds: 50));
        token.cancel();
        async.elapse(const Duration(milliseconds: 1949));

        expect(events, isNotNull,
            reason: 'should not block for full backoff');
        expect(callCount, 1);
        expect(
          events!.any(
            (e) =>
                ThreepioException.findCause<CancelledException>(e.error) !=
                null,
          ),
          isTrue,
          reason: 'should have received context.Canceled error, got '
              '${events!.map((e) => e.error).toList()}',
        );
      });
    });
  });

  group('TestShouldRetry_Stream', () {
    test('ErrorRetry', () async {
      final streamErr = _Err('stream unavailable');
      var callCount = 0;
      final cm = _MockModel(
        stream: (_, __) async {
          callCount++;
          if (callCount < 2) throw streamErr;
          return _streamOf([Message.assistant('recovered stream')]);
        },
      );
      final agent = _agent(
        cm,
        name: 'StreamErrorRetryAgent',
        description: 'Test ShouldRetry when Stream returns error (nil stream)',
        retry: ModelRetryConfig(
          maxRetries: 3,
          shouldRetry: (_, rc) => RetryDecision(retry: rc.error != null),
          backoff: _instantBackoff,
        ),
      );

      final (events, _) = await _drainStreaming(
        agent.run(RunContext.background(), _hello(streaming: true)),
      );
      expect(
        events.any((e) => e.streamContent == 'recovered stream'),
        isTrue,
        reason: 'should have received recovered stream content after error '
            'retry',
      );
      expect(callCount, 2);
    });

    test('ErrorRewrite', () async {
      final streamErr = _Err('model overloaded');
      var callCount = 0;
      final cm = _MockModel(
        stream: (_, __) async {
          callCount++;
          throw streamErr;
        },
      );
      final fatalErr = _Err('fatal: model overloaded, aborting');
      final agent = _agent(
        cm,
        name: 'StreamErrorRewriteAgent',
        description: 'Test ShouldRetry RewriteError when Stream returns error',
        retry: ModelRetryConfig(
          maxRetries: 2,
          shouldRetry: (_, rc) =>
              rc.error != null && '${rc.error}'.contains('overloaded')
                  ? RetryDecision(rewriteError: fatalErr)
                  : const RetryDecision(),
          backoff: _instantBackoff,
        ),
      );

      final events = await agent
          .run(RunContext.background(), _hello(streaming: true))
          .collectAll();
      expect(events, isNotEmpty);
      expect(
        events.any((e) => _errorsIs(e.error, fatalErr)),
        isTrue,
        reason: 'should have received the fatal rewrite error from stream',
      );
      expect(callCount, 1);
    });

    test('RewriteError_OnMessage', () async {
      var callCount = 0;
      final cm = _MockModel(
        stream: (_, __) async {
          callCount++;
          return _streamOf([Message.assistant('hallucinated garbage output')]);
        },
      );
      final fatalErr = _Err('fatal: hallucinated output detected');
      final agent = _agent(
        cm,
        name: 'StreamRewriteOnMessageAgent',
        description:
            'Test ShouldRetry RewriteError on successful stream with bad content',
        retry: ModelRetryConfig(
          maxRetries: 2,
          shouldRetry: (_, rc) => rc.outputMessage != null &&
                  rc.outputMessage!.content.contains('hallucinated')
              ? RetryDecision(rewriteError: fatalErr)
              : const RetryDecision(),
          backoff: _instantBackoff,
        ),
      );

      final events = await agent
          .run(RunContext.background(), _hello(streaming: true))
          .collectAll();
      expect(events, isNotEmpty);
      expect(
        events.any((e) => _errorsIs(e.error, fatalErr)),
        isTrue,
        reason: 'should have received fatal rewrite error from stream message '
            'inspection',
      );
      expect(callCount, 1);
    });

    test('PartialStreamError', () async {
      final partialErr = _Err('connection reset mid-stream');
      var callCount = 0;
      final cm = _MockModel(
        stream: (_, __) async {
          callCount++;
          return callCount < 2
              ? _streamOf([Message.assistant('partial chunk')], error: partialErr)
              : _streamOf([
                  Message.assistant('partial chunk'),
                  Message.assistant(' complete'),
                ]);
        },
      );
      final captured = <RetryContext>[];
      final agent = _agent(
        cm,
        name: 'StreamPartialErrorAgent',
        description:
            'Test ShouldRetry when stream has partial content then error',
        retry: ModelRetryConfig(
          maxRetries: 3,
          shouldRetry: (_, rc) {
            captured.add(rc);
            return RetryDecision(retry: rc.error != null);
          },
          backoff: _instantBackoff,
        ),
      );

      await _drainStreaming(
        agent.run(RunContext.background(), _hello(streaming: true)),
      );

      expect(callCount, 2);
      expect(captured, hasLength(2));
      expect(captured[0].error, isNotNull,
          reason: 'first attempt should have stream error');
      expect(captured[0].outputMessage, isNotNull,
          reason: 'first attempt should have partial message despite error');
      expect(captured[0].outputMessage!.content, 'partial chunk');
    });

    test('ModifiedInputsAndOptions_WithPersist', () async {
      var callCount = 0;
      final capturedInputs = <List<Message>>[];
      final capturedOpts = <ChatModelOptions?>[];
      final cm = _MockModel(
        stream: (input, options) async {
          callCount++;
          capturedInputs.add(List.of(input));
          capturedOpts.add(options);
          return _streamOf([
            Message.assistant(
              callCount < 2 ? 'too long response exceeds limit' : 'good response',
            ),
          ]);
        },
      );
      final agent = _agent(
        cm,
        name: 'StreamModifiedInputsPersistAgent',
        description: 'Test ShouldRetry with ModifiedInputMessages (persist) '
            'and AdditionalOptions in stream mode',
        retry: ModelRetryConfig(
          maxRetries: 3,
          shouldRetry: (_, rc) {
            if (rc.outputMessage != null &&
                rc.outputMessage!.content.contains('too long')) {
              return RetryDecision(
                retry: true,
                modifiedInputMessages: [
                  Message.system('compressed instruction'),
                  Message.user('summarized history'),
                ],
                persistModifiedInputMessages: true,
                additionalOptions: const ChatModelOptions(maxTokens: 16384),
              );
            }
            return const RetryDecision();
          },
          backoff: _instantBackoff,
        ),
      );

      final (events, _) = await _drainStreaming(
        agent.run(RunContext.background(), _hello(streaming: true)),
      );
      expect(
        events.any((e) => e.streamContent == 'good response'),
        isTrue,
        reason: 'should have received good response after retry with '
            'modified inputs',
      );
      expect(callCount, 2);
      expect(capturedInputs, hasLength(2));
      expect(capturedInputs[1][0].content, 'compressed instruction',
          reason: 'second call should use modified input');
      expect(capturedInputs[1][1].content, 'summarized history');
      // Go: len(opts[1]) == len(opts[0]) + 1. The options are one object
      // here: the second call carries the added option, the first does not.
      expect(capturedOpts[0]?.maxTokens, isNull);
      expect(capturedOpts[1]?.maxTokens, 16384);
    });

    test('VerdictSignal_CleanStream_Rejected', () async {
      var callCount = 0;
      final cm = _MockModel(
        stream: (_, __) async {
          callCount++;
          return StreamReader.fromIterable(
            [Message.assistant(callCount == 1 ? 'bad' : 'good')],
          );
        },
      );
      final agent = _agent(
        cm,
        name: 'VerdictCleanRejected',
        description: 'Test verdict signal on clean stream rejected',
        retry: ModelRetryConfig(
          maxRetries: 1,
          shouldRetry: (_, rc) =>
              RetryDecision(retry: rc.outputMessage?.content == 'bad'),
          backoff: _instantBackoff,
        ),
      );

      final (_, ends) = await _drainStreaming(
        agent.run(RunContext.background(), _hello(streaming: true)),
      );
      expect(ends, hasLength(2), reason: 'should have exactly 2 stream events');
      expect(_isWillRetry(ends[0]), isTrue,
          reason: 'first stream should end with WillRetryError, got '
              '${ends[0]}');
      expect(ends[1], isNull, reason: 'second stream should end with io.EOF');
      expect(callCount, 2);
    });

    test('VerdictSignal_StreamError_Rejected', () async {
      final streamErr = _Err('mid-stream error');
      var callCount = 0;
      final cm = _MockModel(
        stream: (_, __) async {
          callCount++;
          if (callCount == 1) {
            return _streamOf([Message.assistant('partial')], error: streamErr);
          }
          return StreamReader.fromIterable([Message.assistant('good')]);
        },
      );
      final agent = _agent(
        cm,
        name: 'VerdictStreamErrorRejected',
        description: 'Test verdict signal on stream error rejected',
        retry: ModelRetryConfig(
          maxRetries: 1,
          shouldRetry: (_, rc) => RetryDecision(retry: rc.error != null),
          backoff: _instantBackoff,
        ),
      );

      final (_, ends) = await _drainStreaming(
        agent.run(RunContext.background(), _hello(streaming: true)),
      );
      expect(ends, isNotEmpty);
      expect(_isWillRetry(ends[0]), isTrue,
          reason: 'first event stream should end with WillRetryError via '
              'errWrapper path, got ${ends[0]}');
      expect(ends, hasLength(2), reason: 'should have 2 stream events');
      expect(callCount, 2);
    });

    test('VerdictSignal_Accepted_FirstAttempt', () async {
      var callCount = 0;
      final cm = _MockModel(
        stream: (_, __) async {
          callCount++;
          return StreamReader.fromIterable([Message.assistant('perfect')]);
        },
      );
      final agent = _agent(
        cm,
        name: 'VerdictAcceptedFirst',
        description: 'Test verdict signal accepted first attempt',
        retry: ModelRetryConfig(
          maxRetries: 2,
          shouldRetry: (_, __) => const RetryDecision(),
          backoff: _instantBackoff,
        ),
      );

      final (_, ends) = await _drainStreaming(
        agent.run(RunContext.background(), _hello(streaming: true)),
      );
      expect(ends, hasLength(1), reason: 'should have exactly 1 event');
      expect(ends.single, isNull,
          reason: 'accepted stream should end with io.EOF');
      expect(callCount, 1);
    });

    test('VerdictSignal_AllRejected_Exhausted', () async {
      var callCount = 0;
      final cm = _MockModel(
        stream: (_, __) async {
          callCount++;
          return StreamReader.fromIterable([Message.assistant('always bad')]);
        },
      );
      final agent = _agent(
        cm,
        name: 'VerdictAllRejected',
        description: 'Test verdict signal all rejected exhausted',
        retry: ModelRetryConfig(
          maxRetries: 2,
          shouldRetry: (_, __) => const RetryDecision(retry: true),
          backoff: _instantBackoff,
        ),
      );

      final (events, ends) = await _drainStreaming(
        agent.run(RunContext.background(), _hello(streaming: true)),
      );
      final willRetryCount = ends.where(_isWillRetry).length;
      expect(willRetryCount, 3,
          reason: 'all 3 stream events should end with WillRetryError');
      expect(events.any((e) => _isExhausted(e.event.error)), isTrue,
          reason: 'final error should be RetryExhaustedError');
      expect(callCount, 3);
    });

    // Go's panic in ShouldRetry is a throw here; the run must still end (a
    // deadlock fails on the test timeout) with the error, whose text carries
    // the word "panic" as Go's does.
    test('ShouldRetry_Panics_VerdictStillSent', () async {
      var callCount = 0;
      final cm = _MockModel(
        stream: (_, __) async {
          callCount++;
          return StreamReader.fromIterable([Message.assistant('trigger panic')]);
        },
      );
      final agent = _agent(
        cm,
        name: 'ShouldRetryPanicsAgent',
        description: 'Test that ShouldRetry panic sends verdict signal and '
            'does not deadlock',
        retry: ModelRetryConfig(
          maxRetries: 1,
          shouldRetry: (_, __) =>
              throw StateError('deliberate panic in ShouldRetry'),
          backoff: _instantBackoff,
        ),
      );

      final events = await agent
          .run(RunContext.background(), _hello(streaming: true))
          .collectAll();
      expect(events, isNotEmpty);
      expect(
        events.any((e) => e.error != null && '${e.error}'.contains('panic')),
        isTrue,
        reason: 'should have received a panic error event',
      );
      expect(callCount, 1);
    });
  });

  test('TestRejectReason_StreamPath', () async {
    final streamErr = _Err('bad output');
    var streamCallCount = 0;
    final m = _MockModel(
      stream: (_, __) async {
        streamCallCount++;
        if (streamCallCount == 1) {
          return _streamOf(
            [Message.assistant('rejected chunk')],
            error: streamErr,
          );
        }
        return _streamOf([Message.assistant('accepted')]);
      },
    );
    final agent = ChatModelAgent(
      ChatModelAgentConfig(
        name: 'reject-reason-agent',
        description: 'test reject reason',
        instruction: 'test',
        model: m,
        modelRetryConfig: ModelRetryConfig(
          maxRetries: 1,
          shouldRetry: (_, rc) {
            if (rc.error != null) {
              return RetryDecision(
                retry: true,
                rejectReason: _RejectInfo('output quality too low', rc.retryAttempt),
              );
            }
            return null;
          },
          backoff: _instantBackoff,
        ),
      ),
    );

    // Go calls initRunCtx first; agent.run sets up its run context itself.
    final iter = agent.run(
      RunContext.background(),
      AgentInput(messages: [Message.user('hello')], enableStreaming: true),
    );

    final capturedRejectReasons = <Object?>[];
    var finalContent = '';
    for (var ev = await iter.nextOrNull(); ev != null; ev = await iter.nextOrNull()) {
      if (ev.error != null) continue;
      final variant = ev.output?.messageOutput;
      if (variant != null && variant.isStreaming) {
        final sr = variant.messageStream!;
        try {
          for (var chunk = await sr.nextOrNull();
              chunk != null;
              chunk = await sr.nextOrNull()) {
            finalContent = chunk.content;
          }
          // Only a WillRetryException is looked at.
          // ignore: avoid_catches_without_on_clauses
        } catch (error) {
          final willRetry =
              ThreepioException.findCause<WillRetryException>(error);
          if (willRetry != null) capturedRejectReasons.add(willRetry.rejectReason);
        }
      }
    }

    expect(finalContent, contains('accepted'));
    expect(capturedRejectReasons, isNotEmpty,
        reason: 'should have at least one WillRetryError with RejectReason '
            'from stream Recv()');
    for (final reason in capturedRejectReasons) {
      expect(reason, isNotNull);
      expect(reason, isA<_RejectInfo>(),
          reason: 'RejectReason should be rejectInfo type, got '
              '${reason.runtimeType}');
      final ri = reason! as _RejectInfo;
      expect(ri.reason, 'output quality too low');
      expect(ri.attempt, 1);
    }
  });

  group('TestWillRetryError_RejectReason', () {
    test('nil when not set', () {
      final wrErr = WillRetryException(
        errorText: 'test',
        retryAttempt: 1,
        cause: _Err('test'),
      );
      expect(wrErr.rejectReason, isNull,
          reason: 'RejectReason should be nil when not set');
    });

    test('returns value when set', () {
      final reason = {'key': 'value'};
      final wrErr = WillRetryException(
        errorText: 'rejected',
        retryAttempt: 2,
        rejectReason: reason,
        cause: _Err('inner'),
      );
      expect(wrErr.rejectReason, reason);
      expect(wrErr.toString(), 'rejected');
      expect(wrErr.retryAttempt, 2);
    });
  });

  group('TestFailoverModelWrapper_Generate', () {
    test('failover to second model', () async {
      final wantErr = _Err('first failed');
      var shouldCalls = 0;
      var m1Calls = 0;
      var m2Calls = 0;
      final attempts = <int>[];

      final m1 = _FakeChatModel(
        generate: (_, __) async {
          m1Calls++;
          throw wantErr;
        },
      );
      final m2 = _FakeChatModel(
        generate: (_, __) async {
          m2Calls++;
          return Message.assistant('ok');
        },
      );

      final cfg = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, __, err) {
          shouldCalls++;
          return _errorsIs(err, wantErr);
        },
        getFailoverModel: (_, failoverCtx) {
          attempts.add(failoverCtx.failoverAttempt);
          return (m2, null);
        },
      );

      final w = FailoverModel(FailoverProxyModel(), cfg);
      final (msg, err) =
          await _result(w.generate(_hi, options: _execOptions(m1)));
      expect(err, isNull);
      expect(msg!.content, 'ok');
      expect(attempts, [1]);
      expect(m1Calls, 1);
      expect(m2Calls, 1);
      expect(shouldCalls, 1);
    });

    // Go's context.Canceled returned by the model is a CancelledException.
    test('canceled error delegates to ShouldFailover', () async {
      var shouldCalls = 0;
      final m1 = _FakeChatModel(
        generate: (_, __) async => throw const CancelledException(),
      );

      final cfg = ModelFailoverConfig(
        maxRetries: 5,
        shouldFailover: (_, __, err) {
          shouldCalls++;
          // User decides to stop on canceled error
          return ThreepioException.findCause<CancelledException>(err) == null;
        },
        getFailoverModel: (_, __) => (m1, null),
      );

      final w = FailoverModel(FailoverProxyModel(), cfg);
      final (_, err) = await _result(w.generate(_hi, options: _execOptions(m1)));
      expect(ThreepioException.findCause<CancelledException>(err), isNotNull,
          reason: '$err');
      // ShouldFailover is called once and returns false, stopping failover
      expect(shouldCalls, 1);
    });

    // Go returns the error from GetFailoverModel; here it throws.
    test('stops when GetFailoverModel returns error', () async {
      final wantErr = _Err('get model failed');
      var called = 0;
      final inner = _FakeChatModel(
        generate: (_, __) async {
          called++;
          return Message.assistant('unused');
        },
      );

      final cfg = ModelFailoverConfig(
        maxRetries: 3,
        shouldFailover: (_, __, ___) => true,
        getFailoverModel: (_, __) => throw wantErr,
      );

      final w = FailoverModel(inner, cfg);
      final (_, err) = await _result(w.generate(_hi));
      expect(_errorsIs(err, wantErr), isTrue, reason: '$err');
      expect(called, 0);
    });
  });

  group('TestFailoverModelWrapper_Stream', () {
    test('returns stream when first attempt succeeds', () async {
      var shouldCalls = 0;
      final inMsg = Message.user('hi');
      final sameInput = <bool>[];

      final m1 = _FakeChatModel(
        stream: (input, _) async {
          sameInput.add(input.length == 1 && identical(input[0], inMsg));
          return StreamReader.fromIterable(
            [Message.assistant('a'), Message.assistant('b')],
          );
        },
      );

      final cfg = ModelFailoverConfig(
        shouldFailover: (_, __, ___) {
          shouldCalls++;
          return false;
        },
        getFailoverModel: (_, __) => (m1, null),
      );

      final w = FailoverModel(FailoverProxyModel(), cfg);
      final (sr, err) =
          await _result(w.stream([inMsg], options: _execOptions(m1)));
      expect(err, isNull);
      final (msgs, drainErr) = await _drainMessageStream(sr!);
      expect(drainErr, isNull);
      expect(msgs, hasLength(2));
      expect(msgs[0].content, 'a');
      expect(msgs[1].content, 'b');
      expect(sameInput, [true]);
      expect(shouldCalls, 0);
    });

    test('failover when Stream returns error immediately', () async {
      final wantErr = _Err('stream init failed');
      var shouldCalls = 0;
      var m1Calls = 0;
      var m2Calls = 0;
      final attempts = <int>[];

      final m1 = _FakeChatModel(
        stream: (_, __) async {
          m1Calls++;
          throw wantErr;
        },
      );
      final m2 = _FakeChatModel(
        stream: (_, __) async {
          m2Calls++;
          return StreamReader.fromIterable([Message.assistant('ok')]);
        },
      );

      final cfg = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, __, err) {
          shouldCalls++;
          return _errorsIs(err, wantErr);
        },
        getFailoverModel: (_, failoverCtx) {
          attempts.add(failoverCtx.failoverAttempt);
          return (m2, null);
        },
      );

      final w = FailoverModel(FailoverProxyModel(), cfg);
      final (sr, err) = await _result(w.stream(_hi, options: _execOptions(m1)));
      expect(err, isNull);
      final (msgs, drainErr) = await _drainMessageStream(sr!);
      expect(drainErr, isNull);
      expect(msgs, hasLength(1));
      expect(msgs[0].content, 'ok');
      expect(attempts, [1]);
      expect(m1Calls, 1);
      expect(m2Calls, 1);
      expect(shouldCalls, 1);
    });

    test('failover when stream errors mid-way', () async {
      final streamErr = _Err('mid error');
      var shouldCalls = 0;
      String? seenOutput;
      var m1Calls = 0;
      var m2Calls = 0;
      final attempts = <int>[];

      final m1 = _FakeChatModel(
        stream: (_, __) async {
          m1Calls++;
          return _streamOf(
            [Message.assistant('p1'), Message.assistant('p2')],
            error: streamErr,
          );
        },
      );
      final m2 = _FakeChatModel(
        stream: (_, __) async {
          m2Calls++;
          return StreamReader.fromIterable([Message.assistant('final')]);
        },
      );

      final cfg = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, out, err) {
          shouldCalls++;
          if (_errorsIs(err, streamErr) && out != null) {
            seenOutput = out.content;
          }
          return _errorsIs(err, streamErr);
        },
        getFailoverModel: (_, failoverCtx) {
          attempts.add(failoverCtx.failoverAttempt);
          return (m2, null);
        },
      );

      final w = FailoverModel(FailoverProxyModel(), cfg);
      final (sr, err) = await _result(w.stream(_hi, options: _execOptions(m1)));
      expect(err, isNull);
      final (msgs, drainErr) = await _drainMessageStream(sr!);
      expect(drainErr, isNull);
      expect(msgs, hasLength(1));
      expect(msgs[0].content, 'final');
      expect(seenOutput, 'p1p2');
      expect(attempts, [1]);
      expect(m1Calls, 1);
      expect(m2Calls, 1);
      expect(shouldCalls, 1);
    });

    test('stop when ShouldFailover returns false for mid-way error', () async {
      final streamErr = _Err('mid error');
      final m1 = _FakeChatModel(
        stream: (_, __) async =>
            _streamOf([Message.assistant('p')], error: streamErr),
      );

      final cfg = ModelFailoverConfig(
        maxRetries: 3,
        shouldFailover: (_, __, ___) => false,
        getFailoverModel: (_, __) => (m1, null),
      );

      final w = FailoverModel(FailoverProxyModel(), cfg);
      final (sr, err) = await _result(w.stream(_hi, options: _execOptions(m1)));
      expect(sr, isNull);
      expect(_errorsIs(err, streamErr), isTrue, reason: '$err');
    });

    // Go's context.Canceled in the stream is a CancelledException.
    test('canceled mid-way error delegates to ShouldFailover', () async {
      var shouldCalls = 0;
      final m1 = _FakeChatModel(
        stream: (_, __) async => _streamOf(
          [Message.assistant('p')],
          error: const CancelledException(),
        ),
      );

      final cfg = ModelFailoverConfig(
        maxRetries: 3,
        shouldFailover: (_, __, err) {
          shouldCalls++;
          // User decides to stop on canceled error
          return ThreepioException.findCause<CancelledException>(err) == null;
        },
        getFailoverModel: (_, __) => (m1, null),
      );

      final w = FailoverModel(FailoverProxyModel(), cfg);
      final (sr, err) = await _result(w.stream(_hi, options: _execOptions(m1)));
      expect(sr, isNull);
      expect(ThreepioException.findCause<CancelledException>(err), isNotNull,
          reason: '$err');
      // ShouldFailover is called once and returns false, stopping failover
      expect(shouldCalls, 1);
    });

    test(
        'stop when Stream returns error immediately and ShouldFailover '
        'returns false', () async {
      final wantErr = _Err('stream init failed');
      var shouldCalls = 0;
      var m1Calls = 0;
      final seenErrors = <Object?>[];

      final m1 = _FakeChatModel(
        stream: (_, __) async {
          m1Calls++;
          throw wantErr;
        },
      );

      final cfg = ModelFailoverConfig(
        maxRetries: 3,
        shouldFailover: (_, __, err) {
          shouldCalls++;
          seenErrors.add(err);
          return false;
        },
        getFailoverModel: (_, __) => (m1, null),
      );

      final w = FailoverModel(FailoverProxyModel(), cfg);
      final (sr, err) = await _result(w.stream(_hi, options: _execOptions(m1)));
      expect(sr, isNull);
      expect(_errorsIs(err, wantErr), isTrue, reason: '$err');
      expect(seenErrors.every((e) => _errorsIs(e, wantErr)), isTrue);
      expect(m1Calls, 1);
      expect(shouldCalls, 1);
    });

    // Go returns the error from GetFailoverModel; here it throws.
    test('stops when GetFailoverModel returns error', () async {
      final wantErr = _Err('get model failed');
      var called = 0;
      final inner = _FakeChatModel(
        stream: (_, __) async {
          called++;
          return StreamReader.fromIterable([Message.assistant('unused')]);
        },
      );

      final cfg = ModelFailoverConfig(
        maxRetries: 3,
        shouldFailover: (_, __, ___) => true,
        getFailoverModel: (_, __) => throw wantErr,
      );

      final w = FailoverModel(inner, cfg);
      final (sr, err) = await _result(w.stream(_hi));
      expect(sr, isNull);
      expect(_errorsIs(err, wantErr), isTrue, reason: '$err');
      expect(called, 0);
    });

    // Go's goroutine and channels become Completers the test completes.
    test('stops when ctx canceled during mid-way error handling', () async {
      final midErr = _Err('mid error');
      var shouldCalls = 0;
      var m1Calls = 0;
      var m2Calls = 0;
      final firstSent = Completer<void>();
      final release = Completer<void>();

      final m1 = _FakeChatModel(
        stream: (_, __) async {
          m1Calls++;
          Stream<Message> emit() async* {
            yield Message.assistant('p');
            firstSent.complete();
            await release.future;
            throw midErr;
          }

          return StreamReader.fromStream(emit());
        },
      );
      final m2 = _FakeChatModel(
        stream: (_, __) async {
          m2Calls++;
          return StreamReader.fromIterable([Message.assistant('unused')]);
        },
      );
      final attempts = <int>[];

      final cfg = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, __, ___) {
          shouldCalls++;
          return true;
        },
        getFailoverModel: (_, failoverCtx) {
          attempts.add(failoverCtx.failoverAttempt);
          return (m2, null);
        },
      );

      final w = FailoverModel(FailoverProxyModel(), cfg);
      final token = CancelToken();
      final result = _result(
        w.stream(_hi, options: _execOptions(m1, cancelToken: token)),
      );

      await firstSent.future;
      token.cancel();
      release.complete();

      final (sr, err) = await result;
      if (sr != null) await sr.close();
      expect(sr, isNull);
      expect(_errorsIs(err, midErr), isTrue, reason: '$err');
      expect(m1Calls, 1);
      expect(m2Calls, 0);
      expect(shouldCalls, 0);
      expect(attempts, isEmpty);
    });
  });

  group('TestRetryThenFailover', () {
    test('Generate_RetryExhaustedTriggersFailover', () async {
      final modelErr = _Err('model error');
      var m1Calls = 0;
      var m2Calls = 0;
      final lastErrors = <Object?>[];

      final m1 = _FakeChatModel(
        generate: (_, __) async {
          m1Calls++;
          throw modelErr;
        },
      );
      final m2 = _FakeChatModel(
        generate: (_, __) async {
          m2Calls++;
          return Message.assistant('ok from m2');
        },
      );

      // IsRetryAble (not ported) accepted every error.
      const retryCfg = ModelRetryConfig(maxRetries: 2, backoff: _zeroBackoff);
      final failoverCfg = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, __, err) => err != null,
        getFailoverModel: (_, fc) {
          lastErrors.add(fc.lastError);
          return (m2, null);
        },
      );

      final wrapped = _retryThenFailover(retryCfg, failoverCfg);
      final (msg, err) =
          await _result(wrapped.generate(_hi, options: _execOptions(m1)));
      expect(err, isNull);
      expect(msg!.content, 'ok from m2');
      expect(lastErrors, hasLength(1));
      expect(lastErrors.single, isNotNull);

      // m1: 1 (lastSuccess) + 2 retries = 3 calls on lastSuccess attempt,
      // then failover to m2 which also goes through retry wrapper: 1 call
      // succeeds.
      expect(m1Calls, 3);
      expect(m2Calls, 1);
    });

    test('Generate_AllExhausted', () async {
      final modelErr = _Err('always fails');
      var m1Calls = 0;
      var m2Calls = 0;

      final m1 = _FakeChatModel(
        generate: (_, __) async {
          m1Calls++;
          throw modelErr;
        },
      );
      final m2 = _FakeChatModel(
        generate: (_, __) async {
          m2Calls++;
          throw modelErr;
        },
      );

      // IsRetryAble (not ported) accepted every error.
      const retryCfg = ModelRetryConfig(maxRetries: 1, backoff: _zeroBackoff);
      final failoverCfg = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, __, err) => err != null,
        getFailoverModel: (_, __) => (m2, null),
      );

      final wrapped = _retryThenFailover(retryCfg, failoverCfg);
      final (_, err) =
          await _result(wrapped.generate(_hi, options: _execOptions(m1)));
      expect(err, isNotNull);
      // Should be RetryExhaustedError from m2's retry wrapper
      expect(_isExhausted(err), isTrue, reason: '$err');
      // m1: 1 initial + 1 retry = 2 calls
      expect(m1Calls, 2);
      // m2: 1 initial + 1 retry = 2 calls
      expect(m2Calls, 2);
    });

    test('Generate_RetrySucceedsNoFailover', () async {
      var m1Calls = 0;
      var failoverCalled = 0;
      var getFailoverModelCalled = 0;

      final m1 = _FakeChatModel(
        generate: (_, __) async {
          m1Calls++;
          if (m1Calls == 1) throw _Err('transient error');
          return Message.assistant('ok on retry');
        },
      );

      // IsRetryAble (not ported) accepted every error.
      const retryCfg = ModelRetryConfig(maxRetries: 2, backoff: _zeroBackoff);
      final failoverCfg = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, __, ___) {
          failoverCalled++;
          return true;
        },
        getFailoverModel: (_, __) {
          // Go: t.Fatal("GetFailoverModel should not be called when retry
          // succeeds"); counted and asserted below.
          getFailoverModelCalled++;
          return (m1, null);
        },
      );

      final wrapped = _retryThenFailover(retryCfg, failoverCfg);
      final (msg, err) =
          await _result(wrapped.generate(_hi, options: _execOptions(m1)));
      expect(err, isNull);
      expect(msg!.content, 'ok on retry');
      // 2 calls: first fails, second succeeds via retry
      expect(m1Calls, 2);
      // ShouldFailover should never be called
      expect(failoverCalled, 0);
      expect(getFailoverModelCalled, 0,
          reason: 'GetFailoverModel should not be called when retry succeeds');
    });

    test('Generate_NonRetryableErrorTriggersFailover', () async {
      final nonRetryableErr = _Err('non-retryable');
      var m1Calls = 0;
      var m2Calls = 0;

      final m1 = _FakeChatModel(
        generate: (_, __) async {
          m1Calls++;
          throw nonRetryableErr;
        },
      );
      final m2 = _FakeChatModel(
        generate: (_, __) async {
          m2Calls++;
          return Message.assistant('ok from m2');
        },
      );

      // IsRetryAble (not ported) rejected nonRetryableErr: the equivalent
      // shouldRetry retries every other error.
      final retryCfg = ModelRetryConfig(
        maxRetries: 3,
        shouldRetry: (_, rc) => RetryDecision(
          retry: rc.error != null && !_errorsIs(rc.error, nonRetryableErr),
        ),
        backoff: _zeroBackoff,
      );
      final failoverCfg = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, __, err) => err != null,
        getFailoverModel: (_, __) => (m2, null),
      );

      final wrapped = _retryThenFailover(retryCfg, failoverCfg);
      final (msg, err) =
          await _result(wrapped.generate(_hi, options: _execOptions(m1)));
      expect(err, isNull);
      expect(msg!.content, 'ok from m2');
      // m1 called only once — non-retryable error skips retry
      expect(m1Calls, 1);
      expect(m2Calls, 1);
    });

    test('Stream_RetryExhaustedTriggersFailover', () async {
      final streamErr = _Err('stream mid error');
      var m1Calls = 0;
      var m2Calls = 0;
      final lastErrors = <Object?>[];

      final m1 = _FakeChatModel(
        stream: (_, __) async {
          m1Calls++;
          return _streamOf([Message.assistant('partial')], error: streamErr);
        },
      );
      final m2 = _FakeChatModel(
        stream: (_, __) async {
          m2Calls++;
          return StreamReader.fromIterable([Message.assistant('ok from m2')]);
        },
      );

      // IsRetryAble (not ported) accepted every error.
      const retryCfg = ModelRetryConfig(maxRetries: 1, backoff: _zeroBackoff);
      final failoverCfg = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, __, err) => err != null,
        getFailoverModel: (_, fc) {
          lastErrors.add(fc.lastError);
          return (m2, null);
        },
      );

      final wrapped = _retryThenFailover(retryCfg, failoverCfg);
      final (sr, err) =
          await _result(wrapped.stream(_hi, options: _execOptions(m1)));
      expect(err, isNull);
      final (msgs, drainErr) = await _drainMessageStream(sr!);
      expect(drainErr, isNull);
      expect(msgs, hasLength(1));
      expect(msgs[0].content, 'ok from m2');
      expect(lastErrors.single, isNotNull);

      // m1: 1 initial + 1 retry = 2 calls on lastSuccess attempt
      expect(m1Calls, 2);
      expect(m2Calls, 1);
    });

    test('Stream_AllExhausted', () async {
      final streamErr = _Err('always fails mid-stream');
      var m1Calls = 0;
      var m2Calls = 0;

      final m1 = _FakeChatModel(
        stream: (_, __) async {
          m1Calls++;
          return _streamOf([Message.assistant('p')], error: streamErr);
        },
      );
      final m2 = _FakeChatModel(
        stream: (_, __) async {
          m2Calls++;
          return _streamOf([Message.assistant('p')], error: streamErr);
        },
      );

      // IsRetryAble (not ported) accepted every error.
      const retryCfg = ModelRetryConfig(maxRetries: 1, backoff: _zeroBackoff);
      final failoverCfg = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, __, err) => err != null,
        getFailoverModel: (_, __) => (m2, null),
      );

      final wrapped = _retryThenFailover(retryCfg, failoverCfg);
      final (_, err) =
          await _result(wrapped.stream(_hi, options: _execOptions(m1)));
      expect(err, isNotNull);
      expect(_isExhausted(err), isTrue, reason: '$err');
      // m1: 1 initial + 1 retry = 2 calls
      expect(m1Calls, 2);
      // m2: 1 initial + 1 retry = 2 calls
      expect(m2Calls, 2);
    });

    test('ShouldRetry_Stream_TriggersFailover', () async {
      var m1Calls = 0;
      var m2Calls = 0;

      final m1 = _FakeChatModel(
        stream: (_, __) async {
          m1Calls++;
          return StreamReader.fromIterable([Message.assistant('bad from m1')]);
        },
      );
      final m2 = _FakeChatModel(
        stream: (_, __) async {
          m2Calls++;
          return StreamReader.fromIterable([Message.assistant('good from m2')]);
        },
      );

      final retryCfg = ModelRetryConfig(
        maxRetries: 1,
        shouldRetry: (_, rc) =>
            RetryDecision(retry: rc.outputMessage?.content == 'bad from m1'),
        backoff: _zeroBackoff,
      );
      final failoverCfg = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, __, err) => err != null,
        getFailoverModel: (_, __) => (m2, null),
      );

      final wrapped = _retryThenFailover(retryCfg, failoverCfg);
      final (sr, err) =
          await _result(wrapped.stream(_hi, options: _execOptions(m1)));
      expect(err, isNull);
      final (msgs, drainErr) = await _drainMessageStream(sr!);
      expect(drainErr, isNull);
      expect(msgs, hasLength(1));
      expect(msgs[0].content, 'good from m2');
      expect(m1Calls, 2);
      expect(m2Calls, 1);
    });

    test('ShouldRetry_Generate_TriggersFailover', () async {
      var m1Calls = 0;
      var m2Calls = 0;

      final m1 = _FakeChatModel(
        generate: (_, __) async {
          m1Calls++;
          return Message.assistant('bad from m1');
        },
      );
      final m2 = _FakeChatModel(
        generate: (_, __) async {
          m2Calls++;
          return Message.assistant('good from m2');
        },
      );

      final retryCfg = ModelRetryConfig(
        maxRetries: 1,
        shouldRetry: (_, rc) =>
            RetryDecision(retry: rc.outputMessage?.content == 'bad from m1'),
        backoff: _zeroBackoff,
      );
      final failoverCfg = ModelFailoverConfig(
        maxRetries: 1,
        shouldFailover: (_, __, err) => err != null,
        getFailoverModel: (_, __) => (m2, null),
      );

      final wrapped = _retryThenFailover(retryCfg, failoverCfg);
      final (msg, err) =
          await _result(wrapped.generate(_hi, options: _execOptions(m1)));
      expect(err, isNull);
      expect(msg!.content, 'good from m2');
      expect(m1Calls, 2);
      expect(m2Calls, 1);
    });

    // Go's context.Canceled is a CancelledException.
    test('Stream_ContextCanceledDuringFailover', () async {
      final streamErr = _Err('m1 fails');
      var m1Calls = 0;
      var failoverModelCalled = 0;

      final m1 = _FakeChatModel(
        stream: (_, __) async {
          m1Calls++;
          throw streamErr;
        },
      );

      final token = CancelToken();

      // IsRetryAble (not ported) returned false: the equivalent shouldRetry
      // never retries (without it the error would come back wrapped in a
      // RetryExhaustedException).
      final retryCfg = ModelRetryConfig(
        shouldRetry: (_, __) => const RetryDecision(),
        backoff: _zeroBackoff,
      );
      final failoverCfg = ModelFailoverConfig(
        maxRetries: 3,
        shouldFailover: (_, __, err) {
          token.cancel();
          return err != null;
        },
        getFailoverModel: (_, __) {
          failoverModelCalled++;
          return (m1, null);
        },
      );

      final wrapped = _retryThenFailover(retryCfg, failoverCfg);
      final (_, err) = await _result(
        wrapped.stream(_hi, options: _execOptions(m1, cancelToken: token)),
      );
      expect(err, isNotNull);
      expect(ThreepioException.findCause<CancelledException>(err), isNotNull,
          reason: '$err');
      expect(m1Calls, 1);
      expect(failoverModelCalled, 0);
    });
  });
}

/// Go's `rejectInfo` (TestRejectReason_StreamPath).
class _RejectInfo {
  _RejectInfo(this.reason, this.attempt);

  final String reason;
  final int attempt;
}
