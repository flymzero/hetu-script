import 'dart:io';

import 'package:path/path.dart' as path;

import 'errors.dart';
import 'common.dart';
import 'expression.dart';
import 'statement.dart';
import 'namespace.dart';
import 'class.dart';
import 'function.dart';
import 'buildin.dart';
import 'lexer.dart';
import 'parser.dart';
import 'resolver.dart';

var globalInterpreter = _Interpreter();

/// 负责对语句列表进行最终解释执行
class _Interpreter implements ExprVisitor, StmtVisitor {
  static String _sdkDir;
  String workingDir;

  var _evaledFiles = <String>[];

  /// 本地变量表，不同语句块和环境的变量可能会有重名。
  /// 这里用表达式而不是用变量名做key，用表达式的值所属环境相对位置作为value
  //final _locals = <Expr, int>{};

  final _varPos = <Expr, String>{};

  /// 常量表
  final _constants = <dynamic>[];

  /// 保存当前语句所在的命名空间
  Namespace curContext;
  String _curFileName;
  String get curFileName => _curFileName;
  bool _isGlobal = true;

  /// external函数的空间
  final _external = Namespace(HS_Common.Global, null);

  Namespace _globalContext;

  Interpreter({Namespace global}) {
    _globalContext = global != null ? global : Namespace.global;
  }

  void init({
    String hetuSdkDir,
    String workingDir,
    String language = 'enUS',
    Map<String, HS_External> bindMap,
    Map<String, HS_External> linkMap,
  }) {
    try {
      _sdkDir = hetuSdkDir ?? 'hetu_core';
      this.workingDir = workingDir ?? path.current;

      // 必须在绑定函数前加载基础类Object和Function，因为函数本身也是对象
      curContext = _globalContext;
      print('Hetu: Loading core library.');
      eval(HS_Buildin.coreLib);

      // 绑定外部函数
      bindAll(HS_Buildin.bindmap);
      bindAll(bindMap);
      linkAll(HS_Buildin.linkmap);
      linkAll(linkMap);

      // 载入基础库
      eval('import \'hetu:core\\value\';import \'hetu:core\\system\';import \'hetu:core\\console\';');
    } catch (e) {
      stdout.write('\x1B[32m');
      print(e);
      print('Hetu init failed!');
      stdout.write('\x1B[m');
    }
  }

  void eval(String script, String fileName, String libName,
      {ParseStyle style = ParseStyle.library, String invokeFunc = null, List<dynamic> args}) {
    final _lexer = Lexer();
    final _parser = Parser();
    final _resolver = Resolver();
    var tokens = _lexer.lex(script);
    var statements = _parser.parse(tokens, style: style);
    _resolver.resolve(statements, fileName, libName);
    for (var stmt in statements) {
      evaluateStmt(stmt);
    }
    if ((style != ParseStyle.commandLine) && (invokeFunc != null)) {
      invoke(invokeFunc, args: args);
    }
    // interpreter(
    //   statements,
    //   invokeFunc: invokeFunc,
    //   args: args,
    // );
  }

  /// 解析文件
  void evalf(String filepath,
      {String libName = HS_Common.Global,
      ParseStyle style = ParseStyle.library,
      String invokeFunc = null,
      List<dynamic> args}) {
    _curFileName = path.absolute(filepath);
    if (!_evaledFiles.contains(curFileName)) {
      print('Hetu: Loading $filepath...');
      _evaledFiles.add(curFileName);
      curContext = Namespace(curFileName, enclosing: _globalContext);
      // if (libName != null) {
      //   _globalContext.define(libName, HS_Common.Namespace, null, null, _curFileName, value: curContext);
      // }

      eval(File(curFileName).readAsStringSync(), curFileName, libName,
          style: style, invokeFunc: invokeFunc, args: args);
    }
    _curFileName = null;
  }

  /// 解析目录下所有文件
  void evald(String dir, {ParseStyle style = ParseStyle.library, String invokeFunc = null, List<dynamic> args}) {
    var _dir = Directory(dir);
    var filelist = _dir.listSync();
    for (var file in filelist) {
      if (file is File) evalf(file.path);
    }
  }

