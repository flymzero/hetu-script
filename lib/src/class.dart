import '../hetu_script.dart';
import 'lexicon.dart';
import 'interpreter.dart';
import 'namespace.dart';
import 'function.dart';
import 'errors.dart';
import 'statement.dart';
import 'value.dart';

/// [HT_Class] is the Dart implementation of the class declaration in Hetu.
///
/// [HT_Class] extends [HT_Namespace].
///
/// The values defined in this namespace are methods and [static] members in Hetu class.
///
/// The [variables] are object members.
///
/// Class can have type parameters.
///
/// Type parameters are optional and defined after class name. Example:
///
/// ```typescript
/// class Map<KeyType, ValueType> {
///   List<KeyType> keys
///   List<ValueType> values
///   ...
/// }
/// ```
class HT_Class extends HT_Namespace with HT_Type {
  final HT_Interpreter interpreter;

  @override
  final HT_TypeId typeid = HT_TypeId.CLASS;

  /// The type parameters of the class.
  final List<String> typeParams;

  @override
  String toString() => '${HT_Lexicon.CLASS} $id';

  final bool isExtern;

  /// Super class of this class
  ///
  /// If a class is not extends from any super class, then it is the child of class `Object`
  final HT_Class superClass;

  /// The object members defined in class definition.
  Map<String, VarDeclStmt> variables = {};

  /// Create a class object.
  ///
  /// [id] : the class name
  ///
  /// [typeParams] : the type parameters defined after class name.
  ///
  /// [closure] : the outer namespace of the class declaration,
  /// normally the global namespace of the interpreter.
  ///
  /// [superClass] : super class of this class.
  HT_Class(String id, this.superClass, this.interpreter,
      {this.isExtern = false, this.typeParams = const [], HT_Namespace closure})
      : super(id: id, closure: closure);

  /// Wether the class contains a static member, will also check super class.
  @override
  bool contains(String varName) =>
      defs.containsKey(varName) ||
      defs.containsKey('${HT_Lexicon.getter}$varName') ||
      ((superClass?.contains(varName)) ?? false) ||
      ((superClass?.contains('${HT_Lexicon.getter}$varName')) ?? false);

  /// Add a object variable declaration to this class.
  void addVariable(VarDeclStmt stmt) {
    if (!variables.containsKey(stmt.id.lexeme)) {
      variables[stmt.id.lexeme] = stmt;
    } else {
      throw HTErr_Defined(
        stmt.id.lexeme,
        interpreter.curFileName,
        stmt.id.line,
        stmt.id.column,
      );
    }
  }

  /// Fetch the value of a static member from this class.
  @override
  dynamic fetch(String varName, int line, int column, HT_Interpreter interpreter,
      {bool error = true, String from = HT_Lexicon.global, bool recursive = true}) {
    var getter = '${HT_Lexicon.getter}$varName';
    if (defs.containsKey(varName)) {
      if (fullName.startsWith(HT_Lexicon.underscore) && !from.startsWith(fullName)) {
        throw HTErr_PrivateDecl(fullName, interpreter.curFileName, line, column);
      } else if (varName.startsWith(HT_Lexicon.underscore) && !from.startsWith(fullName)) {
        throw HTErr_PrivateMember(varName, interpreter.curFileName, line, column);
      }
      if (!defs[varName].isExtern) {
        return defs[varName].value;
      } else {
        final getterFunc =
            interpreter.fetchGlobal('${HT_Lexicon.extern}$id${HT_Lexicon.memberGet}${HT_Lexicon.getter}$varName');
        return getterFunc(interpreter);
      }
    } else if (defs.containsKey(getter)) {
      if (fullName.startsWith(HT_Lexicon.underscore) && !from.startsWith(fullName)) {
        throw HTErr_PrivateDecl(fullName, interpreter.curFileName, line, column);
      } else if (varName.startsWith(HT_Lexicon.underscore) && !from.startsWith(fullName)) {
        throw HTErr_PrivateMember(varName, interpreter.curFileName, line, column);
      }
      HT_Function func = defs[getter].value;
      return func.call(interpreter, line, column);
    }
    //  else if (defs.containsKey(method)) {
    //   if (fullName.startsWith(HT_Lexicon.underscore) && !from.startsWith(fullName)) {
    //     throw HTErr_PrivateDecl(fullName, interpreter.curFileName, line, column);
    //   } else if (varName.startsWith(HT_Lexicon.underscore) && !from.startsWith(fullName)) {
    //     throw HTErr_PrivateMember(varName, interpreter.curFileName, line, column);
    //   }
    //   return defs[method].value;
    // }
    else if (superClass.contains(varName)) {
      return superClass.fetch(varName, line, column, interpreter, error: error, from: superClass.fullName);
    }

    if (closure != null) {
      return closure.fetch(varName, line, column, interpreter, error: error, from: closure.fullName);
    }

    if (error) throw HTErr_Undefined(varName, interpreter.curFileName, line, column);
    return null;
  }

