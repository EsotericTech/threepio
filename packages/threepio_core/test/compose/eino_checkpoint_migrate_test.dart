// Port of eino `compose/checkpoint_migrate_test.go` (v0.9.22).
//
// Dart throws where Go returns an error, and `migrate` answers with the
// record `(state:, changed:)` where Go returns `(state, changed, err)`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:test/test.dart';
import 'package:threepio_core/src/compose/checkpoint.dart';
import 'package:threepio_core/src/compose/checkpoint_store.dart';

/// Go's `stubSerializer`: a serializer made of two functions.
///
/// Go's `unmarshal` fills the checkpoint it is handed
/// (`*(v.(*checkpoint)) = *cp`); here `unmarshal` returns the checkpoint.
final class _StubSerializer implements CheckpointSerializer {
  _StubSerializer({required this.unmarshal, required this.marshal});

  final Object? Function(Uint8List data) unmarshal;
  final Uint8List Function(Object? value) marshal;

  @override
  Object? deserialize(Uint8List bytes) => unmarshal(bytes);

  @override
  Uint8List serialize(Object? value) => marshal(value);
}

Uint8List _bytes(String text) => Uint8List.fromList(utf8.encode(text));

void main() {
  test('TestMigrateCheckpointState_UnmarshalError', () async {
    final input = _bytes('in');
    final codec = _StubSerializer(
      unmarshal: (_) => throw const FormatException('bad'),
      marshal: (_) => _bytes('unused'),
    );

    await expectLater(
      migrateCheckpointState(
        input,
        codec,
        (state) => (state: state, changed: false),
      ),
      throwsA(
        isA<FormatException>().having((e) => e.message, 'message', 'bad'),
      ),
    );
  });

  test('TestMigrateCheckpointState_NoChangeReturnsOriginalBytes', () async {
    final input = _bytes('in');
    final cp = GraphCheckpoint(state: 's');
    final codec = _StubSerializer(
      unmarshal: (_) => cp,
      marshal: (_) => _bytes('marshaled'),
    );

    final out = await migrateCheckpointState(
      input,
      codec,
      (state) => (state: state, changed: false),
    );

    expect(out, input);
  });

  test('TestMigrateCheckpointState_ChangeTriggersMarshal', () async {
    final input = _bytes('in');
    final cp = GraphCheckpoint(state: 's');
    Object? sawState;
    final codec = _StubSerializer(
      unmarshal: (_) => cp,
      marshal: (value) {
        sawState = (value! as GraphCheckpoint).state;
        return _bytes('marshaled');
      },
    );

    final out = await migrateCheckpointState(
      input,
      codec,
      (state) => (state: 's2', changed: true),
    );

    expect(out, _bytes('marshaled'));
    expect(sawState, 's2');
  });

  test('TestMigrateCheckpointState_MigrateErrorStops', () async {
    final input = _bytes('in');
    final cp = GraphCheckpoint(
      state: 'root',
      subGraphs: {'sub': GraphCheckpoint(state: 'sub')},
    );
    final codec = _StubSerializer(
      unmarshal: (_) => cp,
      marshal: (_) => _bytes('marshaled'),
    );

    await expectLater(
      migrateCheckpointState(input, codec, (state) {
        if (state == 'sub') throw StateError('boom');
        return (state: state, changed: false);
      }),
      throwsA(isA<StateError>().having((e) => e.message, 'message', 'boom')),
    );
  });
}
