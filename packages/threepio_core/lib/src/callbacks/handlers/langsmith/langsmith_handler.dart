/// Traces the components of a run in LangSmith.
///
/// Port of eino-ext `callbacks/langsmith` (`langsmith.go`).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:uuid/uuid.dart';

import '../../../components/model/model_callbacks.dart';
import '../../../core/run_context.dart';
import '../../../observability/langfuse/langfuse_values.dart' show encodeJson;
import '../../../schema/message.dart';
import '../../../streaming/stream_reader.dart';
import '../../component_callback_handler.dart';
import '../../run_info.dart';
import 'langsmith_client.dart';
import 'langsmith_trace.dart';
import 'langsmith_utils.dart';

final _log = Logger('threepio.observability.langsmith');

/// The settings of a [LangSmithHandler] and of a `LangSmithFlowTrace`.
///
/// Port of eino-ext `langsmith.Config`.
@immutable
final class LangSmithConfig {
  /// Creates the settings.
  const LangSmithConfig({
    required this.apiKey,
    this.apiUrl = '',
    this.runIdGen,
    this.httpClient,
    this.timeout = const Duration(seconds: 10),
    this.maxQueueSize = 2048,
  });

  /// The LangSmith API key, sent in the header `x-api-key`.
  final String apiKey;

  /// The base URL of the LangSmith API. Empty means
  /// `https://api.smith.langchain.com` ([LangSmithClient.defaultApiUrl]).
  final String apiUrl;

  /// Makes the id of every run. Defaults to a random (version 4) UUID, which
  /// is what LangSmith expects. Port of `RunIDGen`.
  final String Function(RunContext ctx)? runIdGen;

  /// The HTTP client the requests are sent with. When given, the caller owns
  /// it and closes it; otherwise one is created and closed by `shutdown`
  /// (or `LangSmithFlowTrace.close`).
  final http.Client? httpClient;

  /// How long one request to LangSmith may take. Go: the `Timeout` of the
  /// client's `http.Client`, 10 seconds.
  final Duration timeout;

  /// How many requests a [LangSmithHandler] keeps waiting to be sent. A
  /// request beyond that is dropped (and counted in
  /// [LangSmithHandler.droppedRequests]). Must be positive.
  final int maxQueueSize;
}

/// A callback handler that records the components of a run in
/// [LangSmith](https://smith.langchain.com) as a tree of runs.
///
/// Port of eino-ext `langsmith.CallbackHandler`
/// (`langsmith.NewLangsmithHandler`). Every component that starts becomes a
/// run (`POST /runs`) that is updated when it ends or fails
/// (`PATCH /runs/{id}`): a chat model an `llm` run, a tool a `tool` run,
/// everything else a `chain` run. A component that runs inside another is
/// recorded beneath it, in the same trace.
///
/// ```dart
/// final langSmith = LangSmithHandler(
///   const LangSmithConfig(apiKey: 'lsv2_...'),
/// );
/// GlobalCallbacks.append([langSmith]);
///
/// final ctx = LangSmithTrace.set(
///   RunContext.background(),
///   sessionName: 'support-bot',
///   tags: ['production'],
/// );
/// final answer = await runnable.invoke(ctx, question);
///
/// await langSmith.shutdown(); // before the application exits
/// ```
///
/// **What a run shows.** The input of a component is written as JSON text
/// under `inputs.input`, its output under `outputs.output`, its error as
/// `error`. A component whose input is a stream shows the messages of a chat
/// model input under `inputs.stream_inputs`, one whose output is a stream
/// the joined chat model message under `outputs.stream_outputs`, as in Go:
/// the chunks of other streams are not shown. The settings of a chat model
/// call go into `extra.metadata` (`ls_model_name`, `ls_max_tokens`,
/// `model_conf`), and the token usage of a streamed answer into
/// `extra.metadata.usage_metadata`. [LangSmithTrace.set] names the project,
/// the tags and the metadata of the runs of a context.
///
/// **The network is never waited for.** Go sends each request inside the
/// callback. Here the hooks put the requests in a queue and return; the
/// queue sends them one at a time, in order, so that a run is always created
/// before it is updated and before the runs beneath it. Streams are read in
/// the background. [flush] waits until everything has been sent, [shutdown]
/// also releases the HTTP client.
///
/// **Nothing here fails the run.** A request LangSmith does not take, or
/// that cannot be sent, is logged (logger `threepio.observability.langsmith`)
/// and counted in [failedRequests], as Go logs it; it is not tried again,
/// and the next request is sent.
///
/// **One handler per run.** All LangSmith handlers keep their position in
/// the trace under the same context entry (`LangSmithTrace.stateOf`), as in
/// Go, so two of them on one run record each other's runs as parents. Each
/// still ends its own runs.
final class LangSmithHandler extends ComponentCallbackHandler {
  /// Creates a handler that sends to the LangSmith API of [config].
  ///
  /// [client] replaces the transport: the runs go there instead, and the URL,
  /// key, HTTP client and timeout of [config] are not used. [shutdown] does
  /// not close such a client.
  ///
  /// Throws [ArgumentError] when [LangSmithConfig.maxQueueSize] is not
  /// positive.
  LangSmithHandler(this.config, {LangSmithApi? client})
      : _ownClient = client == null
            ? LangSmithClient(
                apiKey: config.apiKey,
                apiUrl: config.apiUrl,
                httpClient: config.httpClient,
                timeout: config.timeout,
              )
            : null,
        _queue = _RequestQueue(config.maxQueueSize) {
    if (config.maxQueueSize <= 0) {
      throw ArgumentError.value(
        config.maxQueueSize,
        'maxQueueSize',
        'the LangSmith queue size must be positive',
      );
    }
    _api = client ?? _ownClient!;
  }