  /// 解析命令行
  dynamic evalc(String input) {
    HS_Error.clear();
    try {
      final _lexer = Lexer();
      final _parser = Parser();
      var tokens = _lexer.lex(input, commandLine: true);
      var statements = _parser.parse(tokens, style: ParseStyle.commandLine);
      return executeBlock(statements, _globalContext);
    } catch (e) {
      print(e);
    } finally {
      HS_Error.output();
    }
  }

  // void addLocal(Expr expr, int distance) {
  //   _locals[expr] = distance;
  // }

  void addVarPos(Expr expr, String fullName) {
    _varPos[expr] = fullName;
  }

  /// 定义一个常量，然后返回数组下标
  /// 相同值的常量不会重复定义
  int addLiteral(dynamic literal) {
    var index = _constants.indexOf(literal);
    if (index == -1) {
      index = _constants.length;
      _constants.add(literal);
      return index;
    } else {
      return index;
    }
  }

  void define(String name, dynamic value) {
    if (_globalContext.contains(name)) {
      throw HSErr_Defined(name, null, null, globalInterpreter.curFileName);
    } else {
      _globalContext.define(name, value.type, null, null, globalInterpreter.curFileName, value: value);
    }
  }

  /// 绑定外部函数，绑定时无需在河图中声明
  void bind(String name, HS_External function) {
    if (_globalContext.contains(name)) {
      throw HSErr_Defined(name, null, null, globalInterpreter.curFileName);
    } else {
      // 绑定外部全局公共函数，参数列表数量设为-1，这样可以自由传递任何类型和数量
      var func_obj = HS_FuncObj(name, // null, null, globalInterpreter.curFileName,
          arity: -1,
          extern: function);
      _globalContext.define(name, HS_Common.FunctionObj, null, null, globalInterpreter.curFileName, value: func_obj);
    }
  }

  void bindAll(Map<String, HS_External> bindMap) {
    if (bindMap != null) {
      for (var key in bindMap.keys) {
        bind(key, bindMap[key]);
      }
    }
  }

  /// 链接外部函数，链接时，必须在河图中存在一个函数声明
  ///
  /// 此种形式的外部函数通常用于需要进行参数类型判断的情况
  void link(String name, HS_External function) {
    if (_external.contains(name)) {
      throw HSErr_Defined(name, null, null, globalInterpreter.curFileName);
    } else {
      _external.define(name, HS_Common.Dynamic, null, null, globalInterpreter.curFileName, value: function);
    }
  }

  void linkAll(Map<String, HS_External> linkMap) {
    if (linkMap != null) {
      for (var key in linkMap.keys) {
        link(key, linkMap[key]);
      }
    }
  }

  dynamic fetchGlobal(String name, int line, int column, String fileName) =>
      _globalContext.fetch(name, line, column, fileName);
  dynamic fetchExternal(String name, int line, int column, String fileName) =>
      _external.fetch(name, line, column, fileName);

  dynamic _getVar(String name, Expr expr) {
    var distance = _locals[expr];
    if (distance != null) {
      // 尝试获取当前环境中的本地变量
      return curContext.fetchAt(distance, name, expr.line, expr.column, expr.fileName, from: curContext.spaceName);
    } else {
      try {
        return curContext.fetch(name, expr.line, expr.column, expr.fileName, from: curContext.spaceName);
      } catch (e) {
        try {
          //TODO:在resolver中，每个expr保存一个Namespace的name，在Interpreter中，取出name，然后在对应的namespace中找到对应的value；
        } catch (e) {
          // 尝试获取全局变量
          return _globalContext.fetch(name, expr.line, expr.column, expr.fileName, from: curContext.spaceName);
        }
      }
    }
  }

  dynamic unwrap(dynamic value, int line, int column, String fileName) {
    if (value is HS_Value) {
      return value;
    } else if (value is num) {
      return HSVal_Num(value, line, column, fileName);
    } else if (value is bool) {
      return HSVal_Bool(value, line, column, fileName);
    } else if (value is String) {
      return HSVal_String(value, line, column, fileName);
    } else {
      return value;
    }
  }

