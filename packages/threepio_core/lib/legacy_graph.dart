/// The state graph that predates the port of Eino's `compose` package:
/// `StateGraph`, `GraphBuilder`, `GraphState`, its checkpoint stores and
/// human-in-the-loop helpers, and the runnable over Dart `Stream`s that
/// `StateGraph.toRunnable()` returns.
///
/// The umbrella library exports the same graph API except for five checkpoint
/// names that the compose port uses for its own contracts (`CheckpointStore`,
/// `CheckpointSerializer`, `JsonCheckpointSerializer`,
/// `InMemoryCheckpointStore`, `FileCheckpointStore`). Import this library for
/// those, with a prefix when `compose.dart` or the umbrella is imported too:
///
/// ```dart
/// import 'package:threepio_core/legacy_graph.dart' as legacy;
///
/// final store = legacy.InMemoryCheckpointStore<MyState>();
/// ```
///
/// New code builds on `Graph` and `Chain` of
/// `package:threepio_core/compose.dart`.
library;

export 'src/graph/graph_exports.dart';
export 'src/graph/legacy_runnable.dart';