  /// The settings of this handler.
  final LangSmithConfig config;

  final LangSmithClient? _ownClient;
  late final LangSmithApi _api;
  final _RequestQueue _queue;
  final _Background _background = _Background();

  /// The run this handler opened for the component a context belongs to.
  /// One key per handler, so that two handlers never end each other's runs:
  /// it must not be `const`, or every handler would share it.
  // ignore: prefer_const_constructors
  final ContextKey<_Run> _runKey = ContextKey<_Run>('langsmith.run');

  /// The context the queued requests are sent with: a component that was
  /// cancelled still has its end reported.
  final RunContext _sendContext = RunContext.background();

  Future<void>? _shutdown;

  /// Set when [shutdown] starts: hooks create no new run from then on.
  bool _stopping = false;

  /// Set when [shutdown] has ended: a request that fails afterwards was
  /// abandoned by it.
  bool _stopped = false;
  bool _overflowing = false;
  int _failed = 0;
  int _dropped = 0;

  /// How many requests LangSmith did not take or that could not be sent.
  int get failedRequests => _failed;

  /// How many requests were not sent because the queue was full
  /// ([LangSmithConfig.maxQueueSize]), the handler was shutting down, or
  /// they update a run whose creation was not sent for one of these reasons.
  int get droppedRequests => _dropped;

  // -------------------------------------------------------------- callbacks

