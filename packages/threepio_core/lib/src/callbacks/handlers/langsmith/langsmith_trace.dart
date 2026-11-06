/// What a run context tells the LangSmith handler: the options of the trace
/// and the run the next component is part of.
///
/// Port of eino-ext `callbacks/langsmith/trace.go`, of `LangsmithState` and
/// of `GetOrInitState` and `GetState` (`langsmith.go`, `utils.go`).
library;

import 'package:meta/meta.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../../observability/langfuse/langfuse_values.dart' show toJsonValue;

/// The options of the LangSmith trace a context belongs to, as
/// [LangSmithTrace.set] stored them.
///
/// Port of eino-ext's `traceOptions`. Go's `ParentID` and
/// `ParentDottedOrder`, which no Go option sets, are not ported; continue a
/// trace under a known run with [LangSmithTrace.withState] instead.
@immutable
final class LangSmithTraceOptions {
  /// Creates options. Prefer [LangSmithTrace.set], which also removes
  /// duplicate tags and copies [metadata].
  const LangSmithTraceOptions({
    this.sessionName = '',
    this.referenceExampleId = '',
    this.traceId = '',
    this.metadata,
    this.tags = const [],
  });

  /// The LangSmith project the runs are recorded in; empty for the default
  /// project. Port of `WithSessionName`.
  final String sessionName;

  /// The dataset example the runs are evaluated against; empty for none.
  /// Port of `WithReferenceExampleID`.
  final String referenceExampleId;

  /// The trace the first run joins instead of starting one of its own; empty
  /// for a new trace. Port of `WithTraceID`.
  final String traceId;

  /// The `extra` of every run, `null` for none. LangSmith shows its entry
  /// `metadata` (a map) as the metadata of the run. Port of `SetMetadata`.
  final Map<String, Object?>? metadata;

  /// The tags of every run, without duplicates. Port of `AddTag`.
  final List<String> tags;

  @override
  String toString() => 'LangSmithTraceOptions(sessionName: $sessionName, '
      'referenceExampleId: $referenceExampleId, traceId: $traceId, '
      'metadata: $metadata, tags: $tags)';
}

/// Where the next run of a LangSmith trace goes: the trace, the run it is
/// part of and that run's place in the trace.
///
/// Port of eino-ext `langsmith.LangsmithState`. The LangSmith handler puts
/// one in the context of every component it sees, and the components run
/// inside are recorded beneath it. [LangSmithTrace.stateOf] reads it, and
/// `LangSmithFlowTrace` turns it into text and back, to carry a trace across
/// a process boundary.
@immutable
final class LangSmithState {
  /// Creates a state. All empty is a state outside any trace.
  const LangSmithState({
    this.traceId = '',
    this.parentRunId = '',
    this.parentDottedOrder = '',
    this.metadata,
    this.tags,
  });

  /// Reads the JSON [LangSmithState.toJson] writes (and Go's
  /// `FlowTrace.SpanToString`).
  ///
  /// Port of the decoding in `FlowTrace.StringToSpan`: [metadata] is taken
  /// from `marshal_metadata`; the `metadata` entry itself carries nothing
  /// (Go writes its `sync.Map` as `{}`). Throws a [ThreepioFormatException]
  /// when a field has the wrong type.
  factory LangSmithState.fromJson(Map<String, Object?> json) {
    String text(String key) => switch (json[key]) {
          null => '',
          final String value => value,
          final other => throw ThreepioFormatException(
              'LangSmith state: "$key" is not a string: $other',
            ),
        };

    final tags = switch (json['tags']) {
      null => null,
      final List<Object?> list when list.every((tag) => tag is String) =>
        List<String>.unmodifiable(list.cast<String>()),
      final other => throw ThreepioFormatException(
          'LangSmith state: "tags" is not a list of strings: $other',
        ),
    };

    final metadata = switch (json['marshal_metadata']) {
      final Map<Object?, Object?> map => Map<String, Object?>.unmodifiable({
          for (final MapEntry(:key, :value) in map.entries) '$key': value,
        }),
      null => json['metadata'] is Map ? const <String, Object?>{} : null,
      final other => throw ThreepioFormatException(
          'LangSmith state: "marshal_metadata" is not an object: $other',
        ),
    };

    return LangSmithState(
      traceId: text('trace_id'),
      parentRunId: text('parent_run_id'),
      parentDottedOrder: text('parent_dotted_order'),
      metadata: metadata,
      tags: tags,
    );
  }

  /// The trace; empty when no run has started one yet.
  final String traceId;

  /// The run the next run is part of; empty for none.
  final String parentRunId;

  /// The dotted order of [parentRunId]; empty for none.
  final String parentDottedOrder;

