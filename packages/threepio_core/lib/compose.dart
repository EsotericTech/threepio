/// Orchestration: runnables, lambdas, graphs, chains, workflows and the tools
/// node, with interrupt, checkpoint and resume.
///
/// Port of the Eino package `compose`. A [Graph], a [Chain] or a [Workflow]
/// connects components (chat models, templates, retrievers, a [ToolsNode])
/// and [Lambda]s; compiled, it is a [Runnable] that can be invoked or
/// streamed.
///
/// ```dart
/// import 'package:threepio_core/compose.dart';
///
/// final chain = Chain<Map<String, dynamic>, Message>()
///   ..appendChatTemplate(template)
///   ..appendChatModel(model);
/// final runnable = await chain.compile(ctx);
/// final answer = await runnable.invoke(ctx, {'topic': 'graphs'});
/// ```
///
/// A run can be paused and continued later: a node throws [interrupt], or the
/// graph is compiled with nodes to stop in front of or behind, or the caller
/// interrupts it from outside (`ctx.withGraphInterrupt()`). With a
/// [CheckpointStore] and a checkpoint id the run is saved and goes on from
/// there when the graph is called again; see [GraphInterruptedException].
///
/// The library also exports what its own signatures need: the schema types
/// (`schema.dart`), streams (`streaming.dart`), the component contracts and
/// their options (`components.dart`) and the callback handler type.
///
/// The state graph that came before this port (`StateGraph`, `GraphBuilder`)
/// is unrelated and stays available from the umbrella library and from
/// `package:threepio_core/legacy_graph.dart`.
library;

export 'components.dart';
export 'schema.dart';
export 'src/callbacks/component_callback_handler.dart';
export 'src/callbacks/run_info.dart';
export 'src/compose/address.dart';
export 'src/compose/agentic_tools_node.dart' show AgenticToolsNode;
export 'src/compose/batch_node.dart';
export 'src/compose/call_options.dart';
export 'src/compose/chain.dart';
export 'src/compose/chain_branch.dart';
export 'src/compose/checkpoint.dart' show migrateCheckpointState;
export 'src/compose/checkpoint_serializer.dart' show JsonCheckpointSerializer;
export 'src/compose/checkpoint_store.dart';
export 'src/compose/errors.dart' hide wrapGraphNodeError;
export 'src/compose/field_addressable.dart';
export 'src/compose/field_mapping.dart'
    show FieldExtractor, FieldMapping, FieldMappingException;
export 'src/compose/graph.dart' show AnyGraph, Graph;
export 'src/compose/graph_interrupt.dart' show GraphInterrupter;
export 'src/compose/interrupt.dart'
    show
        GraphInterruptInfo,
        GraphInterruptedException,
        InterruptCtx,
        compositeInterrupt,
        extractInterruptInfo,
        interrupt,
        statefulInterrupt;
export 'src/compose/graph_branch.dart' hide newGraphBranch;
export 'src/compose/graph_options.dart';
export 'src/compose/introspect.dart';
export 'src/compose/lambda.dart';
export 'src/compose/local_state.dart'
    hide InternalState, internalStateOf, withInternalState;
export 'src/compose/node_path.dart';
export 'src/compose/parallel.dart';
export 'src/compose/resume.dart'
    show InterruptContext, getInterruptState, getResumeContext;
export 'src/compose/runnable.dart';
export 'src/compose/tool_middleware.dart';
export 'src/compose/tools_node.dart'
    hide registerToolsNodeTypes, remapArguments;
export 'src/compose/tools_node_options.dart';
export 'src/compose/values_merge.dart' hide mergeValues;
export 'src/compose/workflow.dart';
export 'streaming.dart';