  /// Port of `CallbackHandler.OnStart`: creates the run of the component.
  @override
  RunContext onStart(RunContext ctx, RunInfo info, Object? input) {
    if (info.isUnknown) return ctx;
    final (current, state) = LangSmithTrace.getOrInitState(ctx);
    final runId = _newRunId(current);
    final options =
        LangSmithTrace.optionsOf(current) ?? const LangSmithTraceOptions();
    final start = clock.now().toUtc();
    final traceId = state.traceId.isEmpty ? runId : state.traceId;
    final dottedOrder =
        langSmithDottedOrder(state.parentDottedOrder, start, runId);

    var extra = langSmithCopyMetadata(options.metadata);
    final modelConfig = _modelConfigOf(input);
    if (modelConfig != null) {
      extra = langSmithWithModelConfig(extra, modelConfig);
    }

    final run = LangSmithRun(
      id: runId,
      traceId: traceId,
      name: langSmithRunName(info),
      runType: langSmithRunType(info),
      startTime: start,
      inputs: {'input': _encode(input, 'input', info)},
      sessionName: options.sessionName,
      extra: extra,
      tags: options.tags,
      referenceExampleId: options.referenceExampleId.isEmpty
          ? null
          : options.referenceExampleId,
      parentRunId: state.parentRunId.isEmpty ? null : state.parentRunId,
      dottedOrder: dottedOrder,
    );
    final record = _Run(runId, extra);
    if (_stopping) {
      _drop(afterShutdown: true);
      record.posted.complete();
    } else {
      _sendAfter(
        _parentOf(current, state),
        () => record.queued = _enqueue(
          'failed to create run',
          (ctx) => _api.createRun(ctx, run),
        ),
        done: record.posted,
      );
    }
    if (_log.isLoggable(Level.FINE)) _log.fine('[langsmith] runinfo: $run');

    return _enter(
      current,
      record,
      LangSmithState(
        traceId: traceId,
        parentRunId: runId,
        parentDottedOrder: dottedOrder,
        metadata: Map.unmodifiable(extra),
        tags: options.tags,
      ),
    );
  }

  /// Port of `CallbackHandler.OnEnd`: ends the run with the [output].
  @override
  RunContext onEnd(RunContext ctx, RunInfo info, Object? output) {
    if (info.isUnknown) return ctx;
    final target = _targetOf(ctx);
    if (target == null) {
      _log.fine('[langsmith] no state in context on OnEnd, runinfo: $info');
      return ctx;
    }
    final patch = LangSmithRunPatch(
      endTime: clock.now().toUtc(),
      outputs: {'output': _encode(output, 'output', info)},
    );
    _update(target, 'failed to update run', patch);
    return ctx;
  }

  /// Port of `CallbackHandler.OnError`: ends the run with the [error].
  @override
  RunContext onError(
    RunContext ctx,
    RunInfo info,
    Object error,
    StackTrace stackTrace,
  ) {
    if (info.isUnknown) return ctx;
    final target = _targetOf(ctx);
    if (target == null) {
      _log.fine('[langsmith] no state in context on OnError, runinfo: $info');
      return ctx;
    }
    final patch = LangSmithRunPatch(
      endTime: clock.now().toUtc(),
      error: langSmithErrorText(error),
    );
    _update(target, 'failed to update run with error', patch);
    return ctx;
  }

