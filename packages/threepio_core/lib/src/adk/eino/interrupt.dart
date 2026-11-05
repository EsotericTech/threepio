/// Interrupt and resume for agents, and the checkpoint the runner keeps.
///
/// Port of eino `adk/interrupt.go` and of `ChatModelAgentInterruptInfo` /
/// `ChatModelAgentResumeData` in `adk/chatmodel.go`.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../compose/address.dart';
import '../../compose/checkpoint_serializer.dart';
import '../../compose/checkpoint_store.dart';
import '../../compose/interrupt.dart';
import '../../compose/resume.dart';
import '../../core/interrupt_signal.dart';
import '../../core/run_context.dart';
import '../../errors.dart';
import '../../schema/message.dart';
import '../../schema/type_registry.dart';
import 'agent.dart';
import 'agent_action.dart';
import 'agent_context.dart';
import 'agent_event.dart';
import 'react_graph.dart';

/// The address segment of an agent. Port of eino `adk.AddressSegmentAgent`.
const AddressSegmentType addressSegmentAgent = AddressSegmentType('agent');

/// The address segment of a tool call. Port of eino
/// `adk.AddressSegmentTool`.
const AddressSegmentType addressSegmentTool = AddressSegmentType.tool;

/// The segment kinds the interrupt contexts of an agent run keep. Port of
/// eino `allowedAddressSegmentTypes`.
@internal
const List<AddressSegmentType> allowedAddressSegmentTypes = [
  addressSegmentAgent,
  addressSegmentTool,
];

/// What an interrupted agent run reports.
///
/// Port of eino `adk.InterruptInfo` (named `AgentInterruptInfo` because the
/// compose library has an `InterruptInfo` of its own, `GraphInterruptInfo`).
/// [interruptContexts] are the points to resume, one per root cause, each
/// with its id, its address and what it reported.
@immutable
final class AgentInterruptInfo {
  /// The report of an interrupt.
  AgentInterruptInfo({this.data, List<InterruptCtx> interruptContexts = const []})
      : interruptContexts = List.unmodifiable(interruptContexts);

  /// A report from its JSON form; see [toJson].
  factory AgentInterruptInfo.fromJson(Map<String, Object?> json) =>
      AgentInterruptInfo(
        data: TypeRegistry.decode(json['data']),
        interruptContexts: [
          for (final context
              in (json['interrupt_contexts'] as List<Object?>?) ?? const [])
            InterruptCtx.fromJson(context! as Map<String, Object?>),
        ],
      );

  /// What the interrupted agent reports about itself. A `ChatModelAgent`
  /// puts a [ChatModelAgentInterruptInfo] here. Port of the field `Data`.
  final Object? data;

  /// The points to resume. Pass their ids to `Runner.resumeWithParams`.
  final List<InterruptCtx> interruptContexts;

  /// The JSON form. Values that are neither JSON nor registered are written
  /// as their `toString()`.
  Map<String, Object?> toJson() => {
        if (data != null) 'data': encodeOrDescribe(data, 'AgentInterruptInfo.data'),
        'interrupt_contexts': [
          for (final context in interruptContexts) context.toJson(),
        ],
      };

  @override
  String toString() => 'AgentInterruptInfo(data: $data, '
      'interruptContexts: $interruptContexts)';
}

/// What an agent is told when it resumes.
///
/// Port of eino `adk.ResumeInfo` (without its deprecated embedded
/// `InterruptInfo`).
@immutable
final class ResumeInfo {
  /// The resume information of one agent.
  const ResumeInfo({
    this.enableStreaming = false,
    this.wasInterrupted = false,
    this.interruptState,
    this.isResumeTarget = false,
    this.resumeData,
  });

  /// Whether the run that interrupted was streaming.
  final bool enableStreaming;

  /// Whether this agent itself interrupted (and was not only on the way to
  /// the agent that did).
  final bool wasInterrupted;

  /// The state the agent saved with its interrupt.
  final Object? interruptState;

  /// Whether the caller resumes this agent explicitly
  /// (`Runner.resumeWithParams` named it).
  final bool isResumeTarget;

  /// The data the caller sent to this agent.
  final Object? resumeData;

  @override
  String toString() => 'ResumeInfo(streaming: $enableStreaming, '
      'wasInterrupted: $wasInterrupted, isResumeTarget: $isResumeTarget)';
}

