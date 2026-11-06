// Mirrors the embedding cache of doc/RAG.md.
import 'dart:io';

import 'package:threepio_core/io.dart';
import 'package:threepio_core/threepio_core.dart';

(Embedder, OpenAIEmbedder) cachedEmbedder(String apiKey) {
  final inner = OpenAIEmbedder(config: OpenAIConfig(apiKey: apiKey));
  final cached = CachingEmbedder(
    inner,
    cache: FileEmbeddingCache(Directory('.embedding_cache')),
    keyGenerator: const SimpleCacheKeyGenerator(),
    expiration: const Duration(days: 7),
  ); // inner.dispose() when done
  return (cached, inner);
}
