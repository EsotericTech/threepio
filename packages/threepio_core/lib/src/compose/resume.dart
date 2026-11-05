/// Resuming an interrupted run: what a component finds of its interrupt, and
/// how a caller says which interrupt points go on.
///
/// Port of eino `compose/resume.go`, `internal/core/resume.go` and the
/// context half of `internal/core/address.go`.
library;

import 'package:meta/meta.dart';

import '../core/run_context.dart';
import 'address.dart';
import 'checkpoint_serializer.dart';
import 'graph_interrupt.dart';
import 'interrupt.dart';
import 'node_path.dart';

/// What the context knows about the place it belongs to.
///
/// Port of eino `addrCtx`. One object per address; it is filled in when the
/// address is entered and, for the place a checkpoint is loaded at, when the
/// checkpoint arrives.
final class _AddressContext {
  _AddressContext(this.address);

  final Address address;
  InterruptState? interruptState;
  bool isResumeTarget = false;
  Object? resumeData;
}

/// What one resumed run knows about the interrupts it continues: where each
/// was raised, what it saved, what the caller resumes it with, and what of
/// that has been handed out already.
///
/// Port of eino `globalResumeInfo`. It is shared by every context of the run
/// and filled as checkpoints are loaded, nested ones included.
final class _ResumeInfo {
  final Map<String, Object?> resumeData = {};
  final Set<String> resumeDataUsed = {};
  final Map<String, InterruptState> states = {};
  final Set<String> statesUsed = {};
  final Map<String, Address> addresses = {};
}

final _addressKey = ContextKey<_AddressContext>('compose.address');
final _resumeKey = ContextKey<_ResumeInfo>('compose.resumeInfo');

/// [ctx] at the address one segment further in.
///
/// Port of eino `core.AppendAddressSegment`. When the run continues an
/// interrupt that was raised at the new address, the context gets the state
/// saved there and the data it is resumed with.
@internal
RunContext appendAddressSegmentTo(
  RunContext ctx,
  AddressSegmentType type,
  String id, [
  String subId = '',
]) {
  final address = ctx.currentAddress
      .append(AddressSegment(type: type, id: id, subId: subId));
  final own = _AddressContext(address);
  final next = ctx.withValue(_addressKey, own);

  final resumeInfo = ctx.value(_resumeKey);
  if (resumeInfo == null) return next;

  // The interrupt raised here, when its state has not been handed out yet.
  var interruptId = '';
  for (final MapEntry(key: candidate, value: raisedAt)
      in resumeInfo.addresses.entries) {
    if (raisedAt == address && !resumeInfo.statesUsed.contains(candidate)) {
      own.interruptState = resumeInfo.states[candidate] ?? const InterruptState();
      resumeInfo.statesUsed.add(candidate);
      interruptId = candidate;
      break;
    }
  }

  if (!resumeInfo.resumeDataUsed.contains(interruptId) &&
      resumeInfo.resumeData.containsKey(interruptId)) {
    resumeInfo.resumeDataUsed.add(interruptId);
    own
      ..resumeData = resumeInfo.resumeData[interruptId]
      ..isResumeTarget = true;
  }

  if (!own.isResumeTarget) {
    // A component is also resumed when something inside it still is to be:
    // it has to run its parts so that they are reached.
    for (final MapEntry(key: candidate, value: raisedAt)
        in resumeInfo.addresses.entries) {
      if (address.isStrictPrefixOf(raisedAt) &&
          !resumeInfo.resumeDataUsed.contains(candidate)) {
        own.isResumeTarget = true;
        break;
      }
    }
  }
  return next;
}

/// [ctx] for the tool call [callId] of the tool [name].
///
/// Port of eino `appendToolAddressSegment`.
@internal
RunContext appendToolAddressSegment(RunContext ctx, String name, String callId) =>
    appendAddressSegmentTo(ctx, AddressSegmentType.tool, name, callId);