  /// Port of `CallbackHandler.OnStartWithStreamInput`: the run is created
  /// once the stream has ended, with the messages of a chat model input.
  @override
  Future<RunContext> onStartWithStreamInput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> input,
  ) async {
    if (info.isUnknown) {
      await input.close();
      return ctx;
    }
    final (current, state) = LangSmithTrace.getOrInitState(ctx);
    final runId = _newRunId(current);
    final options =
        LangSmithTrace.optionsOf(current) ?? const LangSmithTraceOptions();
    final start = clock.now().toUtc();
    final traceId = state.traceId.isEmpty ? runId : state.traceId;
    final dottedOrder =
        langSmithDottedOrder(state.parentDottedOrder, start, runId);
    final metadata = langSmithCopyMetadata(options.metadata);
    final record = _Run(runId, metadata);
    final parentPosted = _parentOf(current, state);

    final started = _background.run(() async {
      try {
        final (inputs, error) = await _receiveAll(input);
        if (error != null) {
          _log.warning(
            '[langsmith] error receiving stream input: '
            '${langSmithErrorText(error)}',
          );
        }
        var extra = metadata;
        var messages = const <Message>[];
        try {
          final model = langSmithExtractModelInput([
            for (final chunk in inputs) ModelCallbackInput.from(chunk),
          ]);
          messages = model.messages;
          final modelExtra = model.extra;
          if (modelExtra != null) extra = {...extra, ...modelExtra};
          final config = model.config;
          if (config != null) extra = langSmithWithModelConfig(extra, config);
          // A failure to read the chunks of a chat model input is logged and
          // the run created without its messages; Go does not create it.
          // ignore: avoid_catches_without_on_clauses
        } catch (error) {
          _log.warning(
            'extract stream model input error: ${langSmithErrorText(error)}, '
            'runinfo: $info',
          );
        }
        record.metadata = extra;
        final run = LangSmithRun(
          id: runId,
          traceId: traceId,
          name: langSmithRunName(info),
          runType: langSmithRunType(info),
          startTime: start,
          inputs: {'stream_inputs': messages},
          sessionName: options.sessionName,
          extra: extra,
          tags: options.tags,
          referenceExampleId: options.referenceExampleId.isEmpty
              ? null
              : options.referenceExampleId,
          parentRunId: state.parentRunId.isEmpty ? null : state.parentRunId,
          dottedOrder: dottedOrder,
        );
        if (parentPosted != null && !parentPosted.isCompleted) {
          await parentPosted.future;
        }
        record.queued = _enqueue(
          'failed to create run for stream',
          (ctx) => _api.createRun(ctx, run),
        );
      } finally {
        if (!record.posted.isCompleted) record.posted.complete();
      }
    });
    if (!started) {
      _drop(afterShutdown: true);
      record.posted.complete();
      await input.close();
    }

    return _enter(
      current,
      record,
      LangSmithState(
        traceId: traceId,
        parentRunId: runId,
        parentDottedOrder: dottedOrder,
        metadata: Map.unmodifiable(metadata),
        tags: options.tags,
      ),
    );
  }

  /// Port of `CallbackHandler.OnEndWithStreamOutput`: the run is ended once
  /// the stream has ended, with the joined chat model message and its token
  /// usage.
  @override
  Future<RunContext> onEndWithStreamOutput(
    RunContext ctx,
    RunInfo info,
    StreamReader<Object?> output,
  ) async {
    if (info.isUnknown) {
      await output.close();
      return ctx;
    }
    final target = _targetOf(ctx);
    if (target == null) {
      _log.fine(
        '[langsmith] no state in context on OnEndWithStreamOutput, '
        'runinfo: $info',
      );
      await output.close();
      return ctx;
    }

    final started = _background.run(() async {
      final (outputs, error) = await _receiveAll(output);
      if (error != null) {
        _log.warning(
          '[langsmith] error receiving stream output: '
          '${langSmithErrorText(error)}',
        );
      }
      final end = clock.now().toUtc();
      final run = target.run;
      if (run != null && !run.posted.isCompleted) await run.posted.future;

      // What the run was created with, so that the update does not take
      // away the model settings. For a run whose input was streamed this
      // also keeps the extra values of that input, which Go leaves out (it
      // starts from the metadata of the state, which never gets them).
      var extra = langSmithCopyMetadata(run?.metadata ?? target.metadata);
      Object? message = langSmithEmptyMessageJson;
      try {
        final model = langSmithExtractModelOutput([
          for (final chunk in outputs) ModelCallbackOutput.from(chunk),
        ]);
        final modelExtra = model.extra;
        if (modelExtra != null) extra = {...extra, ...modelExtra};
        final usage = model.usage;
        if (usage != null) extra = langSmithWithUsage(extra, usage);
        message = model.message ?? langSmithEmptyMessageJson;
        // A failure to join the chunks is logged and the run ended without
        // its message; Go leaves the run open.
        // ignore: avoid_catches_without_on_clauses
      } catch (error) {
        _log.warning(
          'extract stream model output error: ${langSmithErrorText(error)}, '
          'runinfo: $info',
        );
      }
      final patch = LangSmithRunPatch(
        endTime: end,
        outputs: {'stream_outputs': message},
        extra: extra,
      );
      _enqueueUpdate(target, 'failed to update run with stream output', patch);
    });
    if (!started) {
      _drop(afterShutdown: true);
      await output.close();
    }
    return ctx;
  }

  // -------------------------------------------------------- flush, shutdown

  /// Waits for the streams this handler is still reading and for every
  /// queued request to be sent.
  ///
  /// With a [timeout], neither the streams nor LangSmith are waited for
  /// longer than that, each; what is left is sent later.
  Future<void> flush({Duration? timeout}) async {
    await _background.wait(timeout: timeout);
    await _queue.idle(timeout: timeout);
  }

  /// Sends what is queued and releases the HTTP client this handler created.
  ///
  /// Call it before the application exits. From the moment it is called,
  /// callbacks create no new run (a component still gets its state, so that
  /// its end does not end the run around it); what was begun before, such as
  /// a stream being read, is finished and sent, and so is the end of a run
  /// created before that comes while those streams are waited for. With a
  /// [timeout],
  /// streams that have not ended by then are given up on, and so are the
  /// requests LangSmith has not taken after the same time again, including
  /// one that is on its way. Everything not sent is counted in
  /// [droppedRequests]. Calling it again waits for the first call.
  Future<void> shutdown({Duration? timeout}) =>
      _shutdown ??= _shutDown(timeout);

  Future<void> _shutDown(Duration? timeout) async {
    // Runs up to the first `await` within the call of `shutdown`.
    _stopping = true;
    await _background.wait(timeout: timeout, close: true);
    // What the background work had to queue is queued; nothing new is.
    _queue.seal();
    await _queue.idle(timeout: timeout);
    final discarded = _queue.close();
    if (discarded > 0) {
      _dropped += discarded;
      _log.warning(
        '[langsmith] shut down with $discarded request(s) not sent',
      );
    }
    _stopped = true;
    _ownClient?.close();
  }

  // -------------------------------------------------------------- internals

  String _newRunId(RunContext ctx) {
    final generate = config.runIdGen;
    if (generate != null) {
      try {
        return generate(ctx);
        // The function is the application's. A run needs an id all the same.
        // ignore: avoid_catches_without_on_clauses
      } catch (error, stackTrace) {
        _log.warning(
          '[langsmith] runIdGen failed; using a random id',
          error,
          stackTrace,
        );
      }
    }
    return const Uuid().v4();
  }

  /// Port of the first lines of `OnStart`: the settings of a chat model
  /// call, when [input] is the input of one.
  static ModelCallbackConfig? _modelConfigOf(Object? input) {
    try {
      return langSmithExtractModelInput([ModelCallbackInput.from(input)])
          .config;
      // Reading an input must not keep the run from being recorded.
      // ignore: avoid_catches_without_on_clauses
    } catch (_) {
      return null;
    }
  }

  /// [value] as JSON text, as Go writes the input and output of a run
  /// (`sonic.MarshalString`). A value that cannot be written as JSON is
  /// written as its text (`toString()`); Go records no run for it.
  static String _encode(Object? value, String what, RunInfo info) {
    final encoded = encodeJson(value);
    if (encoded != null) return encoded;
    _log.warning('marshal $what error, runinfo: $info');
    return jsonEncode(langSmithErrorText(value));
  }

  /// What ends: the run of this handler in [ctx], or else the run the state
  /// of [ctx] names (Go only looks at the state).
  _Target? _targetOf(RunContext ctx) {
    final state = LangSmithTrace.stateOf(ctx);
    if (state == null) return null;
    final run = ctx.value(_runKey);
    if (run != null) {
      return (runId: run.id, run: run, metadata: state.metadata);
    }
    if (state.parentRunId.isEmpty) return null;
    return (runId: state.parentRunId, run: null, metadata: state.metadata);
  }

  /// What the run that starts in [ctx] waits for before it is created: the
  /// creation of the run it is part of, when this handler opened that one.
  Completer<void>? _parentOf(RunContext ctx, LangSmithState state) {
    final parent = ctx.value(_runKey);
    return parent != null && parent.id == state.parentRunId
        ? parent.posted
        : null;
  }

  RunContext _enter(RunContext ctx, _Run run, LangSmithState state) =>
      LangSmithTrace.withState(ctx, state).withValue(_runKey, run);

  /// Calls [enqueue] once [after] is complete: right away, or in the
  /// background. Completes [done] when it has been called (or given up on).
  /// Once [shutdown] has started, nothing waits in the background any more;
  /// the queue itself refuses requests once it is sealed.
  void _sendAfter(
    Completer<void>? after,
    void Function() enqueue, {
    Completer<void>? done,
  }) {
    if (after == null || after.isCompleted) {
      try {
        enqueue();
      } finally {
        done?.complete();
      }
      return;
    }
    final started = _background.run(() async {
      try {
        await after.future;
        enqueue();
      } finally {
        done?.complete();
      }
    });
    if (!started) {
      _drop(afterShutdown: true);
      done?.complete();
    }
  }

  /// Queues the update [patch] of the run [target] names, once the request
  /// that creates the run is queued (when this handler opened it). [what]
  /// begins the message logged when the update fails (Go's text).
  void _update(_Target target, String what, LangSmithRunPatch patch) =>
      _sendAfter(
        target.run?.posted,
        () => _enqueueUpdate(target, what, patch),
      );

  /// Puts the update [patch] of the run [target] names in the queue, unless
  /// this handler opened that run and did not send the request that creates
  /// it (the queue was full, or [shutdown] had started): LangSmith would
  /// refuse to update a run it does not have.
  void _enqueueUpdate(_Target target, String what, LangSmithRunPatch patch) {
    if (target.run case final run? when !run.queued) {
      _dropped++;
      _log.fine(
        '[langsmith] update of run ${target.runId} dropped: the request that '
        'creates the run was not sent',
      );
      return;
    }
    _enqueue(what, (ctx) => _api.updateRun(ctx, target.runId, patch));
  }

  /// Puts a request in the queue and returns whether it was taken. [what]
  /// begins the message logged when it fails (Go's text).
  bool _enqueue(String what, Future<void> Function(RunContext ctx) request) {
    Future<void> send() async {
      try {
        await request(_sendContext);
        // Whatever the transport throws is a request that was not taken.
        // ignore: avoid_catches_without_on_clauses
      } catch (error) {
        if (_stopped) {
          // Abandoned by a shutdown that stopped waiting for it.
          _dropped++;
          _log.fine(
            '[langsmith] $what after shutdown: ${langSmithErrorText(error)}',
          );
        } else {
          _failed++;
          _log.warning('[langsmith] $what: ${langSmithErrorText(error)}');
        }
      }
    }

    switch (_queue.add(send)) {
      case _Added.queued:
        // The queue had drained: warn again at the next overflow.
        if (_queue.waiting == 1) _overflowing = false;
        return true;
      case _Added.full:
        _drop(afterShutdown: false);
        return false;
      case _Added.closed:
        _drop(afterShutdown: true);
        return false;
    }
  }

  void _drop({required bool afterShutdown}) {
    _dropped++;
    if (afterShutdown) {
      _log.fine('[langsmith] request dropped: the handler has shut down');
    } else if (!_overflowing) {
      _overflowing = true;
      _log.warning(
        '[langsmith] the queue is full (${config.maxQueueSize} requests); '
        'dropping requests until it has room',
      );
    }
  }

  /// Reads [reader] to its end and closes it. Returns the items, and the
  /// error that ended the reading early.
  static Future<(List<Object?>, Object?)> _receiveAll(
    StreamReader<Object?> reader,
  ) async {
    final values = <Object?>[];
    try {
      while (true) {
        try {
          values.add(await reader.recv());
        } on SourceEOFException {
          // One source of a merged stream ended; the others go on.
        }
      }
    } on StreamEOFException {
      return (values, null);
      // ignore: avoid_catches_without_on_clauses
    } catch (error) {
      return (values, error);
    } finally {
      await reader.close();
    }
  }
}