/// What a `ChatModelAgent` reports when its graph interrupts.
///
/// Port of eino `adk.ChatModelAgentInterruptInfo`: the report of its graph
/// and the graph's checkpoint.
@immutable
final class ChatModelAgentInterruptInfo {
  /// The report of an interrupted `ChatModelAgent`.
  const ChatModelAgentInterruptInfo({required this.info, required this.data});

  /// A report from its JSON form; see [toJson].
  factory ChatModelAgentInterruptInfo.fromJson(Map<String, Object?> json) =>
      ChatModelAgentInterruptInfo(
        info: GraphInterruptInfo.fromJson(json['info']! as Map<String, Object?>),
        data: base64Decode(json['data']! as String),
      );

  /// The interrupt report of the agent's graph.
  final GraphInterruptInfo info;

  /// The checkpoint of the agent's graph.
  final Uint8List data;

  /// The JSON form; the checkpoint is written as Base64.
  Map<String, Object?> toJson() => {
        'info': info.toJson(),
        'data': base64Encode(data),
      };
}

/// What a `ChatModelAgent` can be given when it resumes, through
/// `Runner.resumeWithParams` with the agent's interrupt id.
///
/// Port of eino `adk.ChatModelAgentResumeData`.
@immutable
final class ChatModelAgentResumeData {
  /// Resume data with an optional [historyModifier].
  const ChatModelAgentResumeData({this.historyModifier});

  /// Rewrites the agent's history before the run goes on, for example to add
  /// what the user said while the agent was waiting.
  final List<Message> Function(RunContext ctx, List<Message> history)?
      historyModifier;
}

/// What to resume a run with. Port of eino `adk.ResumeParams`.
@immutable
final class ResumeParams {
  /// Parameters that resume the interrupt points in [targets].
  const ResumeParams({this.targets = const {}});

  /// By interrupt id, the data each point gets; `null` resumes a point
  /// without data.
  final Map<String, Object?> targets;
}

/// An event that interrupts the run, with [info] for the caller.
///
/// Port of eino `adk.Interrupt`. An agent sends it as its last event; the
/// runner saves a checkpoint (with `AgentRunOption.checkpointId`), and
/// `Runner.resume` continues the run at this agent.
AgentEvent interruptEvent(RunContext ctx, Object? info) =>
    _interruptEvent(ctx, info, null, const []);

/// Like [interruptEvent], and [state] is saved with the interrupt; the agent
/// gets it back as [ResumeInfo.interruptState]. Port of eino
/// `adk.StatefulInterrupt`. [state] must be JSON or of a type registered
/// with `TypeRegistry`.
AgentEvent statefulInterruptEvent(
  RunContext ctx,
  Object? info,
  Object? state,
) =>
    _interruptEvent(ctx, info, state, const []);

/// An interrupt of an agent that wraps the interrupts of what it ran
/// ([subSignals]: interrupt signals or `GraphInterruptedException`s). Port of
/// eino `adk.CompositeInterrupt`.
AgentEvent compositeInterruptEvent(
  RunContext ctx,
  Object? info,
  Object? state,
  List<InterruptSignal> subSignals,
) =>
    _interruptEvent(ctx, info, state, subSignals);

AgentEvent _interruptEvent(
  RunContext ctx,
  Object? info,
  Object? state,
  List<Object> subSignals,
) {
  final InterruptSignal signal;
  try {
    signal = compositeInterrupt(ctx, info, state, subSignals);
    // compositeInterrupt reports a sub error that is not an interrupt as an
    // ArgumentError; eino returns it as the event's error.
    // ignore: avoid_catching_errors
  } on ArgumentError catch (error, stackTrace) {
    return AgentEvent(error: error, stackTrace: stackTrace);
  }
  final addressed = signal as AddressedInterruptSignal;
  return AgentEvent(
    action: AgentAction.interruptedBy(
      AgentInterruptInfo(
        interruptContexts: toInterruptContexts(
          addressed,
          allowedSegmentTypes: allowedAddressSegmentTypes,
        ),
      ),
      addressed,
    ),
  );
}

