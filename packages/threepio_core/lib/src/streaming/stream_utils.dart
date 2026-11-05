/// Functions that create and combine stream readers.
///
/// They are declared next to the readers they build, in `stream_reader.dart`.
library;

export 'stream_reader.dart'
    show
        concatStreamReaders,
        copyStreamReader,
        mergeNamedStreamReaders,
        mergeStreamReaders,
        pipe,
        transformStreamReader;