  /// Assign a value to a static member of this class.
  @override
  void assign(String varName, dynamic value, int line, int column, HT_Interpreter interpreter,
      {bool error = true, String from = HT_Lexicon.global, bool recursive = true}) {
    var setter = '${HT_Lexicon.setter}$varName';
    if (defs.containsKey(varName)) {
      var decl_type = defs[varName].declType;
      var var_type = HT_TypeOf(value);
      if (from.startsWith(fullName) ||
          (!fullName.startsWith(HT_Lexicon.underscore) && !varName.startsWith(HT_Lexicon.underscore))) {
        if (var_type.isA(decl_type)) {
          if (!defs[varName].isExtern) {
            defs[varName].value = value;
          } else {
            final setterFunc =
                interpreter.fetchGlobal('${HT_Lexicon.extern}$id${HT_Lexicon.memberGet}${HT_Lexicon.setter}$varName');
            setterFunc(interpreter, positionalArgs: [value]);
          }

          return;
        }
        throw HTErr_Type(varName, var_type.toString(), decl_type.toString(), interpreter.curFileName, line, column);
      }
      throw HTErr_PrivateMember(varName, interpreter.curFileName, line, column);
    } else if (defs.containsKey(setter)) {
      if (from.startsWith(fullName) ||
          (!fullName.startsWith(HT_Lexicon.underscore) && !varName.startsWith(HT_Lexicon.underscore))) {
        HT_Function setter_func = defs[setter].value;
        setter_func.call(interpreter, line, column, positionalArgs: [value]);
        return;
      }
      throw HTErr_PrivateMember(varName, interpreter.curFileName, line, column);
    }

    if (closure != null) {
      closure.assign(varName, value, line, column, interpreter, from: from);
      return;
    }

    if (error) throw HTErr_Undefined(varName, interpreter.curFileName, line, column);
  }

  /// Create a object from this class.
  /// TODO：对象初始化时从父类逐个调用构造函数
  HT_Object createInstance(HT_Interpreter interpreter, int line, int column,
      {List<HT_TypeId> typeArgs,
      String constructorName,
      List<dynamic> positionalArgs,
      Map<String, dynamic> namedArgs}) {
    var object = HT_Object(this, interpreter, typeArgs: typeArgs?.sublist(0, typeParams.length));

    var save = interpreter.curNamespace;
    interpreter.curNamespace = object;
    for (final decl in variables.values) {
      dynamic value;
      if (decl.initializer != null) {
        value = interpreter.evaluateExpr(decl.initializer);
      }
      object.define(decl.id.lexeme, interpreter, declType: decl.declType, line: line, column: column, value: value);
    }
    interpreter.curNamespace = save;

    constructorName ??= id;
    var constructor = fetch(constructorName, line, column, interpreter, error: false, from: id);

    if (constructor is HT_Function) {
      constructor.call(interpreter, line, column, positionalArgs: positionalArgs, namedArgs: namedArgs, object: object);
    }

    return object;
  }

  // void initInstance(HT_Object object, String constructorName, Interpreter interpreter,
  //     {List<HT_Type> typeArgs, List<dynamic> positionalArgs, Map<String, dynamic> namedArgs}) {
  //   constructorName ??= id;
  //   var constructor = fetch(constructorName, null, null, interpreter, error: false, from: id);

  //   if (constructor is HT_Function) {
  //     constructor.call(interpreter, null, null,
  //         positionalArgs: positionalArgs, namedArgs: namedArgs, object: object);
  //   }
  // }

  @override // TODO: 区分getOwnProperty和继承的property？
  dynamic getProperty(String id) {
    return fetch(
      id,
      null,
      null,
      interpreter,
    );
  }

  @override
  void setProperty(String id, dynamic value) {
    return assign(
      id,
      value,
      null,
      null,
      interpreter,
    );
  }
}