/// The checkpoint id a `ChatModelAgent` and an `AgentTool` give their inner
/// graph or runner. Port of eino `bridgeCheckpointID`.
@internal
const String bridgeCheckpointId = 'adk_react_mock_key';

/// A store for the one checkpoint of an inner graph or runner, whose bytes
/// the outer layer then keeps in its own interrupt state. Port of eino
/// `bridgeStore`.
@internal
final class BridgeStore implements CheckpointStore {
  /// An empty store.
  BridgeStore();

  /// A store that holds [data] under [id], for a resume. Port of eino
  /// `newResumeBridgeStore`.
  BridgeStore.resume(String id, Uint8List data)
      : _data = {id: Uint8List.fromList(data)};

  Map<String, Uint8List> _data = {};

  @override
  Future<Uint8List?> get(String key) async {
    final value = _data[key];
    return value == null ? null : Uint8List.fromList(value);
  }

  @override
  Future<void> set(String key, Uint8List value) async {
    _data = {..._data, key: Uint8List.fromList(value)};
  }
}

/// The checkpoint a `Runner` saves. Port of eino `serialization`, without
/// the deprecated `Info` field and without the event history of agent
/// transfer.
@internal
final class AdkCheckpoint {
  /// A checkpoint of a run.
  AdkCheckpoint({
    required this.sessionValues,
    required this.enableStreaming,
    required this.interruptId2Address,
    required this.interruptId2State,
    this.rootInput,
  });

  /// A checkpoint from its JSON form.
  factory AdkCheckpoint.fromJson(Map<String, Object?> json) => AdkCheckpoint(
        sessionValues: {
          for (final MapEntry(:key, :value)
              in ((json['session_values'] as Map<String, Object?>?) ?? const {})
                  .entries)
            key: TypeRegistry.decode(value),
        },
        rootInput: switch (json['root_input']) {
          final Map<String, Object?> input => AgentInput.fromJson(input),
          _ => null,
        },
        enableStreaming: json['enable_streaming'] == true,
        interruptId2Address: {
          for (final MapEntry(:key, :value)
              in (json['interrupt_id_to_address']! as Map<String, Object?>)
                  .entries)
            key: Address.fromJson(value! as List<Object?>),
        },
        interruptId2State: {
          for (final MapEntry(:key, :value)
              in (json['interrupt_id_to_state']! as Map<String, Object?>)
                  .entries)
            key: InterruptState.fromJson(value! as Map<String, Object?>),
        },
      );

  final Map<String, Object?> sessionValues;
  final AgentInput? rootInput;
  final bool enableStreaming;
  final Map<String, Address> interruptId2Address;
  final Map<String, InterruptState> interruptId2State;

  /// The JSON form. Session values and saved states must be JSON or of a
  /// registered type.
  Map<String, Object?> toJson() => {
        'session_values': {
          for (final MapEntry(:key, :value) in sessionValues.entries)
            key: TypeRegistry.encode(value),
        },
        if (rootInput != null) 'root_input': rootInput!.toJson(),
        'enable_streaming': enableStreaming,
        'interrupt_id_to_address': {
          for (final MapEntry(:key, :value) in interruptId2Address.entries)
            key: value.toJson(),
        },
        'interrupt_id_to_state': {
          for (final MapEntry(:key, :value) in interruptId2State.entries)
            key: value.toJson(),
        },
      };
}

/// Registers the types the ADK writes into checkpoints, under eino's names.
/// Idempotent; survives `TypeRegistry.reset()` when called again.
@internal
void ensureAdkTypesRegistered() {
  if (!TypeRegistry.isRegistered<AdkCheckpoint>()) {
    TypeRegistry.registerName<AdkCheckpoint>(
      '_eino_adk_serialization',
      fromJson: AdkCheckpoint.fromJson,
      toJson: (checkpoint) => checkpoint.toJson(),
    );
  }
  if (!TypeRegistry.isRegistered<ChatModelAgentInterruptInfo>()) {
    TypeRegistry.registerName<ChatModelAgentInterruptInfo>(
      '_eino_adk_chat_model_agent_interrupt_info',
      fromJson: ChatModelAgentInterruptInfo.fromJson,
      toJson: (info) => info.toJson(),
    );
  }
  registerReactTypes();
}