  /// The `extra` of [parentRunId], when the handler recorded it.
  final Map<String, Object?>? metadata;

  /// The tags of [parentRunId], when the handler recorded them.
  final List<String>? tags;

  /// The state as JSON, in the shape Go's `FlowTrace.SpanToString` writes:
  /// `trace_id`, `parent_run_id`, `parent_dotted_order`, `metadata` (`{}`,
  /// or `null` without metadata), `tags` and `marshal_metadata` (the
  /// metadata itself).
  Map<String, Object?> toJson() {
    final metadata = this.metadata;
    final tags = this.tags;
    return {
      'trace_id': traceId,
      'parent_run_id': parentRunId,
      'parent_dotted_order': parentDottedOrder,
      'metadata': metadata == null ? null : const <String, Object?>{},
      'tags': tags == null ? null : List<String>.of(tags),
      'marshal_metadata': toJsonValue(metadata ?? const <String, Object?>{}),
    };
  }

  @override
  String toString() => 'LangSmithState(traceId: $traceId, parentRunId: '
      '$parentRunId, parentDottedOrder: $parentDottedOrder, metadata: '
      '$metadata, tags: $tags)';
}

/// The LangSmith side of a [RunContext]: the options of the trace and the
/// state of the run that is going on.
///
/// Port of eino-ext's `SetTrace` (with its options), `GetOrInitState` and
/// `GetState`.
///
/// ```dart
/// final ctx = LangSmithTrace.set(
///   RunContext.background().withHandlers([langSmith]),
///   sessionName: 'support-bot',
///   tags: ['production'],
///   metadata: {
///     'metadata': {'conversation': conversationId},
///   },
/// );
/// ```
abstract final class LangSmithTrace {
  static const _optionsKey = ContextKey<LangSmithTraceOptions>(
    'langsmith.traceOptions',
  );
  static const _stateKey = ContextKey<LangSmithState>('langsmith.state');

  /// A copy of [ctx] whose components are recorded with these options.
  ///
  /// Port of `SetTrace` and its options. Every call replaces all the options
  /// [ctx] had, as in Go:
  ///
  /// * [sessionName]: the LangSmith project (`WithSessionName`).
  /// * [tags]: the tags of every run, each once, in the order given
  ///   (`AddTag`).
  /// * [referenceExampleId]: the dataset example the runs are evaluated
  ///   against (`WithReferenceExampleID`).
  /// * [traceId]: a trace the first run joins (`WithTraceID`).
  /// * [metadata]: the `extra` of every run (`SetMetadata`). Put the metadata
  ///   LangSmith shows under its key `metadata`, as a map; the handler adds
  ///   the model settings there. The map is copied.
  static RunContext set(
    RunContext ctx, {
    String sessionName = '',
    Iterable<String> tags = const [],
    String referenceExampleId = '',
    String traceId = '',
    Map<String, Object?>? metadata,
  }) {
    final unique = <String>[];
    for (final tag in tags) {
      if (!unique.contains(tag)) unique.add(tag);
    }
    return ctx.withValue(
      _optionsKey,
      LangSmithTraceOptions(
        sessionName: sessionName,
        referenceExampleId: referenceExampleId,
        traceId: traceId,
        metadata: metadata == null ? null : Map.unmodifiable(metadata),
        tags: List.unmodifiable(unique),
      ),
    );
  }

  /// The options [set] stored in [ctx], or `null`.
  static LangSmithTraceOptions? optionsOf(RunContext ctx) =>
      ctx.value(_optionsKey);

  /// The state of the run [ctx] belongs to, or `null` when no LangSmith run
  /// is going on. Port of `GetState`.
  static LangSmithState? stateOf(RunContext ctx) => ctx.value(_stateKey);

  /// [ctx] with its state, and the state; a context without one is given one
  /// made from its options (the trace id of [set], no parent run).
  ///
  /// Port of `GetOrInitState`. A context that has a state is returned as it
  /// is.
  static (RunContext, LangSmithState) getOrInitState(RunContext ctx) {
    final existing = ctx.value(_stateKey);
    if (existing != null) return (ctx, existing);
    final state = LangSmithState(traceId: optionsOf(ctx)?.traceId ?? '');
    return (ctx.withValue(_stateKey, state), state);
  }

  /// A copy of [ctx] whose components are recorded as part of the run
  /// [state] describes, in its trace.
  ///
  /// The way to continue a trace that was carried here as text (see
  /// `LangSmithFlowTrace.stringToSpan`). Eino's handler stores its state
  /// the same way; this makes the operation public.
  static RunContext withState(RunContext ctx, LangSmithState state) =>
      ctx.withValue(_stateKey, state);
}