  // void interpreter(List<Stmt> statements, {bool commandLine = false, String invokeFunc = null, List<dynamic> args}) {
  //   for (var stmt in statements) {
  //     evaluateStmt(stmt);
  //   }

  //   if ((!commandLine) && (invokeFunc != null)) {
  //     invoke(invokeFunc, args: args);
  //   }
  // }

  dynamic invoke(String name, {String classname, List<dynamic> args}) {
    HS_Error.clear();
    try {
      if (classname == null) {
        var func = _globalContext.fetch(name, null, null, globalInterpreter.curFileName);
        if (func is HS_FuncObj) {
          return func.call(null, null, globalInterpreter.curFileName, args ?? []);
        } else {
          throw HSErr_Undefined(name, null, null, globalInterpreter.curFileName);
        }
      } else {
        var klass = _globalContext.fetch(classname, null, null, globalInterpreter.curFileName);
        if (klass is HS_Class) {
          // 只能调用公共函数
          var func = klass.fetch(name, null, null, globalInterpreter.curFileName);
          if (func is HS_FuncObj) {
            return func.call(null, null, globalInterpreter.curFileName, args ?? []);
          } else {
            throw HSErr_Callable(name, null, null, globalInterpreter.curFileName);
          }
        } else {
          throw HSErr_Undefined(classname, null, null, globalInterpreter.curFileName);
        }
      }
    } catch (e) {
      print(e);
    } finally {
      HS_Error.output();
    }
  }

  void executeBlock(List<Stmt> statements, Namespace environment) {
    var saved_context = curContext;
    var saved_is_global = _isGlobal;

    try {
      curContext = environment;
      _isGlobal = false;
      for (var stmt in statements) {
        evaluateStmt(stmt);
      }
    } finally {
      curContext = saved_context;
      _isGlobal = saved_is_global;
    }
  }

  dynamic evaluateStmt(Stmt stmt) => stmt.accept(this);

  //dynamic evaluateExpr(Expr expr) => unwrap(expr.accept(this));
  dynamic evaluateExpr(Expr expr) => expr.accept(this);

  @override
  dynamic visitNullExpr(NullExpr expr) => null;

  @override
  dynamic visitLiteralExpr(LiteralExpr expr) => _constants[expr.constantIndex];

  @override
  dynamic visitListExpr(ListExpr expr) {
    var list = [];
    for (var item in expr.list) {
      list.add(evaluateExpr(item));
    }
    return list;
  }

  @override
  dynamic visitMapExpr(MapExpr expr) {
    var map = {};
    for (var key_expr in expr.map.keys) {
      var key = evaluateExpr(key_expr);
      var value = evaluateExpr(expr.map[key_expr]);
      map[key] = value;
    }
    return map;
  }

  @override
  dynamic visitVarExpr(VarExpr expr) => _getVar(expr.name.lexeme, expr);

  @override
  dynamic visitGroupExpr(GroupExpr expr) => evaluateExpr(expr.inner);

  @override
  dynamic visitUnaryExpr(UnaryExpr expr) {
    var value = evaluateExpr(expr.value);

    switch (expr.op.lexeme) {
      case HS_Common.Subtract:
        {
          if (value is num) {
            return -value;
          } else {
            throw HSErr_UndefinedOperator(value.toString(), expr.op.lexeme, expr.op.line, expr.op.column, curFileName);
          }
        }
        break;
      case HS_Common.Not:
        {
          if (value is bool) {
            return !value;
          } else {
            throw HSErr_UndefinedOperator(value.toString(), expr.op.lexeme, expr.op.line, expr.op.column, curFileName);
          }
        }
        break;
      default:
        throw HSErr_UndefinedOperator(value.toString(), expr.op.lexeme, expr.op.line, expr.op.column, curFileName);
        break;
    }
  }