/// [HT_Object] is the Dart implementation of the object object in Hetu.
class HT_Object extends HT_Namespace with HT_Type {
  final HT_Interpreter interpreter;

  static int _instanceIndex = 0;

  final bool isExtern;

  final HT_Class klass;

  HT_TypeId _typeid;
  @override
  HT_TypeId get typeid => _typeid;

  HT_Object(this.klass, this.interpreter, {List<HT_TypeId> typeArgs = const [], this.isExtern = false})
      : super(id: HT_Lexicon.instance + (_instanceIndex++).toString(), closure: klass) {
    _typeid = HT_TypeId(klass.id, arguments: typeArgs = const []);
    define(HT_Lexicon.THIS, interpreter, declType: typeid, value: this);
  }

  @override
  String toString() => '${HT_Lexicon.instanceOf}$typeid';

  @override
  bool contains(String varName) => defs.containsKey(varName) || defs.containsKey('${HT_Lexicon.getter}$varName');

  @override
  dynamic fetch(String varName, int line, int column, HT_Interpreter interpreter,
      {bool error = true, String from = HT_Lexicon.global, bool recursive = true}) {
    if (defs.containsKey(varName)) {
      if (!varName.startsWith(HT_Lexicon.underscore) || from.startsWith(fullName)) {
        return defs[varName].value;
      }
      throw HTErr_PrivateMember(varName, interpreter.curFileName, line, column);
    } else {
      var getter = '${HT_Lexicon.getter}$varName';
      if (klass.contains(getter)) {
        HT_Function method = klass.fetch(getter, line, column, interpreter, error: false, from: klass.fullName);
        if ((method != null) && (!method.funcStmt.isStatic)) {
          return method.call(interpreter, line, column, object: this);
        }
      } else {
        // var method_name = '${HT_Lexicon.method}$varName';
        // if (klass.contains(method_name)) {
        final method = klass.fetch(varName, line, column, interpreter, error: false, from: klass.fullName);
        if ((method is HT_Function) && (!method.funcStmt.isStatic)) {
          method.declContext = this;
          return method;
        }
        // }
      }
    }

    if (error) throw HTErr_UndefinedMember(varName, typeid.toString(), interpreter.curFileName, line, column);
  }

  @override
  void assign(String varName, dynamic value, int line, int column, HT_Interpreter interpreter,
      {bool error = true, String from = HT_Lexicon.global, bool recursive = true}) {
    if (defs.containsKey(varName)) {
      var decl_type = defs[varName].declType;
      var var_type = HT_TypeOf(value);
      if (!varName.startsWith(HT_Lexicon.underscore) || from.startsWith(fullName)) {
        if (var_type.isA(decl_type)) {
          if (!defs[varName].isImmutable) {
            defs[varName].value = value;
            return;
          }
          throw HTErr_Immutable(varName, interpreter.curFileName, line, column);
        }
        throw HTErr_Type(varName, var_type.toString(), decl_type.toString(), interpreter.curFileName, line, column);
      }
      throw HTErr_PrivateMember(varName, interpreter.curFileName, line, column);
    } else {
      var setter = '${HT_Lexicon.setter}$varName';
      if (klass.contains(setter)) {
        HT_Function method = klass.fetch(setter, line, column, interpreter, error: false, from: klass.fullName);
        if ((method != null) && (!method.funcStmt.isStatic)) {
          method.call(interpreter, line, column, positionalArgs: [value], object: this);
          return;
        }
      }
    }

    if (error) throw HTErr_Undefined(varName, interpreter.curFileName, line, column);
  }

  dynamic invoke(String methodName, int line, int column, HT_Interpreter interpreter,
      {bool error = true, List<dynamic> positionalArgs, Map<String, dynamic> namedArgs}) {
    HT_Function method = klass.fetch(methodName, null, null, interpreter, from: klass.fullName);
    if ((method != null) && (!method.funcStmt.isStatic)) {
      return method.call(interpreter, null, null, positionalArgs: positionalArgs, namedArgs: namedArgs, object: this);
    }

    if (error) throw HTErr_Undefined(methodName, interpreter.curFileName, line, column);
  }

  @override // TODO: 区分getOwnProperty和继承的property？
  dynamic getProperty(String id) {
    return fetch(
      id,
      null,
      null,
      interpreter,
    );
  }

  @override
  void setProperty(String id, dynamic value) {
    return assign(
      id,
      value,
      null,
      null,
      interpreter,
    );
  }
}