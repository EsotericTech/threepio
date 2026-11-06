// Port of eino `adk/middlewares/skill/filesystem_backend_test.go` (v0.9.22).
//
// Ported: TestNewBackendFromFilesystem, TestFilesystemBackend_List,
// TestFilesystemBackend_Get, TestParseFrontmatter, TestLoadSkillFromFile.
//
// Not ported: TestNewBackendFromFilesystem/"nil config returns error" and
// "nil backend returns error" (a nil config or backend is a compile-time
// error in Dart: required parameter).
//
// Adapted: Go's `assert.Nil(t, skills)` / `assert.Empty(t, skill)` /
// `assert.Empty(t, fm)` next to a returned error have no Dart counterpart:
// the error is thrown and nothing is returned.
import 'package:test/test.dart';
import 'package:threepio_core/adk.dart';
import 'package:threepio_core/src/adk/middlewares/skill/filesystem_backend.dart'
    show parseFrontMatter;

final ctx = RunContext.background();

/// Go `assert.Error` + `assert.Contains(err.Error(), …)`.
Matcher _throwsContaining(String part) => throwsA(
      predicate<Object?>((error) => '$error'.contains(part), 'an error containing "$part"'),
    );

Future<InMemoryBackend> _fs(Map<String, String> files) async {
  final fs = InMemoryBackend();
  for (final MapEntry(:key, :value) in files.entries) {
    await fs.write(ctx, WriteRequest(filePath: key, content: value));
  }
  return fs;
}

