/// The path of a node through nested graphs.
library;

import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

/// The keys that lead to a node: one key for a node of the graph that is run,
/// one more for every graph nested on the way.
///
/// Port of eino `compose.NodePath` and `compose.NewNodePath`. `NodePath(['sub',
/// 'model'])` names the node `model` of the graph that is the node `sub`.
@immutable
final class NodePath {
  /// The path made of [path], outermost key first.
  NodePath(Iterable<String> path) : path = List.unmodifiable(path);

  /// The node keys, outermost first. Port of eino `NodePath.GetPath`.
  final List<String> path;

  /// This path with [key] in front of it.
  NodePath prepend(String key) => NodePath([key, ...path]);

  static const _equality = ListEquality<String>();

  @override
  bool operator ==(Object other) =>
      other is NodePath && _equality.equals(path, other.path);

  @override
  int get hashCode => _equality.hash(path);

  @override
  String toString() => '[${path.join(', ')}]';
}
