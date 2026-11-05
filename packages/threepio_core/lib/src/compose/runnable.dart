/// The contract of everything that can be run: a compiled graph, chain or
/// workflow, and the tools node.
library;

import '../core/run_context.dart';
import '../streaming/stream_reader.dart';
import 'call_options.dart';

/// Something that takes an [I] and gives an [O], in four ways.
///
/// Port of eino `compose.Runnable`. The four methods differ in whether the
/// input and the output are single values or streams:
///
/// | method      | input    | output   |
/// |-------------|----------|----------|
/// | [invoke]    | value    | value    |
/// | [stream]    | value    | stream   |
/// | [collect]   | stream   | value    |
/// | [transform] | stream   | stream   |
///
/// A compiled graph offers all four whatever its nodes implement: a node that
/// only knows how to answer with a value is given the joined chunks of a
/// stream, and its answer is passed on as a stream of one chunk.
///
/// [options] are the call options of this run: callbacks, options for the
/// components inside, the step limit. Each can be aimed at single nodes with
/// [CallOption.designateNode].
///
/// A returned stream belongs to the caller, who reads it to its end or closes
/// it.
abstract interface class Runnable<I, O> {
  /// Value in, value out. Port of eino `Runnable.Invoke`.
  Future<O> invoke(
    RunContext ctx,
    I input, {
    List<CallOption> options = const [],
  });

  /// Value in, stream out. Port of eino `Runnable.Stream`.
  Future<StreamReader<O>> stream(
    RunContext ctx,
    I input, {
    List<CallOption> options = const [],
  });

  /// Stream in, value out. Port of eino `Runnable.Collect`.
  Future<O> collect(
    RunContext ctx,
    StreamReader<I> input, {
    List<CallOption> options = const [],
  });

  /// Stream in, stream out. Port of eino `Runnable.Transform`.
  Future<StreamReader<O>> transform(
    RunContext ctx,
    StreamReader<I> input, {
    List<CallOption> options = const [],
  });
}
