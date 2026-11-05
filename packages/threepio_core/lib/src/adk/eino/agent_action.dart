/// What an agent asks of the run besides its output.
///
/// Port of eino `adk.AgentAction`.
library;

import 'package:meta/meta.dart';

import '../../compose/interrupt.dart';
import '../../schema/type_registry.dart';
import 'interrupt.dart';

/// An action an agent attaches to one of its events.
///
/// Port of eino `adk.AgentAction`. Of eino's fields, [interrupted] and
/// [customizedAction] are ported. `Exit`, `TransferToAgent` and `BreakLoop`
/// belong to agent transfer and workflow agents, which eino marks as not
/// recommended; they are not ported.
@immutable
final class AgentAction {
  /// An action with a custom payload, or the report of an interrupt.
  const AgentAction({this.interrupted, this.customizedAction})
      : interruptSignal = null;

  /// The action of an interrupt event, with the signal the runner saves.
  @internal
  const AgentAction.interruptedBy(
    AgentInterruptInfo this.interrupted,
    AddressedInterruptSignal this.interruptSignal,
  ) : customizedAction = null;

  /// An action from its JSON form; see [toJson].
  factory AgentAction.fromJson(Map<String, Object?> json) => AgentAction(
        interrupted: switch (json['interrupted']) {
          final Map<String, Object?> info => AgentInterruptInfo.fromJson(info),
          _ => null,
        },
        customizedAction: TypeRegistry.decode(json['customized_action']),
      );

  /// Set when the agent interrupted: what it reports and where the run can
  /// be resumed. Port of the field `Interrupted`.
  final AgentInterruptInfo? interrupted;

  /// Whatever the agent wants its caller to see. Port of the field
  /// `CustomizedAction`.
  final Object? customizedAction;

  /// The interrupt signal behind [interrupted]; the runner saves it in the
  /// checkpoint. Port of eino's unexported `internalInterrupted`.
  @internal
  final AddressedInterruptSignal? interruptSignal;

  /// This action with [data] as what the interrupted agent reports
  /// ([AgentInterruptInfo.data]), keeping the interrupt the runner saves.
  ///
  /// Go sets `event.Action.Interrupted.Data` on the event `adk.Interrupt`
  /// returned; actions are immutable here:
  ///
  /// ```dart
  /// final event = interruptEvent(ctx, info);
  /// yield event.copyWith(action: event.action!.withInterruptData(data));
  /// ```
  ///
  /// Throws [StateError] on an action that is not an interrupt.
  AgentAction withInterruptData(Object? data) {
    final current = interrupted;
    final signal = interruptSignal;
    if (current == null || signal == null) {
      throw StateError('withInterruptData needs the action of an interrupt event');
    }
    return AgentAction.interruptedBy(
      AgentInterruptInfo(
        data: data,
        interruptContexts: current.interruptContexts,
      ),
      signal,
    );
  }

  /// The JSON form. Values that are not JSON and not registered with
  /// [TypeRegistry] are written as their `toString()`.
  Map<String, Object?> toJson() => {
        if (interrupted != null) 'interrupted': interrupted!.toJson(),
        if (customizedAction != null)
          'customized_action':
              encodeOrDescribe(customizedAction, 'AgentAction.customizedAction'),
      };

  @override
  String toString() => interrupted != null
      ? 'AgentAction(interrupted: $interrupted)'
      : 'AgentAction(customizedAction: $customizedAction)';
}
