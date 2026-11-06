/// Tool infos that depend on the run.
///
/// Go's `tool.BaseTool.Info(ctx)` takes the run's context; Dart's
/// `BaseTool.info()` does not (the contract is older than `RunContext`). A
/// tool whose description depends on the run (the skill tool lists the
/// skills of a backend that may read session values; the deep agent's `task`
/// tool asks a description generator) implements this as well. The
/// `ChatModelAgent` asks it with the run's context for the tools middlewares
/// add in `beforeAgent`, and a `ToolsNode` asks it with the context it is
/// created or called with (Go's `NewToolNode(ctx, …)` and `convTools(ctx, …)`).
@internal
library;

import 'package:meta/meta.dart';

import '../../core/run_context.dart';
import '../../schema/tool_info.dart';

/// A tool whose info can be built with the run's context.
@internal
abstract interface class RunContextToolInfo {
  /// The tool's info for the run of [ctx]. Port of Go's `Info(ctx)`.
  Future<ToolInfo> infoWithContext(RunContext ctx);
}
