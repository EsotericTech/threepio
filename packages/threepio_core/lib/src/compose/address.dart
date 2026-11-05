/// Addresses: where in a run something is.
///
/// Port of the address half of eino `internal/core/address.go` and of the
/// address types of `compose/interrupt.go`.
library;

import 'package:meta/meta.dart';

/// What kind of thing a segment of an [Address] names.
///
/// Port of eino `compose.AddressSegmentType`. The kinds a graph uses are the
/// constants of this class. The set is open, as in Eino: a component that
/// runs parts of its own under addresses (the agents of the ADK, a node that
/// runs a batch) names its kind with a constant of its own:
///
/// ```dart
/// const batchProcess = AddressSegmentType('batch_process');
/// ```
@immutable
final class AddressSegmentType {
  /// The kind called [name]. Two kinds with the same name are the same kind.
  const AddressSegmentType(this.name);

  /// A node of a graph. Port of eino `compose.AddressSegmentNode`.
  static const node = AddressSegmentType('node');

  /// A tool call inside a tools node. Port of eino
  /// `compose.AddressSegmentTool`.
  static const tool = AddressSegmentType('tool');

  /// A compiled graph, chain or workflow that is run on its own: the one the
  /// caller invokes, or one that a lambda or a tool runs. A graph that is a
  /// node of another graph (`addGraphNode`) is a [node], not a runnable. Port
  /// of eino `compose.AddressSegmentRunnable`.
  static const runnable = AddressSegmentType('runnable');

  /// The name of the kind, as it appears in the text form of an address.
  final String name;

  @override
  bool operator ==(Object other) =>
      other is AddressSegmentType && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => name;
}

/// One step of an [Address]: a node, a tool call, a runnable.
///
/// Port of eino `compose.AddressSegment`.
@immutable
final class AddressSegment {
  /// The segment of the given [type] and [id].
  const AddressSegment({required this.type, required this.id, this.subId = ''});

  /// A segment from its JSON form.
  factory AddressSegment.fromJson(Map<String, Object?> json) => AddressSegment(
        type: AddressSegmentType(json['type']! as String),
        id: json['id']! as String,
        subId: json['sub_id'] as String? ?? '',
      );

  /// What the segment names.
  final AddressSegmentType type;

  /// The name inside its kind: the key of the node, the name of the tool, the
  /// name of the graph.
  final String id;

  /// Tells apart what [id] alone does not: the id of a tool call when one
  /// message calls the same tool twice. Empty when it is not needed.
  final String subId;

  /// The JSON form of the segment.
  Map<String, Object?> toJson() => {
        'type': type.name,
        'id': id,
        if (subId.isNotEmpty) 'sub_id': subId,
      };

  @override
  bool operator ==(Object other) =>
      other is AddressSegment &&
      other.type == type &&
      other.id == id &&
      other.subId == subId;

  @override
  int get hashCode => Object.hash(type, id, subId);

  @override
  String toString() => subId.isEmpty ? '$type:$id' : '$type:$id:$subId';
}

/// The place of a component in a run: the segments that lead to it,
/// outermost first.
///
/// Port of eino `compose.Address`. The node `review` of a graph compiled as
/// `root` runs at `runnable:root;node:review`; a tool call inside the tools
/// node `tools` of that graph at
/// `runnable:root;node:tools;tool:book_ticket:call_1`.
///
/// An interrupt remembers the address it was raised at. On the resumed run
/// the component at that address finds its saved state again
/// (`getInterruptState`) and the data it is resumed with
/// (`getResumeContext`).
@immutable
final class Address {
  /// The address made of [segments], outermost first.
  Address(Iterable<AddressSegment> segments)
      : segments = List.unmodifiable(segments);

  /// The address of something that runs outside any graph.
  const Address.empty() : segments = const [];

  /// An address from its JSON form.
  factory Address.fromJson(List<Object?> json) => Address([
        for (final segment in json)
          AddressSegment.fromJson(segment! as Map<String, Object?>),
      ]);

  /// The segments, outermost first.
  final List<AddressSegment> segments;

  /// Whether the address has no segments.
  bool get isEmpty => segments.isEmpty;

  /// The number of segments.
  int get length => segments.length;

  /// This address with [segment] behind its last segment.
  Address append(AddressSegment segment) => Address([...segments, segment]);

  /// Whether [other] lies inside this address: it starts with all the
  /// segments of this one and has more.
  bool isStrictPrefixOf(Address other) {
    if (other.length <= length) return false;
    for (var i = 0; i < length; i++) {
      if (segments[i] != other.segments[i]) return false;
    }
    return true;
  }

  /// The JSON form of the address.
  List<Object?> toJson() => [for (final segment in segments) segment.toJson()];

  @override
  bool operator ==(Object other) {
    if (other is! Address || other.length != length) return false;
    for (var i = 0; i < length; i++) {
      if (segments[i] != other.segments[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hashAll(segments);

  /// The text form of the address: `type:id` (or `type:id:subId`) per
  /// segment, joined with `;`. Port of eino `Address.String`.
  @override
  String toString() => segments.join(';');
}
