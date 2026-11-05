/// The marker of an interrupt on its way up the call stack.
library;

import '../errors.dart';

/// Thrown to pause a run at the point where it is thrown, so that the run can
/// be resumed there later.
///
/// Port of the role of eino's interrupt errors (`compose.Interrupt`,
/// `compose.StatefulInterrupt`, `compose.CompositeInterrupt`). This type is
/// only the marker: the functions that create a signal and the engine that
/// catches it, stores a checkpoint and reports the interrupt belong to the
/// compose library.
///
/// An interrupt is not a failure. **Code that catches the errors of a tool or
/// of a graph node must let it through**, also when it arrives wrapped in
/// another exception; [isInterrupt] recognises both:
///
/// ```dart
/// try {
///   return await tool.invokableRun(ctx, arguments);
/// } on Exception catch (error) {
///   if (isInterrupt(error)) rethrow;
///   return 'The tool failed: $error';
/// }
/// ```
///
/// A handler that turns a signal into a tool result makes the run continue as
/// if nothing had asked it to stop, and the checkpoint that would have let
/// the user resume is never written.
abstract interface class InterruptSignal implements Exception {}

/// Whether [error] is an [InterruptSignal], or a [ThreepioException] that was
/// raised because of one.
///
/// Port of the check eino makes with `compose.IsInterruptRerunError`, which
/// looks through wrapped errors with `errors.As`. A layer between the tool
/// and the handler (a graph node, a nested agent) may wrap what it rethrows
/// and keep the original as the `cause`; the interrupt still has to get
/// through.
bool isInterrupt(Object? error) =>
    ThreepioException.findCause<InterruptSignal>(error) != null;
