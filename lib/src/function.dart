import 'class.dart';
import 'extern_class.dart' show HT_ExternFunc;
import 'namespace.dart';
import 'statement.dart';
import 'interpreter.dart';
import 'errors.dart';
import 'value.dart';
import 'lexicon.dart';

class HT_FunctionType extends HT_TypeId {
  final HT_TypeId returnType;
  final List<HT_TypeId> paramsTypes;

  HT_FunctionType(this.returnType, {List<HT_TypeId> arguments = const [], this.paramsTypes = const []})
      : super(HT_Lexicon.function, arguments: arguments);

  @override
  String toString() {
    var result = StringBuffer();
    result.write('$id');
    if (arguments.isNotEmpty) {
      result.write('<');
      for (var i = 0; i < arguments.length; ++i) {
        result.write(arguments[i]);
        if ((arguments.length > 1) && (i != arguments.length - 1)) result.write(', ');
      }
      result.write('>');
    }

    result.write('(');

    for (final param in paramsTypes) {
      result.write(param.id);
      //if (param.initializer != null)
      if (paramsTypes.length > 1) result.write(', ');
    }
    result.write('): ' + returnType.toString());
    return result.toString();
  }
}

class HT_Function with HT_Type {
  static int functionIndex = 0;

  HT_Namespace declContext;
  HT_Namespace _closure;
  //HT_Namespace _save;
  final String internalName;
  String get id => internalName ?? funcStmt.id;

  final FuncDeclStmt funcStmt;

  HT_FunctionType _typeid;
  @override
  HT_TypeId get typeid => _typeid;

  final HT_ExternFunc extern;

  HT_Function({this.funcStmt, this.internalName, List<HT_TypeId> typeArgs = const [], this.extern, this.declContext}) {
    //_save = _closure = closure;
    var paramsTypes = <HT_TypeId>[];
    for (final param in funcStmt.params) {
      paramsTypes.add(param.declType ?? HT_TypeId.ANY);
    }

    _typeid = HT_FunctionType(funcStmt.returnType, arguments: typeArgs, paramsTypes: paramsTypes);
  }

  @override
  String toString() {
    var result = StringBuffer();
    result.write('${HT_Lexicon.function}');
    if (id != null) result.write(' ${id ?? ''}');
    if (typeid.arguments.isNotEmpty) {
      result.write('<');
      for (var i = 0; i < typeid.arguments.length; ++i) {
        result.write(typeid.arguments[i]);
        if ((typeid.arguments.length > 1) && (i != typeid.arguments.length - 1)) result.write(', ');
      }
      result.write('>');
    }

    result.write('(');

    if (funcStmt.arity >= 0) {
      for (final param in funcStmt.params) {
        result.write(param.id.lexeme + ': ' + (param.declType?.toString() ?? HT_Lexicon.ANY));
        //if (param.initializer != null)
        if (funcStmt.params.length > 1) result.write(', ');
      }
    } else {
      result.write('... ');
      result.write(funcStmt.params.first.id.lexeme + ': ' + (funcStmt.params.first.declType ?? HT_Lexicon.ANY));
    }
    result.write('): ' + funcStmt.returnType?.toString() ?? HT_Lexicon.VOID);
    return result.toString();
  }

  dynamic call(HT_Interpreter interpreter, int line, int column,
      {List<dynamic> positionalArgs = const [], Map<String, dynamic> namedArgs = const {}, HT_Object object}) {
    if (funcStmt.arity >= 0) {
      if (positionalArgs.length < funcStmt.arity || positionalArgs.length > funcStmt.params.length) {
        throw HTErr_Arity(id, positionalArgs.length, funcStmt.arity, interpreter.curFileName, line, column);
      }
    } else {
      namedArgs[funcStmt.params.first.id.lexeme] = positionalArgs;
    }

    for (var i = 0; i < funcStmt.params.length; ++i) {
      if (funcStmt.params[i].isOptional && (i >= positionalArgs.length) && (funcStmt.params[i].initializer != null)) {
        positionalArgs.add(interpreter.evaluateExpr(funcStmt.params[i].initializer));
      } else if (funcStmt.params[i].isNamed &&
          (namedArgs[funcStmt.params[i].id.lexeme] == null) &&
          (funcStmt.params[i].initializer != null)) {
        namedArgs[funcStmt.params[i].id.lexeme] = interpreter.evaluateExpr(funcStmt.params[i].initializer);
      }
    }

    dynamic result;
    try {
      if (extern != null) {
        return extern(interpreter, externObject: object, positionalArgs: positionalArgs, namedArgs: namedArgs);
      } else if (funcStmt.definition != null) {
        if (funcStmt == null) throw HTErr_MissingFuncDef(id, interpreter.curFileName, line, column);
        //_save = _closure;
        //assert(closure != null);
        // 函数每次在调用时，才生成对应的作用域
        if (object != null) {
          _closure = HT_Namespace(id: '__${object.id}.$id${functionIndex++}', closure: object);
          _closure.define(HT_Lexicon.THIS, interpreter,
              declType: object.typeid, line: line, column: column, isImmutable: true);
        } else {
          _closure = HT_Namespace(id: '__$id${functionIndex++}', closure: declContext);
        }

        if (funcStmt.arity >= 0) {
          for (var i = 0; i < funcStmt.params.length; ++i) {
            var var_stmt = funcStmt.params[i];
            var arg;
            if (!var_stmt.isNamed) {
              arg = positionalArgs[i];
            } else {
              arg = namedArgs[var_stmt.id];
            }
            final arg_type_decl = var_stmt.declType;

            var arg_type = HT_TypeOf(arg);
            if (arg_type.isNotA(arg_type_decl)) {
              throw HTErr_ArgType(
                  arg.toString(), arg_type.toString(), arg_type_decl.toString(), interpreter.curFileName, line, column);
            }

            _closure.define(var_stmt.id.lexeme, interpreter,
                declType: arg_type_decl, line: line, column: column, value: arg);
          }
        } else {
          // “...”形式的variadic parameters本质是一个List
          // TODO: variadic parameters也需要类型检查
          _closure.define(funcStmt.params.first.id.lexeme, interpreter,
              declType: HT_TypeId.list, line: line, column: column, value: positionalArgs);
        }

        result = interpreter.executeBlock(funcStmt.definition, _closure);
        //_closure = _save;
      } else {
        throw HTErr_FuncWithoutBody(id, interpreter.curFileName, line, column);
      }
    } catch (returnValue) {
      if (returnValue is HT_Error) {
        rethrow;
      } else if ((returnValue is Exception) || (returnValue is Error) || (returnValue is NoSuchMethodError)) {
        throw HT_Error(returnValue.toString(), interpreter.curFileName, line, column);
      }

      var returned_type = HT_TypeOf(returnValue);

      if ((funcStmt != null) && (returned_type.isNotA(funcStmt.returnType))) {
        throw HTErr_ReturnType(
            returned_type.toString(), id, funcStmt.returnType.toString(), interpreter.curFileName, line, column);
      }

      if (returnValue is NullThrownError) return null;

      //_closure = _save;
      return returnValue;
    }

    // 如果函数体中没有直接return，则会返回最后一个语句的值
    return result;
  }
}