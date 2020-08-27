import 'package:hetu_script/hetu.dart';

import 'interpreter.dart';
import 'namespace.dart';
import 'common.dart';
import 'function.dart';
import 'errors.dart';
import 'statement.dart';

String HS_TypeOf(dynamic value) {
  if ((value == null) || (value is NullThrownError)) {
    return HS_Common.Null;
  } else if (value is HS_Value) {
    return value.type;
  } else if (value is num) {
    return HS_Common.Num;
  } else if (value is bool) {
    return HS_Common.Bool;
  } else if (value is String) {
    return HS_Common.Str;
  } else if (value is List) {
    return HS_Common.List;
  } else if (value is Map) {
    return HS_Common.Map;
  } else {
    return value.runtimeType.toString();
  }
}

/// [HS_Class]的实例对应河图中的"class"声明
///
/// [HS_Class]继承自命名空间[Namespace]，[HS_Class]中的变量，对应在河图中对应"class"以[static]关键字声明的成员
///
/// 类的方法单独定义在一个表中，通过[fetchMethod]获取
///
/// 类的静态成员定义在所继承的[Namespace]的表中，通过[define]和[fetch]定义和获取
///
/// TODO：对象初始化时从父类逐个调用构造函数
class HS_Class extends Namespace {
  String get type => HS_Common.Class;

  String toString() => '$name';

  final String name;
  HS_Class superClass;

  Map<String, VarStmt> variables = {};
  //Map<String, HS_Function> methods = {};

  HS_Class(this.name, {Namespace closure, this.superClass}) : super(name: name, closure: closure);

  @override
  bool contains(String varName) =>
      variables.containsKey(varName) ||
      defs.containsKey(varName) ||
      defs.containsKey('${HS_Common.Getter}$varName') ||
      (superClass == null ? false : superClass.contains(varName)) ||
      (superClass == null ? false : superClass.contains('${HS_Common.Getter}$varName'));

  void addVariable(VarStmt stmt) {
    if (!variables.containsKey(stmt.name.lexeme)) {
      variables[stmt.name.lexeme] = stmt;
    } else {
      throw HSErr_Defined(name, stmt.name.line, stmt.name.column, null);
    }
  }

  // void addMethod(String name, HS_FuncObj func, int line, int column, String fileName) {
  //   if (!methods.containsKey(name))
  //     methods[name] = func;
  //   else
  //     throw HSErr_Defined(name, line, column, fileName);
  // }

  // dynamic fetchMethod(String name, int line, int column, String fileName,
  //     {bool error = true, String from = HS_Common.Global}) {
  //   var getter = '${HS_Common.Getter}$name';
  //   if (methods.containsKey(name)) {
  //     if (from.startsWith(from) || (!name.startsWith(HS_Common.Underscore))) {
  //       return methods[name];
  //     }
  //     throw HSErr_Private(name, line, column, fileName);
  //   } else if (methods.containsKey(getter)) {
  //     return methods[getter];
  //   }

  //   // if (superClass is HS_Class) {
  //   //   (closure as HS_Class).fetchMethod(name, line, column, fileName, error: error);
  //   // }

  //   if (error) {
  //     throw HSErr_UndefinedMember(name, this.name, line, column, fileName);
  //   }
  // }

  @override
  dynamic fetch(String varName, int line, int column, Interpreter interpreter,
      {bool nonExistError = true, String from = HS_Common.Global, bool recursive = true}) {
    var getter = '${HS_Common.Getter}$varName';
    if (defs.containsKey(varName)) {
      if (from.startsWith(this.fullName) || !varName.startsWith(HS_Common.Underscore)) {
        return defs[varName].value;
      }
      throw HSErr_Private(varName, line, column, interpreter.curFileName);
    } else if (defs.containsKey(getter)) {
      if (from.startsWith(this.fullName) || !varName.startsWith(HS_Common.Underscore)) {
        HS_Function func = defs[getter].value;
        return func.call(interpreter, line, column, []);
      }
      throw HSErr_Private(varName, line, column, interpreter.curFileName);
    } else if ((superClass != null) && (superClass.contains(varName))) {
      return superClass.fetch(varName, line, column, interpreter, nonExistError: nonExistError, from: closure.fullName);
    }

    if (closure != null) {
      return closure.fetch(varName, line, column, interpreter, nonExistError: nonExistError, from: closure.fullName);
    }

    if (nonExistError) throw HSErr_Undefined(varName, line, column, interpreter.curFileName);
    return null;
  }

  @override
  void assign(String varName, dynamic value, int line, int column, Interpreter interpreter,
      {bool nonExistError = true, String from = HS_Common.Global, bool recursive = true}) {
    var setter = '${HS_Common.Setter}$varName';
    if (defs.containsKey(varName)) {
      if (from.startsWith(this.fullName) || !varName.startsWith(HS_Common.Underscore)) {
        var vartype = defs[varName].type;
        if ((vartype == HS_Common.Any) || (vartype == HS_TypeOf(value))) {
          defs[varName].value = value;
          return;
        }
        throw HSErr_Type(varName, HS_TypeOf(value), vartype, line, column, interpreter.curFileName);
      }
      throw HSErr_Private(varName, line, column, interpreter.curFileName);
    } else if (defs.containsKey(setter)) {
      if (from.startsWith(this.fullName) || !varName.startsWith(HS_Common.Underscore)) {
        HS_Function setter_func = defs[setter].value;
        setter_func.call(interpreter, line, column, [value]);
        return;
      }
      throw HSErr_Private(varName, line, column, interpreter.curFileName);
    }

    if (closure != null) {
      closure.assign(varName, value, line, column, interpreter, from: from);
      return;
    }

    if (nonExistError) throw HSErr_Undefined(varName, line, column, interpreter.curFileName);
  }