void main() {
  group('TestNewBackendFromFilesystem', () {
    // "nil config returns error" and "nil backend returns error": not
    // portable (compile-time errors in Dart).

    test('empty baseDir returns error', () {
      final fsBackend = InMemoryBackend();
      expect(
        () => FilesystemSkillBackend(backend: fsBackend, baseDir: ''),
        throwsA(isA<ArgumentError>().having((e) => '$e', 'text', contains('baseDir is required'))),
      );
    });

    test('valid config succeeds', () {
      final fsBackend = InMemoryBackend();
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');
      expect(backend, isNotNull);
    });
  });

  group('TestFilesystemBackend_List', () {
    test('empty directory returns empty list', () async {
      final fsBackend = await _fs({'/skills/.keep': ''});
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');

      final skills = await backend.list(ctx);
      expect(skills, isEmpty);
    });

    test('directory with no SKILL.md files returns empty list', () async {
      final fsBackend = await _fs({'/skills/subdir/other.txt': 'some content'});
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');

      final skills = await backend.list(ctx);
      expect(skills, isEmpty);
    });

    test('files in root directory are ignored', () async {
      final fsBackend = await _fs({
        '/skills/SKILL.md': '---\nname: root-skill\ndescription: Root skill\n---\nContent',
      });
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');

      final skills = await backend.list(ctx);
      expect(skills, isEmpty);
    });

    test('valid skill directory returns skill', () async {
      final fsBackend = await _fs({
        '/skills/my-skill/SKILL.md': '''
---
name: pdf-processing
description: Extract text and tables from PDF files, fill forms, merge documents.
license: Apache-2.0
metadata:
  author: example-org
  version: "1.0"
---
This is the skill content.''',
      });
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');

      final skills = await backend.list(ctx);
      expect(skills, hasLength(1));
      expect(skills[0].name, 'pdf-processing');
      expect(
        skills[0].description,
        'Extract text and tables from PDF files, fill forms, merge documents.',
      );
    });

    test('multiple skill directories returns all skills', () async {
      final fsBackend = await _fs({
        '/skills/skill-1/SKILL.md': '---\nname: skill-1\ndescription: First skill\n---\nContent 1',
        '/skills/skill-2/SKILL.md': '---\nname: skill-2\ndescription: Second skill\n---\nContent 2',
      });
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');

      final skills = await backend.list(ctx);
      expect(skills, hasLength(2));

      final names = [skills[0].name, skills[1].name];
      expect(names, contains('skill-1'));
      expect(names, contains('skill-2'));
    });

    test('invalid SKILL.md returns error', () async {
      final fsBackend = await _fs({'/skills/invalid-skill/SKILL.md': 'No frontmatter here'});
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');

      await expectLater(backend.list(ctx), _throwsContaining('failed to load skill'));
    });

    test('non-existent baseDir returns empty list', () async {
      final fsBackend = InMemoryBackend();
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/path/that/does/not/exist');

      final skills = await backend.list(ctx);
      expect(skills, isEmpty);
    });

    test('deeply nested SKILL.md is ignored', () async {
      final fsBackend = await _fs({
        '/skills/valid-skill/SKILL.md': '---\nname: valid-skill\ndescription: Valid skill\n---\nContent',
        '/skills/deep/nested/SKILL.md': '---\nname: nested-skill\ndescription: Nested skill\n---\nContent',
      });
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');

      final skills = await backend.list(ctx);
      expect(skills, hasLength(1));
      expect(skills[0].name, 'valid-skill');
    });
  });

  group('TestFilesystemBackend_Get', () {
    test('skill not found returns error', () async {
      final fsBackend = await _fs({'/skills/.keep': ''});
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');

      await expectLater(backend.get(ctx, 'non-existent'), _throwsContaining('skill not found'));
    });

    test('existing skill is returned', () async {
      final fsBackend = await _fs({
        '/skills/test-skill/SKILL.md':
            '---\nname: test-skill\ndescription: Test skill description\n---\nTest content here.',
      });
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');

      final skill = await backend.get(ctx, 'test-skill');
      expect(skill.name, 'test-skill');
      expect(skill.description, 'Test skill description');
      expect(skill.content, 'Test content here.');
    });

    test('get specific skill from multiple', () async {
      final fsBackend = await _fs({
        for (final name in ['alpha', 'beta', 'gamma'])
          '/skills/$name/SKILL.md': '---\nname: $name\ndescription: Skill $name\n---\nContent for $name',
      });
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');

      final skill = await backend.get(ctx, 'beta');
      expect(skill.name, 'beta');
      expect(skill.description, 'Skill beta');
      expect(skill.content, 'Content for beta');
    });
  });

  group('TestParseFrontmatter', () {
    test('valid frontmatter', () {
      const data = '---\nname: test\ndescription: test description\n---\nThis is the content.';

      final (fm, content) = parseFrontMatter(data);
      expect(fm, 'name: test\ndescription: test description');
      expect(content, 'This is the content.');
    });

    test('frontmatter with multiline content', () {
      const data = '---\nname: test\n---\nLine 1\nLine 2\nLine 3';

      final (fm, content) = parseFrontMatter(data);
      expect(fm, 'name: test');
      expect(content, 'Line 1\nLine 2\nLine 3');
    });

    test('frontmatter with leading/trailing whitespace', () {
      const data = '  \n---\nname: test\n---\nContent  ';

      final (fm, content) = parseFrontMatter(data);
      expect(fm, 'name: test');
      expect(content, 'Content');
    });

    test('missing opening delimiter returns error', () {
      const data = 'name: test\n---\nContent';

      expect(() => parseFrontMatter(data), _throwsContaining('does not start with frontmatter delimiter'));
    });

    test('missing closing delimiter returns error', () {
      const data = '---\nname: test\nContent without closing';

      expect(() => parseFrontMatter(data), _throwsContaining('closing delimiter not found'));
    });

    test('empty frontmatter', () {
      const data = '---\n---\nContent only';

      final (fm, content) = parseFrontMatter(data);
      expect(fm, isEmpty);
      expect(content, 'Content only');
    });

    test('empty content', () {
      const data = '---\nname: test\n---';

      final (fm, content) = parseFrontMatter(data);
      expect(fm, 'name: test');
      expect(content, isEmpty);
    });

    test('content with --- inside', () {
      const data = '---\nname: test\n---\nContent with --- in the middle';

      final (fm, content) = parseFrontMatter(data);
      expect(fm, 'name: test');
      expect(content, 'Content with --- in the middle');
    });
  });

  group('TestLoadSkillFromFile', () {
    test('valid skill file', () async {
      final fsBackend = await _fs({
        '/skills/SKILL.md': '---\nname: file-skill\ndescription: Skill from file\n---\nFile skill content.',
      });

      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');
      final skill = await backend.loadSkillFromFile(ctx, '/skills/SKILL.md');
      expect(skill.name, 'file-skill');
      expect(skill.description, 'Skill from file');
      expect(skill.content, 'File skill content.');
      expect(skill.baseDirectory, '/skills');
    });

    test('non-existent file returns error', () async {
      final fsBackend = InMemoryBackend();
      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/tmp');
      await expectLater(
        backend.loadSkillFromFile(ctx, '/path/to/nonexistent/SKILL.md'),
        _throwsContaining('failed to read file'),
      );
    });

    test('invalid yaml in frontmatter returns error', () async {
      final fsBackend = await _fs({'/skills/SKILL.md': '---\nname: [invalid yaml\n---\nContent'});

      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');
      await expectLater(
        backend.loadSkillFromFile(ctx, '/skills/SKILL.md'),
        _throwsContaining('failed to unmarshal frontmatter'),
      );
    });

    test('content with extra whitespace is trimmed', () async {
      final fsBackend = await _fs({
        '/skills/SKILL.md': '---\nname: trimmed-skill\ndescription: desc\n---\n\n   Content with whitespace   \n\n',
      });

      final backend = FilesystemSkillBackend(backend: fsBackend, baseDir: '/skills');
      final skill = await backend.loadSkillFromFile(ctx, '/skills/SKILL.md');
      expect(skill.content, 'Content with whitespace');
    });
  });
}
