import 'package:test/test.dart';
import 'package:threepio_core/src/internal/type_utils.dart';
import 'package:threepio_core/src/schema/message.dart';

void main() {
  group('isSubtype', () {
    test('follows the class hierarchy', () {
      expect(isSubtype<int, num>(), isTrue);
      expect(isSubtype<num, int>(), isFalse);
      expect(isSubtype<String, Comparable<String>>(), isTrue);
    });

    test('every type is a subtype of itself and of the top types', () {
      expect(isSubtype<int, int>(), isTrue);
      expect(isSubtype<int, Object>(), isTrue);
      expect(isSubtype<int?, Object?>(), isTrue);
      expect(isSubtype<Message, dynamic>(), isTrue);
    });

    test('respects nullability', () {
      expect(isSubtype<int, int?>(), isTrue);
      expect(isSubtype<int?, int>(), isFalse);
      expect(isSubtype<Null, int?>(), isTrue);
      expect(isSubtype<Null, int>(), isFalse);
    });

    test('generic types are covariant', () {
      expect(isSubtype<List<int>, List<num>>(), isTrue);
      expect(isSubtype<List<num>, List<int>>(), isFalse);
      expect(isSubtype<Map<String, int>, Map<String, Object?>>(), isTrue);
      expect(isSubtype<Map<String, Object?>, Map<String, int>>(), isFalse);
    });
  });

  group('isSameType', () {
    test('is true only for types that are subtypes of each other', () {
      expect(isSameType<int, int>(), isTrue);
      expect(isSameType<List<int>, List<int>>(), isTrue);
      expect(isSameType<int, num>(), isFalse);
      expect(isSameType<int, int?>(), isFalse);
    });
  });

  group('isInstance', () {
    test('matches a value whose runtime class is private', () {
      final message = Message.user('hi');

      expect(message.runtimeType, isNot(Message));
      expect(isInstance<Message>(message), isTrue);
      expect(isInstance<List<int>>([1, 2]), isTrue);
    });

    test('keeps its type argument when stored', () {
      const accepts = isInstance<num>;

      expect(accepts(1), isTrue);
      expect(accepts(1.5), isTrue);
      expect(accepts('1'), isFalse);
      expect(accepts(null), isFalse);
    });
  });

  group('isNullable', () {
    test('is true for nullable and top types', () {
      expect(isNullable<int?>(), isTrue);
      expect(isNullable<Object?>(), isTrue);
      expect(isNullable<dynamic>(), isTrue);
      expect(isNullable<int>(), isFalse);
      expect(isNullable<Object>(), isFalse);
    });
  });
}