  HS_Instance createInstance(Interpreter interpreter, int line, int column, Namespace closure,
      {String initterName, List<dynamic> args}) {
    var instance = HS_Instance(this);

    var save = interpreter.curContext;
    interpreter.curContext = instance;
    for (var decl in variables.values) {
      dynamic value;
      if (decl.initializer != null) {
        value = interpreter.evaluateExpr(decl.initializer);
      }

      if (decl.typename != null) {
        instance.define(decl.name.lexeme, decl.typename.lexeme, line, column, interpreter, value: value);
      } else {
        // 从初始化表达式推断变量类型
        if (value != null) {
          instance.define(decl.name.lexeme, HS_TypeOf(value), line, column, interpreter, value: value);
        } else {
          instance.define(decl.name.lexeme, HS_Common.Any, line, column, interpreter);
        }
      }
    }

    interpreter.curContext = save;

    initterName = HS_Common.Initter + (initterName == null ? name : initterName);

    var constructor = fetch(initterName, line, column, interpreter, nonExistError: false, from: name);

    if (constructor is HS_Function) {
      constructor.bind(instance, line, column, interpreter).call(interpreter, line, column, args ?? []);
    }

    return instance;
  }
}

class HS_Instance extends Namespace {
  @override
  String get type => klass.name;

  @override
  String toString() => '${HS_Common.InstanceString}"${klass.name}"';

  static int _instanceIndex = 0;

  HS_Class klass;

  HS_Instance(this.klass) //, int line, int column, String fileName)
      : super(name: HS_Common.Instance + (_instanceIndex++).toString(), closure: klass)
  //globalInterpreter.curFileName,
  //line, column, fileName,

  //spaceName: ofClass.name)
  {
    define(HS_Common.This, klass.name, null, null, null, value: this);
    //ofClass = globalInterpreter.fetchGlobal(class_name, line, column, fileName);
  }

  @override
  bool contains(String varName) => defs.containsKey(varName) || defs.containsKey('${HS_Common.Getter}$varName');

  @override
  dynamic fetch(String varName, int line, int column, Interpreter interpreter,
      {bool nonExistError = true, String from = HS_Common.Global, bool recursive = true}) {
    var getter = '${HS_Common.Getter}$varName';
    if (defs.containsKey(varName)) {
      if (!varName.startsWith(HS_Common.Underscore)) {
        return defs[varName].value;
      }
      throw HSErr_Private(varName, line, column, interpreter.curFileName);
    } else if (klass.contains(getter)) {
      HS_Function method = klass.fetch(getter, line, column, interpreter, nonExistError: false, from: klass.fullName);
      if ((method != null) && (!method.funcStmt.isStatic)) {
        return method.bind(this, line, column, interpreter).call(interpreter, line, column, []);
      }
    } else if (klass.contains(varName)) {
      HS_Function method = klass.fetch(varName, line, column, interpreter, nonExistError: false, from: klass.fullName);
      if ((method != null) && (!method.funcStmt.isStatic)) {
        return method.bind(this, line, column, interpreter);
      }
    }

    if (nonExistError) throw HSErr_UndefinedMember(varName, this.type, line, column, interpreter.curFileName);
  }

  @override
  void assign(String varName, dynamic value, int line, int column, Interpreter interpreter,
      {bool nonExistError = true, String from = HS_Common.Global, bool recursive = true}) {
    if (defs.containsKey(varName)) {
      if (!varName.startsWith(HS_Common.Underscore)) {
        var varType = defs[varName].type;
        if ((varType == HS_Common.Any) || ((value != null) && (varType == HS_TypeOf(value))) || (value == null)) {
          if (defs[varName].mutable) {
            defs[varName].value = value;
            return;
          }
          throw HSErr_Mutable(varName, line, column, interpreter.curFileName);
        }
        throw HSErr_Type(varName, HS_TypeOf(value), varType, line, column, interpreter.curFileName);
      }
      throw HSErr_Private(varName, line, column, interpreter.curFileName);
    } else {
      var setter = '${HS_Common.Setter}$varName';
      if (klass.contains(setter)) {
        HS_Function method = klass.fetch(setter, line, column, interpreter, nonExistError: false, from: klass.fullName);
        if ((method != null) && (!method.funcStmt.isStatic)) {
          method.bind(this, line, column, interpreter).call(interpreter, line, column, [value]);
          return;
        }
      }
    }

    if (nonExistError) throw HSErr_Undefined(varName, line, column, interpreter.curFileName);
  }

  dynamic invoke(String methodName, int line, int column, Interpreter interpreter,
      {bool error = true, List<dynamic> args}) {
    HS_Function method = klass.fetch(methodName, null, null, interpreter, from: klass.fullName);
    if ((method != null) && (!method.funcStmt.isStatic)) {
      return method.bind(this, line, column, interpreter).call(interpreter, null, null, args ?? []);
    }

    if (error) throw HSErr_Undefined(methodName, line, column, interpreter.curFileName);
  }
}