  @override
  dynamic visitBinaryExpr(BinaryExpr expr) {
    var left = evaluateExpr(expr.left);
    var right;
    if (expr.op == HS_Common.And) {
      if (left is bool) {
        // 如果逻辑和操作的左操作数是假，则直接返回，不再判断后面的值
        if (!left) {
          return false;
        } else {
          right = evaluateExpr(expr.right);
          if (right is bool) {
            return left && right;
          } else {
            throw HSErr_UndefinedBinaryOperator(
                left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column, curFileName);
          }
        }
      } else {
        throw HSErr_UndefinedBinaryOperator(
            left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column, curFileName);
      }
    } else {
      right = evaluateExpr(expr.right);

      // TODO 操作符重载
      switch (expr.op.type) {
        case HS_Common.Or:
          {
            if (left is bool) {
              if (right is bool) {
                return left || right;
              } else {
                throw HSErr_UndefinedBinaryOperator(
                    left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column, curFileName);
              }
            } else {
              throw HSErr_UndefinedBinaryOperator(
                  left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column, curFileName);
            }
          }
          break;
        case HS_Common.Equal:
          return left == right;
          break;
        case HS_Common.NotEqual:
          return left != right;
          break;
        case HS_Common.Add:
        case HS_Common.Subtract:
          {
            if ((left is String) && (right is String)) {
              return left + right;
            } else if ((left is num) && (right is num)) {
              if (expr.op.lexeme == HS_Common.Add) {
                return left + right;
              } else if (expr.op.lexeme == HS_Common.Subtract) {
                return left - right;
              }
            } else {
              throw HSErr_UndefinedBinaryOperator(
                  left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column, curFileName);
            }
          }
          break;
        case HS_Common.Multiply:
        case HS_Common.Devide:
        case HS_Common.Modulo:
        case HS_Common.Greater:
        case HS_Common.GreaterOrEqual:
        case HS_Common.Lesser:
        case HS_Common.LesserOrEqual:
        case HS_Common.Is:
          {
            if ((expr.op == HS_Common.Is) && (right is HS_Class)) {
              return HS_TypeOf(left) == right.name;
            } else if (left is num) {
              if (right is num) {
                if (expr.op == HS_Common.Multiply) {
                  return left * right;
                } else if (expr.op == HS_Common.Devide) {
                  return left / right;
                } else if (expr.op == HS_Common.Modulo) {
                  return left % right;
                } else if (expr.op == HS_Common.Greater) {
                  return left > right;
                } else if (expr.op == HS_Common.GreaterOrEqual) {
                  return left >= right;
                } else if (expr.op == HS_Common.Lesser) {
                  return left < right;
                } else if (expr.op == HS_Common.LesserOrEqual) {
                  return left <= right;
                }
              } else {
                throw HSErr_UndefinedBinaryOperator(
                    left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column, curFileName);
              }
            } else {
              throw HSErr_UndefinedBinaryOperator(
                  left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column, curFileName);
            }
          }
          break;
        default:
          throw HSErr_UndefinedBinaryOperator(
              left.toString(), right.toString(), expr.op.lexeme, expr.op.line, expr.op.column, curFileName);
          break;
      }
    }
  }

  @override
  dynamic visitCallExpr(CallExpr expr) {
    var callee = evaluateExpr(expr.callee);
    var args = <dynamic>[];
    for (var arg in expr.args) {
      var value = evaluateExpr(arg);
      args.add(value);
    }

    if (callee is HS_FuncObj) {
      if (callee.functype != FuncStmtType.constructor) {
        return callee.call(expr.line, expr.column, expr.fileName, args ?? []);
      } else {
        //TODO命名构造函数
      }
    } else if (callee is HS_Class) {
      // for (var i = 0; i < callee.varStmts.length; ++i) {
      //   var param_type_token = callee.varStmts[i].typename;
      //   var arg = args[i];
      //   if (arg.type != param_type_token.lexeme) {
      //     throw HetuError(
      //         '(Interpreter) The argument type "${arg.type}" can\'t be assigned to the parameter type "${param_type_token.lexeme}".'
      //         ' [${param_type_token.line}, ${param_type_token.column}].');
      //   }
      // }

      return callee.createInstance(expr.line, expr.column, expr.fileName, args: args);
    } else {
      throw HSErr_Callable(callee.toString(), expr.callee.line, expr.callee.column, curFileName);
    }
  }

