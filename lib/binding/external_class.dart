import '../error/error.dart';
// import '../class.dart' show HTInheritable;
import '../type/type.dart';
import '../element/object.dart';

/// Namespace class of low level external dart functions for Hetu to use.
abstract class HTExternalClass with HTObject {
  // @override
  // final HTExternalClass? superClass;

  @override
  HTType get valueType => HTType.CLASS;

  // @override
  final String id;

  HTExternalClass(this.id); //, {this.superClass, this.superClassType});

  /// Default [HTExternalClass] constructor.
  /// Fetch a instance member of the Dart class by the [field], in the form of
  /// ```
  /// object.key
  /// ```
  dynamic instanceMemberGet(dynamic object, String field) =>
      throw HTError.undefined(field);

  /// Assign a value to a instance member of the Dart class by the [field], in the form of
  /// ```
  /// object.key = value
  /// ```
  void instanceMemberSet(dynamic object, String field, dynamic varValue) =>
      throw HTError.undefined(field);

  /// Fetch a instance member of the Dart class by the [field], in the form of
  /// ```
  /// object[key]
  /// ```
  dynamic instanceSubGet(dynamic object, dynamic key) => object[key];

  /// Assign a value to a instance member of the Dart class by the [field], in the form of
  /// ```
  /// object[key] = value
  /// ```
  void instanceSubSet(dynamic object, dynamic key, dynamic varValue) =>
      object[key] = varValue;
}