/// Saves the checkpoint of the run [ctx] belongs to under [key]. Port of
/// eino `runnerSaveCheckPointImpl`.
@internal
Future<void> saveAdkCheckpoint({
  required bool enableStreaming,
  required CheckpointStore store,
  required RunContext ctx,
  required String key,
  required AddressedInterruptSignal signal,
}) async {
  ensureAdkTypesRegistered();
  final run = adkRunContextOf(ctx);
  final (addresses, states) = signalToPersistenceMaps(signal);
  final checkpoint = AdkCheckpoint(
    sessionValues: Map.of(run?.session.values ?? const {}),
    rootInput: run?.rootInput,
    enableStreaming: enableStreaming,
    interruptId2Address: addresses,
    interruptId2State: states,
  );
  await store.set(key, const JsonCheckpointSerializer().serialize(checkpoint));
}

/// Loads the checkpoint [id]: the context to resume in, the restored run and
/// what the agent resumes with. Port of eino `runnerLoadCheckPointImpl`.
@internal
Future<(RunContext, AdkRunContext, ResumeInfo)> loadAdkCheckpoint(
  CheckpointStore store,
  RunContext ctx,
  String id,
) async {
  ensureAdkTypesRegistered();
  final Uint8List? data;
  try {
    data = await store.get(id);
    // Whatever the store throws.
    // ignore: avoid_catches_without_on_clauses
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(
      ThreepioException('failed to get checkpoint from store: $error',
          cause: error),
      stackTrace,
    );
  }
  if (data == null) throw ThreepioException('checkpoint[$id] not exist');
  final Object? decoded;
  try {
    decoded = const JsonCheckpointSerializer().deserialize(data);
    // A checkpoint that cannot be read, whatever the decoder throws.
    // ignore: avoid_catches_without_on_clauses
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(
      ThreepioException('failed to decode checkpoint: $error', cause: error),
      stackTrace,
    );
  }
  if (decoded is! AdkCheckpoint) {
    throw ThreepioException(
      'failed to decode checkpoint: not an agent checkpoint '
      '(${decoded.runtimeType})',
    );
  }
  final resumed = populateInterruptState(
    ctx,
    decoded.interruptId2Address,
    decoded.interruptId2State,
  );
  return (
    resumed,
    AdkRunContext(
      session: RunSession(Map.of(decoded.sessionValues)),
      rootInput: decoded.rootInput,
    ),
    ResumeInfo(enableStreaming: decoded.enableStreaming),
  );
}

/// [ctx] at the agent [agentName] and what that agent resumes with. Port of
/// eino `buildResumeInfo`.
@internal
(RunContext, ResumeInfo) buildResumeInfo(
  RunContext ctx,
  String agentName,
  ResumeInfo info,
) {
  var next = appendAddressSegmentTo(ctx, addressSegmentAgent, agentName);
  final interrupted = getInterruptState<Object>(next);
  var isResumeTarget = false;
  Object? resumeData;
  if (interrupted.wasInterrupted) {
    final resume = getResumeContext<Object>(next);
    isResumeTarget = resume.isResumeTarget;
    if (resume.hasData) resumeData = resume.data;
  }
  final run = adkRunContextOf(next);
  if (run != null) {
    next = withAdkRunContext(
      next,
      AdkRunContext(
        session: run.session,
        rootInput: run.rootInput,
        depth: run.depth + 1,
      ),
    );
  }
  return (
    next,
    ResumeInfo(
      enableStreaming: info.enableStreaming,
      wasInterrupted: interrupted.wasInterrupted,
      interruptState: interrupted.hasState ? interrupted.state : null,
      isResumeTarget: isResumeTarget,
      resumeData: resumeData,
    ),
  );
}

/// The one child of the current agent on the way to the interrupt. Port of
/// eino `getNextResumeAgent`.
@internal
String nextResumeAgent(RunContext ctx) {
  final next = nextResumptionPoints(ctx);
  if (next == null) {
    throw const ThreepioException(
      'failed to get next agent leading to interruption: '
      'no resume info in the context',
    );
  }
  if (next.isEmpty) {
    throw const ThreepioException(
      'no child agents leading to interrupted agent were found',
    );
  }
  if (next.length > 1) {
    throw const ThreepioException(
      'agent has multiple child agents leading to interruption, but '
      'concurrent transfer is not supported',
    );
  }
  return next.single;
}