/// What an end callback updates: the run's id, the run when this handler
/// opened it, and the metadata of the state.
typedef _Target = ({
  String runId,
  _Run? run,
  Map<String, Object?>? metadata,
});

/// A run this handler opened.
final class _Run {
  _Run(this.id, this.metadata);

  final String id;

  /// The `extra` the run is created with. For a streamed input it is only
  /// known once the stream has ended.
  Map<String, Object?> metadata;

  /// Completes when the request that creates the run is in the queue (or has
  /// been given up on). The requests that must come after it wait for it.
  final Completer<void> posted = Completer<void>();

  /// Whether the request that creates the run was taken by the queue; set
  /// before [posted] completes. When it was not, the updates of the run are
  /// not sent either.
  bool queued = false;
}

enum _Added { queued, full, closed }

/// The requests waiting to be sent, sent one at a time in the order they
/// were added.
final class _RequestQueue {
  _RequestQueue(this.maxSize);

  final int maxSize;
  final Queue<Future<void> Function()> _pending = Queue();
  bool _sending = false;
  bool _sealed = false;
  bool _closed = false;
  Completer<void>? _idle;

  /// The requests waiting, and the one being sent.
  int get length => _pending.length + (_sending ? 1 : 0);

  /// The requests waiting.
  int get waiting => _pending.length;