  @override
  dynamic visitAssignExpr(AssignExpr expr) {
    var value = evaluateExpr(expr.value);

    var distance = _locals[expr];
    if (distance != null) {
      // 尝试设置当前环境中的本地变量
      curContext.assignAt(distance, expr.variable.lexeme, value, expr.line, expr.column, expr.fileName,
          from: curContext.spaceName);
    } else {
      try {
        // 尝试设置当前实例中的类成员变量
        HS_Instance instance =
            curContext.fetch(HS_Common.This, expr.line, expr.column, expr.fileName, from: curContext.spaceName);
        instance.assign(expr.variable.lexeme, value, expr.line, expr.column, expr.fileName, from: curContext.spaceName);
      } catch (e) {
        if (e is HSErr_Undefined) {
          // 尝试设置全局变量
          _globalContext.assign(expr.variable.lexeme, value, expr.line, expr.column, expr.fileName);
        } else {
          throw e;
        }
      }
    }

    // 返回右值
    return value;
  }

  @override
  dynamic visitThisExpr(ThisExpr expr) => _getVar(HS_Common.This, expr);

  @override
  dynamic visitSubGetExpr(SubGetExpr expr) {
    var collection = evaluateExpr(expr.collection);
    var key = evaluateExpr(expr.key);
    if (collection is HSVal_List) {
      return collection.value.elementAt(key);
    } else if (collection is List) {
      return collection[key];
    } else if (collection is HSVal_Map) {
      return collection.value[key];
    } else if (collection is Map) {
      return collection[key];
    }

    throw HSErr_SubGet(collection.toString(), expr.line, expr.column, expr.fileName);
  }

  @override
  dynamic visitSubSetExpr(SubSetExpr expr) {
    var collection = evaluateExpr(expr.collection);
    var key = evaluateExpr(expr.key);
    var value = evaluateExpr(expr.value);
    if ((collection is HSVal_List) || (collection is HSVal_Map)) {
      collection.value[key] = value;
    } else if ((collection is List) || (collection is Map)) {
      return collection[key] = value;
    }

    throw HSErr_SubGet(collection.toString(), expr.line, expr.column, expr.fileName);
  }

  @override
  dynamic visitMemberGetExpr(MemberGetExpr expr) {
    var object = evaluateExpr(expr.collection);
    if ((object is HS_Instance) || (object is HS_Class)) {
      return object.fetch(expr.key.lexeme, expr.line, expr.column, expr.fileName, from: curContext.spaceName);
    } else if (object is num) {
      return HSVal_Num(object, expr.line, expr.column, expr.fileName)
          .fetch(expr.key.lexeme, expr.line, expr.column, expr.fileName, from: curContext.spaceName);
    } else if (object is bool) {
      return HSVal_Bool(object, expr.line, expr.column, expr.fileName)
          .fetch(expr.key.lexeme, expr.line, expr.column, expr.fileName, from: curContext.spaceName);
    } else if (object is String) {
      return HSVal_String(object, expr.line, expr.column, expr.fileName)
          .fetch(expr.key.lexeme, expr.line, expr.column, expr.fileName, from: curContext.spaceName);
    } else if (object is List) {
      return HSVal_List(object, expr.line, expr.column, expr.fileName)
          .fetch(expr.key.lexeme, expr.line, expr.column, expr.fileName, from: curContext.spaceName);
    } else if (object is Map) {
      return HSVal_Map(object, expr.line, expr.column, expr.fileName)
          .fetch(expr.key.lexeme, expr.line, expr.column, expr.fileName, from: curContext.spaceName);
    }

    throw HSErr_Get(object.toString(), expr.line, expr.column, expr.fileName);
  }

  @override
  dynamic visitMemberSetExpr(MemberSetExpr expr) {
    dynamic object = evaluateExpr(expr.collection);
    var value = evaluateExpr(expr.value);
    if ((object is HS_Instance) || (object is HS_Class)) {
      object.assign(expr.key.lexeme, value, expr.line, expr.column, expr.fileName, from: curContext.spaceName);
      return value;
    } else {
      throw HSErr_Get(object.toString(), expr.key.line, expr.key.column, expr.fileName);
    }
  }

  // TODO: import as 命名空间
  @override
  dynamic visitImportStmt(ImportStmt stmt) {
    String lib_name;
    if (stmt.filepath.startsWith('hetu:')) {
      lib_name = stmt.filepath.substring(5);
      lib_name = path.join(_sdkDir, lib_name + '.ht');
    } else {
      lib_name = path.join(workingDir, stmt.filepath);
    }
    evalf(lib_name, spaceName: stmt.spacename);
  }