/// [ctx] knowing the interrupts of a checkpoint that was just loaded: where
/// each was raised and what it saved.
///
/// Port of eino `core.PopulateInterruptState`. The place [ctx] itself is at
/// gets its state and its resume data here, because it was entered before
/// the checkpoint was read.
@internal
RunContext populateInterruptState(
  RunContext ctx,
  Map<String, Address> addresses,
  Map<String, InterruptState> states,
) {
  var next = ctx;
  var resumeInfo = ctx.value(_resumeKey);
  if (resumeInfo == null) {
    resumeInfo = _ResumeInfo();
    next = ctx.withValue(_resumeKey, resumeInfo);
  }
  resumeInfo.addresses.addAll(addresses);
  resumeInfo.states.addAll(states);

  final own = ctx.value(_addressKey);
  if (own != null) {
    for (final MapEntry(key: id, value: raisedAt) in addresses.entries) {
      if (raisedAt != own.address) continue;
      if (!resumeInfo.statesUsed.contains(id)) {
        own.interruptState = resumeInfo.states[id] ?? const InterruptState();
        resumeInfo.statesUsed.add(id);
      }
      if (!resumeInfo.resumeDataUsed.contains(id)) {
        own
          ..isResumeTarget = true
          ..resumeData = resumeInfo.resumeData[id];
        resumeInfo.resumeDataUsed.add(id);
      }
      break;
    }
  }
  return next;
}

/// The ids of the places directly inside the address of [ctx] that lead to an
/// interrupt point of the resumed run, or `null` when the run resumes
/// nothing.
///
/// Port of eino `core.GetNextResumptionPoints`.
@internal
Set<String>? nextResumptionPoints(RunContext ctx) {
  final resumeInfo = ctx.value(_resumeKey);
  if (resumeInfo == null) return null;
  final parent = ctx.currentAddress;
  return {
    for (final raisedAt in resumeInfo.addresses.values)
      if (parent.isStrictPrefixOf(raisedAt))
        raisedAt.segments[parent.length].id,
  };
}

/// The path of [ctx] through nested graphs: the node keys since the graph
/// that was last run on its own. The flag says whether [ctx] belongs to a
/// graph that runs as a node of another graph.
///
/// Port of eino `getNodePath`.
@internal
(NodePath, bool) nodePathOf(RunContext ctx) {
  var path = <String>[];
  for (final segment in ctx.currentAddress.segments) {
    if (segment.type == AddressSegmentType.runnable) {
      path = <String>[];
    } else {
      path.add(segment.id);
    }
  }
  return (NodePath(path), path.isNotEmpty);
}

/// Whether the component [ctx] belongs to interrupted on the run that is
/// being resumed, and the state it saved then.
///
/// Port of eino `compose.GetInterruptState`. A component that can interrupt
/// calls it first to tell its first run from a resumed one:
///
/// ```dart
/// final previous = getInterruptState<ReviewState>(ctx);
/// if (!previous.wasInterrupted) {
///   throw statefulInterrupt(ctx, 'Please review', ReviewState(draft));
/// }
/// final draft = previous.state!.draft;
/// ```
///
/// `wasInterrupted` is true when the component at this address raised an
/// interrupt, with or without state. `hasState` is true when it saved a state
/// and that state is a [T]; `state` is then that state. A state that went
/// through a checkpoint store is rebuilt from JSON: a state of a class of
/// your own needs `TypeRegistry.registerName`.
({bool wasInterrupted, bool hasState, T? state})
    getInterruptState<T extends Object>(RunContext ctx) {
  final saved = ctx.value(_addressKey)?.interruptState;
  if (saved == null) {
    return (wasInterrupted: false, hasState: false, state: null);
  }
  final state = reviveAs<T>(saved.state);
  return (wasInterrupted: true, hasState: state != null, state: state);
}

/// The saved state of the interrupt raised at the address of [ctx], with what
/// the layer that raised it kept for itself.
@internal
InterruptState? interruptStateOf(RunContext ctx) =>
    ctx.value(_addressKey)?.interruptState;