  /// Adds [send], which must not throw.
  _Added add(Future<void> Function() send) {
    if (_sealed || _closed) return _Added.closed;
    if (_pending.length >= maxSize) return _Added.full;
    _pending.add(send);
    if (!_sending) {
      _sending = true;
      // Started from a microtask: the callback that added the request
      // returns first.
      scheduleMicrotask(() => unawaited(_drain()));
    }
    return _Added.queued;
  }

  Future<void> _drain() async {
    try {
      while (_pending.isNotEmpty && !_closed) {
        final send = _pending.removeFirst();
        try {
          await send();
          // `send` catches what the request throws; this is a last guard.
          // ignore: avoid_catches_without_on_clauses
        } catch (error, stackTrace) {
          _log.warning('[langsmith] request failed', error, stackTrace);
        }
      }
    } finally {
      _sending = false;
      _idle?.complete();
      _idle = null;
    }
  }

  /// Completes when nothing is waiting or being sent, or after [timeout].
  Future<void> idle({Duration? timeout}) async {
    if (!_sending && _pending.isEmpty) return;
    final idle = (_idle ??= Completer<void>()).future;
    if (timeout == null) return idle;
    await idle.timeout(
      timeout,
      onTimeout: () => _log.warning(
        '[langsmith] stopped waiting for LangSmith; $length request(s) not '
        'sent yet',
      ),
    );
  }