  @override
  void visitVarStmt(VarStmt stmt) {
    dynamic value;
    if (stmt.initializer != null) {
      value = evaluateExpr(stmt.initializer);
    }

    Namespace space;
    space = _isGlobal && !stmt.name.lexeme.startsWith(HS_Common.Underscore) ? _globalContext : curContext;

    if (stmt.typename.lexeme == HS_Common.Dynamic) {
      space.define(stmt.name.lexeme, stmt.typename.lexeme, stmt.typename.line, stmt.typename.column, curFileName,
          value: value);
    } else if (stmt.typename.lexeme == HS_Common.Var) {
      // 如果用了var关键字，则从初始化表达式推断变量类型
      if (value != null) {
        space.define(stmt.name.lexeme, HS_TypeOf(value), stmt.typename.line, stmt.typename.column, curFileName,
            value: value);
      } else {
        space.define(stmt.name.lexeme, HS_Common.Dynamic, stmt.typename.line, stmt.typename.column, curFileName);
      }
    } else {
      // 接下来define函数会判断类型是否符合声明
      space.define(stmt.name.lexeme, stmt.typename.lexeme, stmt.typename.line, stmt.typename.column, curFileName,
          value: value);
    }
  }

  @override
  void visitExprStmt(ExprStmt stmt) => evaluateExpr(stmt.expr);

  @override
  void visitBlockStmt(BlockStmt stmt) {
    executeBlock(stmt.block, Namespace(globalInterpreter.curFileName, enclosing: curContext));
  }

  @override
  void visitReturnStmt(ReturnStmt stmt) {
    if (stmt.expr != null) {
      throw evaluateExpr(stmt.expr);
    }
    throw null;
  }

  @override
  void visitIfStmt(IfStmt stmt) {
    var value = evaluateExpr(stmt.condition);
    if (value is bool) {
      if (value) {
        evaluateStmt(stmt.thenBranch);
      } else if (stmt.elseBranch != null) {
        evaluateStmt(stmt.elseBranch);
      }
    } else {
      throw HSErr_Condition(stmt.condition.line, stmt.condition.column, stmt.condition.fileName);
    }
  }

  @override
  void visitWhileStmt(WhileStmt stmt) {
    var value = evaluateExpr(stmt.condition);
    if (value is bool) {
      while ((value is bool) && (value)) {
        try {
          evaluateStmt(stmt.loop);
          value = evaluateExpr(stmt.condition);
        } catch (error) {
          if (error is HS_Break) {
            return;
          } else if (error is HS_Continue) {
            continue;
          } else {
            throw error;
          }
        }
      }
    } else {
      throw HSErr_Condition(stmt.condition.line, stmt.condition.column, stmt.condition.fileName);
    }
  }

  @override
  void visitBreakStmt(BreakStmt stmt) {
    throw HS_Break();
  }

  @override
  void visitContinueStmt(ContinueStmt stmt) {
    throw HS_Continue();
  }

  @override
  void visitFuncStmt(FuncStmt stmt) {
    // 构造函数本身不注册为变量
    if (stmt.functype != FuncStmtType.constructor) {
      HS_FuncObj func;
      if (stmt.isExtern) {
        var externFunc = _external.fetch(stmt.name.lexeme, stmt.name.line, stmt.name.column, curFileName);
        func = HS_FuncObj(stmt.internalName,
            funcStmt: stmt, extern: externFunc, functype: stmt.functype, arity: stmt.arity);
      } else {
        func = HS_FuncObj(stmt.name.lexeme, // stmt.name.line, stmt.name.column, curFileName,
            funcStmt: stmt,
            closure: curContext,
            functype: stmt.functype,
            arity: stmt.arity);
      }
      Namespace space;
      stmt.name.lexeme.startsWith(HS_Common.Underscore) ? space = curContext : space = _globalContext;
      space.define(stmt.name.lexeme, HS_Common.FunctionObj, stmt.name.line, stmt.name.column, curFileName, value: func);
    }
  }

