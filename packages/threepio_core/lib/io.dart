/// The parts of threepio that need `dart:io`: files, processes, sockets.
///
/// Everything else in the package runs on every platform Dart runs on; what
/// is exported here does not run on the web. Import it next to the library
/// whose types it implements:
///
/// ```dart
/// import 'package:threepio_core/compose.dart';
/// import 'package:threepio_core/io.dart';
///
/// final store = FileCheckpointStore(Directory('checkpoints'));
/// ```
///
/// [FileCheckpointStore] here is the checkpoint store of the compose graphs.
/// The store of the same name that belongs to the older state graph is in
/// `package:threepio_core/legacy_graph.dart`.
library;

export 'src/compose/stores/file_checkpoint_store.dart';
