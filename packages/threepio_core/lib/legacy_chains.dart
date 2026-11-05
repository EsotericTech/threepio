/// The LangChain-style chains that predate the port of Eino's `compose`
/// package: `BaseChain`, `LLMChain`, `RetrievalQAChain` and their relatives,
/// which pass `Map<String, dynamic>` from step to step.
///
/// They are kept as they are. New code composes components with `Chain` and
/// `Graph` of `package:threepio_core/compose.dart`, which are typed, stream,
/// and take call options and callbacks.
library;

export 'src/components/chain/base_chain.dart';
export 'src/components/chain/llm_chain.dart';
export 'src/components/chain/retrieval_qa_chain.dart';