  @override
  void visitClassStmt(ClassStmt stmt) {
    HS_Class superClass;

    //TODO: while superClass != null, inherit all...

    if (stmt.superClass == null) {
      if (stmt.name.lexeme != HS_Common.Object)
        superClass = globalInterpreter.fetchGlobal(HS_Common.Object, stmt.name.line, stmt.name.column, curFileName);
    } else {
      superClass = evaluateExpr(stmt.superClass);
      if (superClass is! HS_Class) {
        throw HSErr_Extends(superClass.name, stmt.superClass.line, stmt.superClass.column, curFileName);
      }
    }

    var klass = HS_Class(stmt.name.lexeme, //stmt.name.line, stmt.name.column, curFileName,
        superClass: superClass);

    if (stmt.superClass != null) {
      klass.define(HS_Common.Super, HS_Common.Class, stmt.name.line, stmt.name.column, curFileName, value: superClass);
    }

    // 在开头就定义类本身的名字，这样才可以在类定义体中使用类本身
    Namespace space;
    space = _isGlobal && !stmt.name.lexeme.startsWith(HS_Common.Underscore) ? _globalContext : curContext;
    space.define(stmt.name.lexeme, HS_Common.Class, stmt.name.line, stmt.name.column, curFileName, value: klass);

    for (var variable in stmt.variables) {
      if (variable.isStatic) {
        dynamic value;
        if (variable.initializer != null) {
          var save = curContext;
          curContext = klass;
          value = globalInterpreter.evaluateExpr(variable.initializer);
          curContext = save;
        } else if (variable.isExtern) {
          value = globalInterpreter.fetchExternal('${stmt.name.lexeme}${HS_Common.Dot}${variable.name.lexeme}',
              variable.name.line, variable.name.column, curFileName);
        }

        if (variable.typename.lexeme == HS_Common.Dynamic) {
          klass.define(variable.name.lexeme, variable.typename.lexeme, variable.typename.line, variable.typename.column,
              curFileName,
              value: value);
        } else if (variable.typename.lexeme == HS_Common.Var) {
          // 如果用了var关键字，则从初始化表达式推断变量类型
          if (value != null) {
            klass.define(
                variable.name.lexeme, HS_TypeOf(value), variable.typename.line, variable.typename.column, curFileName,
                value: value);
          } else {
            klass.define(
                variable.name.lexeme, HS_Common.Dynamic, variable.typename.line, variable.typename.column, curFileName);
          }
        } else {
          // 接下来define函数会判断类型是否符合声明
          klass.define(variable.name.lexeme, variable.typename.lexeme, variable.typename.line, variable.typename.column,
              curFileName,
              value: value);
        }
      } else {
        klass.addVariable(variable);
      }
    }

    for (var method in stmt.methods) {
      if (klass.containsKey(method.name.lexeme)) {
        throw HSErr_Defined(method.name.lexeme, method.name.line, method.name.column, curFileName);
      }

      HS_FuncObj func;
      if (method.isExtern) {
        var externFunc = globalInterpreter.fetchExternal('${stmt.name.lexeme}${HS_Common.Dot}${method.internalName}',
            method.name.line, method.name.column, curFileName);
        func = HS_FuncObj(method.internalName, //method.name.line, method.name.column, curFileName,
            className: stmt.name.lexeme,
            funcStmt: method,
            extern: externFunc,
            functype: method.functype,
            arity: method.arity);
      } else {
        Namespace closure;
        if (method.isStatic) {
          // 静态函数外层是类本身
          closure = klass;
        } else {
          // 成员函数外层是实例，在某个实例取出函数的时候才绑定到那个实例上
          closure = null;
        }
        func = HS_FuncObj(method.internalName, //method.name.line, method.name.column, curFileName,
            className: stmt.name.lexeme,
            funcStmt: method,
            closure: closure,
            functype: method.functype,
            arity: method.arity);
      }
      if (method.isStatic) {
        klass.define(method.internalName, HS_Common.FunctionObj, method.name.line, method.name.column, curFileName,
            value: func);
      } else {
        klass.addMethod(method.internalName, func, method.name.line, method.name.column, curFileName);
      }
    }
  }
}