  /// Refuses new requests; the waiting ones are still sent.
  void seal() => _sealed = true;

  /// Refuses new requests and drops the waiting ones. Returns how many were
  /// dropped. A request being sent is not waited for (the handler closes the
  /// HTTP client it created, which aborts it).
  int close() {
    _sealed = true;
    _closed = true;
    final discarded = _pending.length;
    _pending.clear();
    return discarded;
  }
}

/// The work the handler does in the background: reading streams, and
/// requests that wait for another one to be queued. Port of the goroutines
/// of `OnStartWithStreamInput` and `OnEndWithStreamOutput`.
final class _Background {
  int _active = 0;
  bool _closing = false;
  Completer<void>? _idle;

  /// Starts [work] unless the handler is shutting down. Returns whether it
  /// started.
  bool run(Future<void> Function() work) {
    if (_closing) return false;
    _active++;
    unawaited(_guarded(work));
    return true;
  }

  Future<void> _guarded(Future<void> Function() work) async {
    try {
      await work();
      // Telemetry must not surface as an unhandled error of the application.
      // ignore: avoid_catches_without_on_clauses
    } catch (error, stackTrace) {
      _log.warning('[langsmith] callback failed', error, stackTrace);
    } finally {
      _active--;
      if (_active == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  /// Completes when no work is running, or after [timeout]. With [close],
  /// no new work is started from now on.
  Future<void> wait({Duration? timeout, bool close = false}) async {
    if (close) _closing = true;
    if (_active == 0) return;
    final idle = (_idle ??= Completer<void>()).future;
    if (timeout == null) return idle;
    await idle.timeout(
      timeout,
      onTimeout: () => _log.warning(
        '[langsmith] stopped waiting for $_active stream(s) that have not '
        'ended; their runs may not be recorded',
      ),
    );
  }
}
