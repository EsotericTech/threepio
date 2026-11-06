/// A [SkillBackend] that reads SKILL.md files from a [FilesystemBackend].
///
/// Port of eino `adk/middlewares/skill/filesystem_backend.go`.
library;

import 'package:meta/meta.dart';
import 'package:yaml/yaml.dart';

import '../../../core/run_context.dart';
import '../../../errors.dart';
import '../../filesystem/backend.dart';
import '../../filesystem/requests.dart';
import '../internal/go_compat.dart';
import 'skill.dart';

/// The file name of a skill. Port of `skillFileName`.
const String _skillFileName = 'SKILL.md';

/// Skills stored as `<baseDir>/<skill>/SKILL.md` on a [FilesystemBackend].
///
/// Port of eino `skill.NewBackendFromFilesystem`. Only the direct
/// subdirectories of [baseDir] are searched; a SKILL.md deeper down is
/// ignored. A SKILL.md starts with a YAML front matter between `---` lines
/// (`name`, `description`, `context`, `agent`, `model`); the rest is the
/// skill's content. The skills are read again on every [list] and [get].
final class FilesystemSkillBackend implements SkillBackend {
  /// Skills under [baseDir] of [backend]. Throws [ArgumentError] for an
  /// empty [baseDir].
  FilesystemSkillBackend({required this.backend, required this.baseDir}) {
    if (baseDir.isEmpty) throw ArgumentError.value(baseDir, 'baseDir', 'baseDir is required');
  }

  /// The files.
  final FilesystemBackend backend;

  /// The directory whose subdirectories hold the skills.
  final String baseDir;

  @override
  Future<List<SkillFrontMatter>> list(RunContext ctx) async {
    final List<Skill> skills;
    try {
      skills = await _list(ctx);
    } on Object catch (error) {
      throw ThreepioException('failed to list skills: ${goValueString(error)}', cause: error);
    }
    return [for (final skill in skills) skill.frontMatter];
  }

  @override
  Future<Skill> get(RunContext ctx, String name) async {
    final List<Skill> skills;
    try {
      skills = await _list(ctx);
    } on Object catch (error) {
      throw ThreepioException('failed to list skills: ${goValueString(error)}', cause: error);
    }
    for (final skill in skills) {
      if (skill.name == name) return skill;
    }
    throw ThreepioException('skill not found: $name');
  }

  Future<List<Skill>> _list(RunContext ctx) async {
    final List<FileInfo> entries;
    try {
      entries = await backend.globInfo(
        ctx,
        GlobInfoRequest(pattern: '*/$_skillFileName', path: baseDir),
      );
    } on Object catch (error) {
      throw ThreepioException('failed to glob skill files: ${goValueString(error)}', cause: error);
    }
    final skills = <Skill>[];
    for (final entry in entries) {
      final filePath = goIsAbs(entry.path) ? entry.path : goJoin([baseDir, entry.path]);
      try {
        skills.add(await loadSkillFromFile(ctx, filePath));
      } on Object catch (error) {
        throw ThreepioException(
          'failed to load skill from $filePath: ${goValueString(error)}',
          cause: error,
        );
      }
    }
    return skills;
  }

  /// The skill in the SKILL.md at [path]. Port of `loadSkillFromFile`.
  @visibleForTesting
  Future<Skill> loadSkillFromFile(RunContext ctx, String path) async {
    final FileContent fileContent;
    try {
      fileContent = await backend.read(ctx, ReadRequest(filePath: path));
    } on Object catch (error) {
      throw ThreepioException('failed to read file: ${goValueString(error)}', cause: error);
    }
    final data = stripLineNumbers(fileContent.content);
    final String frontMatter;
    final String content;
    try {
      (frontMatter, content) = parseFrontMatter(data);
    } on ThreepioException catch (error) {
      throw ThreepioException('failed to parse frontmatter: ${error.message}', cause: error);
    }
    return Skill(
      frontMatter: _decodeFrontMatter(frontMatter),
      content: content.trim(),
      baseDirectory: goDir(path),
    );
  }
}

SkillFrontMatter _decodeFrontMatter(String text) {
  YamlNode node;
  try {
    node = loadYamlNode(text);
  } on YamlException catch (error) {
    throw ThreepioException('failed to unmarshal frontmatter: ${error.message}', cause: error);
  }
  if (node is YamlScalar && node.value == null) return const SkillFrontMatter(name: '');
  if (node is! YamlMap) {
    throw ThreepioException(
      'failed to unmarshal frontmatter: the front matter is not a mapping (${node.runtimeType})',
    );
  }
  final map = node;
  // yaml.v3 decodes a scalar into a string field as its text: `model: 4.10`
  // stays `4.10`, `007` stays `007`, `TRUE` stays `TRUE`.
  String field(String key) {
    final value = map.nodes[key];
    if (value == null) return '';
    if (value is! YamlScalar) {
      throw ThreepioException('failed to unmarshal frontmatter: "$key" is not a scalar');
    }
    final raw = value.value;
    if (raw == null) return '';
    if (raw is String) return raw;
    return value.span.text;
  }

  return SkillFrontMatter(
    name: field('name'),
    description: field('description'),
    context: SkillContextMode.parse(field('context')),
    agent: field('agent'),
    model: field('model'),
  );
}

/// [data] with everything up to the first tab of each line removed (the
/// line numbers a backend may add). Port of `stripLineNumbers`.
@visibleForTesting
String stripLineNumbers(String data) => [
      for (final line in data.split('\n'))
        line.contains('\t') ? line.substring(line.indexOf('\t') + 1) : line,
    ].join('\n');

/// The front matter between the leading `---` lines and the content after
/// them. Throws [ThreepioException] without a front matter. Port of
/// `parseFrontmatter`.
@visibleForTesting
(String, String) parseFrontMatter(String raw) {
  const delimiter = '---';
  final data = raw.trim();
  if (!data.startsWith(delimiter)) {
    throw const ThreepioException('file does not start with frontmatter delimiter');
  }
  final rest = data.substring(delimiter.length);
  final end = rest.indexOf('\n$delimiter');
  if (end < 0) throw const ThreepioException('frontmatter closing delimiter not found');
  final frontMatter = rest.substring(0, end).trim();
  var content = rest.substring(end + delimiter.length + 1);
  if (content.startsWith('\n')) content = content.substring(1);
  return (frontMatter, content);
}
