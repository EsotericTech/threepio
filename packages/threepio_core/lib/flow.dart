/// Ready-made retrieval flows: retrievers built from other retrievers, and
/// the indexer that goes with one of them.
///
/// Port of the Eino package `flow` (its `retriever` and `indexer` parts):
///
/// * `MultiQueryRetriever.fromConfig` (`flow/retriever/multiquery`): a chat
///   model or a function rewrites the query into several, each is retrieved
///   from the same retriever, and the results are fused.
/// * `ParentRetriever.fromConfig` (`flow/retriever/parent`): finds small
///   documents and returns the documents they were cut from, by the parent
///   id each keeps in its metadata.
/// * `RouterRetriever.fromConfig` (`flow/retriever/router`): a router picks
///   retrievers, each is asked, and the results are fused by reciprocal
///   rank.
/// * `ParentIndexer` (`flow/indexer/parent`): cuts documents into pieces and
///   stores them with their parent's id, for the parent retriever.
/// * `concurrentRetrieve` and `RetrieveTask` (`flow/retriever/utils`): runs
///   retrievals side by side, each reported to the callback handlers.
///
/// The three retrievers are static methods of the retriever classes threepio
/// already had, whose own constructors and behaviour are unchanged; what they
/// return is a plain `Retriever`, usable on its own or as a node of a graph
/// or chain (`addRetrieverNode`, `appendRetriever`). The library also
/// exports `components.dart` and `schema.dart`, whose types its signatures
/// use.
///
/// Eino's `flow/agent` packages (the ReAct agent and the multi-agent host)
/// are not ported: Eino recommends its ADK for agents instead
/// (`package:threepio_core/adk.dart`).
library;

export 'components.dart';
export 'schema.dart';
export 'src/flow/indexer/parent_indexer.dart';
export 'src/flow/retriever/multi_query_retriever.dart'
    show MultiQueryRetrieverConfig;
export 'src/flow/retriever/retrieve_utils.dart'
    show RetrieveTask, concurrentRetrieve;
