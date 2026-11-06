// Imported by p12_exports_test.dart: the umbrella, `io.dart` and
// `callbacks.dart` without prefixes. An ambiguous name would be a compile
// error here.
import 'package:threepio_core/callbacks.dart';
import 'package:threepio_core/io.dart';
import 'package:threepio_core/threepio_core.dart';

/// Uses one name of each library, unprefixed.
bool namesResolve() => <Type>[
      FileLoader,
      LocalOperator,
      LangSmithHandler,
      SearchResult,
      QdrantIndexer,
      DuckDuckGoRegion,
      HtmlParser,
      UrlLoader,
    ].length == 8;