/// Whether the caller resumes the component [ctx] belongs to, and the data it
/// resumes it with.
///
/// Port of eino `compose.GetResumeContext`. Typically called after
/// [getInterruptState] said that the component was interrupted.
///
/// `isResumeTarget` is true when the caller named the interrupt point of this
/// component, or of a component inside it, with `ctx.resume`,
/// `ctx.resumeWithData` or `ctx.batchResumeWithData`. `hasData` is true when
/// data was given for this very component and it is a [T]; `data` is then
/// that data.
///
/// How to use the answer depends on the application:
///
/// * When resuming means that every interrupted point goes on (one
///   "continue" button), a component only needs [getInterruptState] and may
///   look here for optional data.
/// * When interrupt points are resumed one by one, a component that is not a
///   resume target must interrupt again (with the state it has), so that it
///   stays in the checkpoint until its turn comes:
///
///   ```dart
///   final resumed = getResumeContext<Decision>(ctx);
///   if (!resumed.isResumeTarget) {
///     throw statefulInterrupt(ctx, question, previous.state);
///   }
///   ```
///
/// A component that runs parts of its own gets `isResumeTarget` with
/// `hasData == false` when one of its parts is the target: it runs its parts
/// and lets the resume reach them.
({bool isResumeTarget, bool hasData, T? data})
    getResumeContext<T extends Object>(RunContext ctx) {
  final own = ctx.value(_addressKey);
  if (own == null || !own.isResumeTarget) {
    return (isResumeTarget: false, hasData: false, data: null);
  }
  final data = own.resumeData;
  return data is T
      ? (isResumeTarget: true, hasData: true, data: data)
      : (isResumeTarget: true, hasData: false, data: null);
}

/// Addresses, resuming and interrupting from outside, on the run context.
///
/// Port of the context functions of eino `compose/resume.go` and of
/// `compose.WithGraphInterrupt`.
extension InterruptContext on RunContext {
  /// Where in the run this context is: the graphs, nodes and tool calls that
  /// lead to the component it was given to. Empty outside any graph.
  ///
  /// Port of eino `compose.GetCurrentAddress`.
  Address get currentAddress =>
      value(_addressKey)?.address ?? const Address.empty();

  /// A context one step further in: for a component that runs parts of its
  /// own which can interrupt, the context of one such part.
  ///
  /// Port of eino `compose.AppendAddressSegment`. Graphs and tools nodes do
  /// this for their nodes and tool calls. A component of your own that runs
  /// several graphs side by side gives each its own segment, so that their
  /// interrupt points have different addresses.
  RunContext appendAddressSegment(AddressSegmentType type, String id) =>
      appendAddressSegmentTo(this, type, id);

  /// A context for the resumed run that continues the interrupt points with
  /// the given ids, without giving them data.
  ///
  /// Port of eino `compose.Resume`. The ids are those of
  /// `GraphInterruptInfo.interruptContexts`.
  RunContext resume(List<String> interruptIds) =>
      batchResumeWithData({for (final id in interruptIds) id: null});

  /// A context for the resumed run that continues the interrupt point
  /// [interruptId] and hands it [data] (see [getResumeContext]).
  ///
  /// Port of eino `compose.ResumeWithData`.
  RunContext resumeWithData(String interruptId, Object? data) =>
      batchResumeWithData({interruptId: data});

  /// A context for the resumed run that continues the interrupt points that
  /// are the keys of [data], each with its value as resume data; `null`
  /// resumes without data.
  ///
  /// Port of eino `compose.BatchResumeWithData`. Called on a context that
  /// already resumes some points, it adds to them and returns the same
  /// context.
  RunContext batchResumeWithData(Map<String, Object?> data) {
    final resumeInfo = value(_resumeKey);
    if (resumeInfo != null) {
      resumeInfo.resumeData.addAll(data);
      return this;
    }
    return withValue(_resumeKey, _ResumeInfo()..resumeData.addAll(data));
  }

  /// A context whose runs can be interrupted from outside, and the handle
  /// that does it.
  ///
  /// Port of eino `compose.WithGraphInterrupt`. A graph that is run with the
  /// returned context stops when [GraphInterrupter.interrupt] is called: it
  /// waits for the nodes that are running (for as long as the `timeout` of
  /// that call allows), writes a checkpoint and fails with a
  /// `GraphInterruptedException`, exactly as for an interrupt from inside.
  ///
  /// ```dart
  /// final (runCtx, interrupter) = ctx.withGraphInterrupt();
  /// final run = runnable.invoke(runCtx, input, options: [CallOption.checkpointId(id)]);
  /// stopButton.onPressed = () => interrupter.interrupt(timeout: const Duration(seconds: 2));
  /// ```
  ///
  /// Under such a context every node, also inside nested graphs, has its
  /// input kept until it has finished. A node that is still running when the
  /// timeout ends is abandoned and runs again, with that input, when the run
  /// is resumed. (An interrupt from inside a node does not keep the input:
  /// the node saves what it needs with `statefulInterrupt`.)
  (RunContext, GraphInterrupter) withGraphInterrupt() {
    final signal = GraphCancelSignal();
    return (withGraphCancelSignal(this, signal), GraphInterrupter.of(signal));
  }
}
