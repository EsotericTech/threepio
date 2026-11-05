// The checkpoint store on the file system, exported from io.dart.
import 'dart:io';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/compose.dart';
import 'package:threepio_core/io.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('threepio_checkpoints_');
  });

  tearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });

  test('is a checkpoint store that can delete', () {
    final store = FileCheckpointStore(root);
    expect(store, isA<CheckpointStore>());
    expect(store, isA<CheckpointDeleter>());
    expect(store.directory.path, root.path);
  });

  test('stores, replaces, reads and deletes', () async {
    final store = FileCheckpointStore(root);
    expect(await store.get('run-1'), isNull);

    await store.set('run-1', Uint8List.fromList([1, 2, 3]));
    expect(await store.get('run-1'), [1, 2, 3]);
    await store.set('run-1', Uint8List.fromList([4]));
    expect(await store.get('run-1'), [4]);
    await store.set('run-2', Uint8List.fromList([5]));
    expect(await store.get('run-2'), [5]);

    await store.delete('run-1');
    expect(await store.get('run-1'), isNull);
    expect(await store.get('run-2'), [5]);
    // Deleting what is not there is not an error.
    await store.delete('run-1');
    await store.delete('never');
  });

  test('creates its directory with the first checkpoint', () async {
    final nested = Directory('${root.path}/a/b');
    final store = FileCheckpointStore(nested);
    expect(await store.get('x'), isNull);
    expect(nested.existsSync(), isFalse);
    await store.set('x', Uint8List.fromList([1]));
    expect(nested.existsSync(), isTrue);
    expect(await store.get('x'), [1]);
  });

  test('leaves no temporary file behind', () async {
    final store = FileCheckpointStore(root);
    await store.set('a', Uint8List.fromList([1]));
    await store.set('a', Uint8List.fromList([2]));
    expect(
      [for (final file in root.listSync()) file.uri.pathSegments.last],
      ['a.checkpoint'],
    );
  });

  test('an id cannot leave the directory', () async {
    final store = FileCheckpointStore(root);
    for (final id in ['../escape', 'a/b', r'a\b', '.hidden', '', 'x' * 180, 'ü']) {
      final file = store.fileOf(id);
      expect(file.parent.path, root.path, reason: id);
      await store.set(id, Uint8List.fromList(id.codeUnits.take(3).toList()));
      expect(await store.get(id), id.codeUnits.take(3).toList(), reason: id);
    }
    expect(root.parent.listSync().where((e) => e.path.endsWith('escape')), isEmpty);
    expect(store.fileOf('plain-id_1.v2').uri.pathSegments.last, 'plain-id_1.v2.checkpoint');
  });

  test('two ids never share a file', () async {
    final store = FileCheckpointStore(root);
    String name(String id) => store.fileOf(id).uri.pathSegments.last;

    // An id that looks like the encoded form of another one is encoded
    // itself.
    final encoded = name('a/b');
    expect(encoded, startsWith('x-'));
    final lookalike = encoded.substring(0, encoded.length - '.checkpoint'.length);
    expect(name(lookalike), isNot(encoded));

    // Upper and lower case differ, also where the file system does not tell
    // them apart: no name has an upper-case letter.
    expect(name('Run1').toLowerCase(), isNot(name('run1').toLowerCase()));
    expect(name('Run1'), name('Run1').toLowerCase());
    expect(name('a/B').toLowerCase(), isNot(name('a/b').toLowerCase()));

    final ids = ['run1', 'Run1', 'RUN1', 'a/b', 'a_b', lookalike, 'x-', 'x', ''];
    expect({for (final id in ids) name(id).toLowerCase()}, hasLength(ids.length));
    for (final (index, id) in ids.indexed) {
      await store.set(id, Uint8List.fromList([index]));
    }
    for (final (index, id) in ids.indexed) {
      expect(await store.get(id), [index], reason: id);
    }
  });

  test('an id that is too long for a file name is refused', () async {
    final store = FileCheckpointStore(root);
    expect(() => store.fileOf('x' * 181), throwsArgumentError);
    expect(() => store.fileOf('/' * 112), throwsArgumentError);
    expect(store.fileOf('/' * 110).parent.path, root.path);
    await expectLater(
      store.set('x' * 300, Uint8List.fromList([1])),
      throwsArgumentError,
    );
    await expectLater(store.get('x' * 300), throwsArgumentError);
  });

  test('a graph resumes from it in a second store object on the same '
      'directory', () async {
    final ctx = RunContext.background();
    Future<Runnable<String, String>> build() {
      final graph = Graph<String, String>()
        ..addLambdaNode('1', Lambda.invokable((ctx, String s) => '${s}1'))
        ..addLambdaNode('2', Lambda.invokable((ctx, String s) => '${s}2'))
        ..addEdge(Graph.start, '1')
        ..addEdge('1', '2')
        ..addEdge('2', Graph.end);
      return graph.compile(
        ctx,
        options: GraphCompileOptions(
          checkpointStore: FileCheckpointStore(root),
          interruptBeforeNodes: const ['2'],
        ),
      );
    }

    final first = await build();
    await expectLater(
      first.invoke(ctx, 'in', options: [CallOption.checkpointId('run')]),
      throwsA(isA<GraphInterruptedException>()),
    );
    expect(File('${root.path}/run.checkpoint').existsSync(), isTrue);

    // As after a restart: a new graph object and a new store object.
    final second = await build();
    expect(
      await second.invoke(ctx, '', options: [CallOption.checkpointId('run')]),
      'in12',
    );
  });
}
