import 'dart:typed_data';
import 'dart:convert';

import '../implementation/parser.dart';
import '../implementation/lexicon.dart';
import '../implementation/const_table.dart';
import '../implementation/class.dart';
import '../implementation/lexer.dart';
import '../common/constants.dart';
import '../common/errors.dart';
import '../plugin/moduleHandler.dart';
import 'opcode.dart';
import 'bytecode_interpreter.dart';
import 'bytecode_source.dart';

class HTRegIdx {
  static const value = 0;
  static const symbol = 1;
  static const objectSymbol = 2;
  static const refType = 3;
  static const typeArgs = 4;
  static const loopCount = 5;
  static const anchor = 6;
  static const assign = 7;
  static const orLeft = 8;
  static const andLeft = 9;
  static const equalLeft = 10;
  static const relationLeft = 11;
  static const addLeft = 12;
  static const multiplyLeft = 13;
  static const postfixObject = 14;
  static const postfixKey = 15;

  static const length = 16;
}

class BytecodeDeclarationBlock implements DeclarationBlock {
  final enumDecls = <String, Uint8List>{};
  final funcDecls = <String, Uint8List>{};
  final classDecls = <String, Uint8List>{};
  final varDecls = <String, Uint8List>{};

  @override
  bool contains(String id) =>
      enumDecls.containsKey(id) ||
      funcDecls.containsKey(id) ||
      classDecls.containsKey(id) ||
      varDecls.containsKey(id);
}

/// Utility class that parse a string content into a uint8 list
class HTCompiler extends Parser with ConstTable, HetuRef {
  /// Hetu script bytecode's bytecode signature
  static const hetuSignatureData = [8, 5, 20, 21];

  /// The version of the compiled bytecode,
  /// used to determine compatibility.
  static const hetuVersionData = [0, 1, 0, 0];

  late BytecodeDeclarationBlock _mainBlock;
  late BytecodeDeclarationBlock _curBlock;

  final _importedModules = <ImportInfo>[];

  late String _curModuleFullName;
  @override
  String get curModuleFullName => _curModuleFullName;

  ClassInfo? _curClass;
  FunctionType? _curFuncType;

  var _leftValueLegality = false;

  /// Compiles a Token list.
  Future<HTBytecodeCompilation> compile(
      String content, HTModuleHandler moduleHandler, String fullName,
      {ParserConfig config = const ParserConfig()}) async {
    this.config = config;
    _curModuleFullName = fullName;

    _curBlock = _mainBlock = BytecodeDeclarationBlock();
    _importedModules.clear();
    _curClass = null;
    _curFuncType = null;

    final compilation = HTBytecodeCompilation();

    final tokens = Lexer().lex(content, fullName);
    addTokens(tokens);
    final bytesBuilder = BytesBuilder();
    while (curTok.type != HTLexicon.endOfFile) {
      final exprStmts = _parseStmt(codeType: config.codeType);
      bytesBuilder.add(exprStmts);
    }
    final code = bytesBuilder.toBytes();

    for (final importInfo in _importedModules) {
      final importedFullName = moduleHandler.resolveFullName(importInfo.key,
          fullName.startsWith(HTLexicon.anonymousScript) ? null : fullName);
      if (!moduleHandler.hasModule(importedFullName)) {
        _curModuleFullName = importedFullName;
        final importedContent = await moduleHandler.getContent(importedFullName,
            curModuleFullName: _curModuleFullName);
        final compiler2 = HTCompiler();
        final compilation2 = await compiler2.compile(
            importedContent.content, moduleHandler, importedFullName);

        compilation.addAll(compilation2);
      }
    }

    final mainBuilder = BytesBuilder();
    // 河图字节码标记
    mainBuilder.addByte(HTOpCode.signature);
    mainBuilder.add(hetuSignatureData);
    // 版本号
    mainBuilder.addByte(HTOpCode.version);
    mainBuilder.add(hetuVersionData);
    // 添加常量表
    mainBuilder.addByte(HTOpCode.constTable);
    mainBuilder.add(_uint16(intTable.length));
    for (final value in intTable) {
      mainBuilder.add(_int64(value));
    }
    mainBuilder.add(_uint16(floatTable.length));
    for (final value in floatTable) {
      mainBuilder.add(_float64(value));
    }
    mainBuilder.add(_uint16(stringTable.length));
    for (final value in stringTable) {
      mainBuilder.add(_utf8String(value));
    }
    // 将变量表前置，总是按照：枚举、函数、类、变量这个顺序
    for (final decl in _mainBlock.enumDecls.values) {
      mainBuilder.add(decl);
    }
    for (final decl in _mainBlock.funcDecls.values) {
      mainBuilder.add(decl);
    }
    for (final decl in _mainBlock.classDecls.values) {
      mainBuilder.add(decl);
    }
    for (final decl in _mainBlock.varDecls.values) {
      mainBuilder.add(decl);
    }
    // 添加程序本体代码
    mainBuilder.add(code);

    compilation.add(HTBytecodeSource(fullName, mainBuilder.toBytes()));

    return compilation;
  }

  /// -32768 to 32767
  Uint8List _int16(int value) =>
      Uint8List(2)..buffer.asByteData().setInt16(0, value, Endian.big);

  /// 0 to 65,535
  Uint8List _uint16(int value) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, value, Endian.big);

  /// 0 to 4,294,967,295
  // Uint8List _uint32(int value) => Uint8List(4)..buffer.asByteData().setUint32(0, value, Endian.big);

  /// -9,223,372,036,854,775,808 to 9,223,372,036,854,775,807
  Uint8List _int64(int value) =>
      Uint8List(8)..buffer.asByteData().setInt64(0, value, Endian.big);

  Uint8List _float64(double value) =>
      Uint8List(8)..buffer.asByteData().setFloat64(0, value, Endian.big);

  Uint8List _shortUtf8String(String value) {
    final bytesBuilder = BytesBuilder();
    final stringData = utf8.encoder.convert(value);
    bytesBuilder.addByte(stringData.length);
    bytesBuilder.add(stringData);
    return bytesBuilder.toBytes();
  }

  Uint8List _utf8String(String value) {
    final bytesBuilder = BytesBuilder();
    final stringData = utf8.encoder.convert(value);
    bytesBuilder.add(_uint16(stringData.length));
    bytesBuilder.add(stringData);
    return bytesBuilder.toBytes();
  }

  Uint8List _parseStmt(
      {CodeType codeType = CodeType.module, bool endOfExec = false}) {
    final bytesBuilder = BytesBuilder();
    switch (codeType) {
      case CodeType.script:
        switch (curTok.type) {
          case HTLexicon.IMPORT:
            _parseImportStmt();
            break;
          case HTLexicon.EXTERNAL:
            advance(1);
            switch (curTok.type) {
              case HTLexicon.ABSTRACT:
                advance(1);
                if (curTok.type == HTLexicon.CLASS) {
                  _parseClassDeclStmt(isAbstract: true, isExternal: true);
                } else {
                  throw HTError.unexpected(
                      SemanticType.classDeclStmt, curTok.lexeme);
                }
                break;
              case HTLexicon.CLASS:
                _parseClassDeclStmt(isExternal: true);
                break;
              case HTLexicon.ENUM:
                _parseEnumDeclStmt(isExternal: true);
                break;
              case HTLexicon.VAR:
              case HTLexicon.LET:
              case HTLexicon.CONST:
                throw HTError.externalVar();
              case HTLexicon.FUNCTION:
                if (expect([HTLexicon.FUNCTION, HTLexicon.identifier])) {
                  _parseFuncDeclaration(isExternal: true);
                } else {
                  throw HTError.unexpected(
                      SemanticType.funcDeclStmt, peek(1).lexeme);
                }
                break;
              default:
                throw HTError.unexpected(HTLexicon.declStmt, curTok.lexeme);
            }
            break;
          case HTLexicon.ABSTRACT:
            advance(1);
            if (curTok.type == HTLexicon.CLASS) {
              _parseClassDeclStmt(isAbstract: true);
            } else {
              throw HTError.unexpected(
                  SemanticType.classDeclStmt, curTok.lexeme);
            }
            break;
          case HTLexicon.ENUM:
            _parseEnumDeclStmt();
            break;
          case HTLexicon.CLASS:
            _parseClassDeclStmt();
            break;
          case HTLexicon.VAR:
            _parseVarDeclStmt();
            break;
          case HTLexicon.LET:
            _parseVarDeclStmt(typeInferrence: true);
            break;
          case HTLexicon.CONST:
            _parseVarDeclStmt(typeInferrence: true, isImmutable: true);
            break;
          case HTLexicon.FUNCTION:
            if (expect([HTLexicon.FUNCTION, HTLexicon.identifier])) {
              _parseFuncDeclaration();
            } else if (expect([
              HTLexicon.FUNCTION,
              HTLexicon.squareLeft,
              HTLexicon.identifier,
              HTLexicon.squareRight,
              HTLexicon.identifier
            ])) {
              _parseFuncDeclaration();
            } else {
              final func = _parseExprStmt();
              bytesBuilder.add(func);
            }
            break;
          case HTLexicon.IF:
            final ifStmt = _parseIfStmt();
            bytesBuilder.add(ifStmt);
            break;
          case HTLexicon.WHILE:
            final whileStmt = _parseWhileStmt();
            bytesBuilder.add(whileStmt);
            break;
          case HTLexicon.DO:
            final doStmt = _parseDoStmt();
            bytesBuilder.add(doStmt);
            break;
          case HTLexicon.FOR:
            final forStmt = _parseForStmt();
            bytesBuilder.add(forStmt);
            break;
          case HTLexicon.WHEN:
            final whenStmt = _parseWhenStmt();
            bytesBuilder.add(whenStmt);
            break;
          case HTLexicon.semicolon:
            advance(1);
            break;
          default:
            final expr = _parseExprStmt();
            bytesBuilder.add(expr);
            break;
        }
        break;
      case CodeType.module:
        switch (curTok.type) {
          case HTLexicon.IMPORT:
            _parseImportStmt();
            break;
          case HTLexicon.ABSTRACT:
            advance(1);
            if (curTok.type == HTLexicon.CLASS) {
              _parseClassDeclStmt(isAbstract: true);
            } else {
              throw HTError.unexpected(
                  SemanticType.classDeclStmt, curTok.lexeme);
            }
            break;
          case HTLexicon.EXTERNAL:
            advance(1);
            switch (curTok.type) {
              case HTLexicon.ABSTRACT:
                advance(1);
                if (curTok.type == HTLexicon.CLASS) {
                  _parseClassDeclStmt(isAbstract: true, isExternal: true);
                } else {
                  throw HTError.unexpected(
                      SemanticType.classDeclStmt, curTok.lexeme);
                }
                break;
              case HTLexicon.CLASS:
                _parseClassDeclStmt(isExternal: true);
                break;
              case HTLexicon.ENUM:
                _parseEnumDeclStmt(isExternal: true);
                break;
              case HTLexicon.FUNCTION:
                if (expect([HTLexicon.FUNCTION, HTLexicon.identifier])) {
                  _parseFuncDeclaration(isExternal: true);
                } else {
                  throw HTError.unexpected(
                      SemanticType.funcDeclStmt, peek(1).lexeme);
                }
                break;
              case HTLexicon.VAR:
              case HTLexicon.LET:
              case HTLexicon.CONST:
                throw HTError.externalVar();
              default:
                throw HTError.unexpected(HTLexicon.declStmt, curTok.lexeme);
            }
            break;
          case HTLexicon.ENUM:
            _parseEnumDeclStmt();
            break;
          case HTLexicon.CLASS:
            _parseClassDeclStmt();
            break;
          case HTLexicon.VAR:
            _parseVarDeclStmt(lateInitialize: true);
            break;
          case HTLexicon.LET:
            _parseVarDeclStmt(typeInferrence: true, lateInitialize: true);
            break;
          case HTLexicon.CONST:
            _parseVarDeclStmt(
                typeInferrence: true, isImmutable: true, lateInitialize: true);
            break;
          case HTLexicon.FUNCTION:
            if (expect([HTLexicon.FUNCTION, HTLexicon.identifier])) {
              _parseFuncDeclaration();
            } else if (expect([
              HTLexicon.FUNCTION,
              HTLexicon.squareLeft,
              HTLexicon.identifier,
              HTLexicon.squareRight,
              HTLexicon.identifier
            ])) {
              _parseFuncDeclaration();
            } else {
              throw HTError.unexpected(
                  SemanticType.funcDeclStmt, peek(1).lexeme);
            }
            break;
          default:
            throw HTError.unexpected(HTLexicon.declStmt, curTok.lexeme);
        }
        break;
      case CodeType.function:
        switch (curTok.type) {
          case HTLexicon.VAR:
            _parseVarDeclStmt();
            break;
          case HTLexicon.LET:
            _parseVarDeclStmt(typeInferrence: true);
            break;
          case HTLexicon.CONST:
            _parseVarDeclStmt(typeInferrence: true, isImmutable: true);
            break;
          case HTLexicon.FUNCTION:
            if (expect([HTLexicon.FUNCTION, HTLexicon.identifier]) ||
                expect([
                  HTLexicon.FUNCTION,
                  HTLexicon.squareLeft,
                  HTLexicon.identifier,
                  HTLexicon.squareRight,
                  HTLexicon.identifier
                ])) {
              _parseFuncDeclaration();
            } else {
              final func =
                  _parseFuncDeclaration(funcType: FunctionType.literal);
              bytesBuilder.add(func);
            }
            break;
          case HTLexicon.IF:
            final ifStmt = _parseIfStmt();
            bytesBuilder.add(ifStmt);
            break;
          case HTLexicon.WHILE:
            final whileStmt = _parseWhileStmt();
            bytesBuilder.add(whileStmt);
            break;
          case HTLexicon.DO:
            final doStmt = _parseDoStmt();
            bytesBuilder.add(doStmt);
            break;
          case HTLexicon.FOR:
            final forStmt = _parseForStmt();
            bytesBuilder.add(forStmt);
            break;
          case HTLexicon.WHEN:
            final whenStmt = _parseWhenStmt();
            bytesBuilder.add(whenStmt);
            break;
          case HTLexicon.BREAK:
            advance(1);
            bytesBuilder.addByte(HTOpCode.breakLoop);
            break;
          case HTLexicon.CONTINUE:
            advance(1);
            bytesBuilder.addByte(HTOpCode.continueLoop);
            break;
          case HTLexicon.RETURN:
            if (_curFuncType != FunctionType.constructor) {
              final returnStmt = _parseReturnStmt();
              bytesBuilder.add(returnStmt);
            } else {
              throw HTError.outsideReturn();
            }
            break;
          case HTLexicon.semicolon:
            advance(1);
            break;
          default:
            final expr = _parseExprStmt();
            bytesBuilder.add(expr);
            break;
        }
        break;
      case CodeType.klass:
        final isExternal = expect([HTLexicon.EXTERNAL], consume: true);
        final isStatic = expect([HTLexicon.STATIC], consume: true);
        switch (curTok.type) {
          case HTLexicon.VAR:
            _parseVarDeclStmt(
                isMember: true,
                isExternal: isExternal || (_curClass?.isExternal ?? false),
                isStatic: isStatic,
                lateInitialize: true);
            break;
          case HTLexicon.LET:
            _parseVarDeclStmt(
                isMember: true,
                typeInferrence: true,
                isExternal: isExternal || (_curClass?.isExternal ?? false),
                isStatic: isStatic,
                lateInitialize: true);
            break;
          case HTLexicon.CONST:
            _parseVarDeclStmt(
                isMember: true,
                typeInferrence: true,
                isExternal: isExternal || (_curClass?.isExternal ?? false),
                isImmutable: true,
                isStatic: isStatic,
                lateInitialize: true);
            break;
          case HTLexicon.FUNCTION:
            _parseFuncDeclaration(
                funcType: FunctionType.method,
                isExternal: isExternal || (_curClass?.isExternal ?? false),
                isStatic: isStatic);
            break;
          case HTLexicon.CONSTRUCT:
            if (_curClass!.isAbstract) {
              throw HTError.abstractCtor();
            }
            if (isStatic) {
              throw HTError.unexpected(HTLexicon.declStmt, HTLexicon.CONSTRUCT);
            }
            _parseFuncDeclaration(
              funcType: FunctionType.constructor,
              isExternal: isExternal || (_curClass?.isExternal ?? false),
            );
            break;
          case HTLexicon.GET:
            _parseFuncDeclaration(
                funcType: FunctionType.getter,
                isExternal: isExternal || (_curClass?.isExternal ?? false),
                isStatic: isStatic);
            break;
          case HTLexicon.SET:
            _parseFuncDeclaration(
                funcType: FunctionType.setter,
                isExternal: isExternal || (_curClass?.isExternal ?? false),
                isStatic: isStatic);
            break;
          default:
            throw HTError.unexpected(HTLexicon.declStmt, curTok.lexeme);
        }
        break;
      case CodeType.expression:
        final expr = _parseExpr();
        bytesBuilder.add(expr);
        break;
    }
    if (endOfExec) {
      bytesBuilder.addByte(HTOpCode.endOfExec);
    }

    return bytesBuilder.toBytes();
  }

  void _parseImportStmt() async {
    advance(1);
    String key = match(HTLexicon.string).literal;
    String? alias;
    if (expect([HTLexicon.AS], consume: true)) {
      alias = match(HTLexicon.identifier).lexeme;

      if (alias.isEmpty) {
        throw HTError.emptyString();
      }
    }

    final showList = <String>[];
    if (expect([HTLexicon.SHOW], consume: true)) {
      while (curTok.type == HTLexicon.identifier) {
        showList.add(advance(1).lexeme);
        if (curTok.type != HTLexicon.comma) {
          break;
        } else {
          advance(1);
        }
      }
    }

    expect([HTLexicon.semicolon], consume: true);

    _importedModules.add(ImportInfo(key, name: alias, showList: showList));
  }

  Uint8List _debugInfo() {
    final bytesBuilder = BytesBuilder();
    bytesBuilder.addByte(HTOpCode.debugInfo);
    final line = Uint8List(2)
      ..buffer.asByteData().setUint16(0, curTok.line, Endian.big);
    bytesBuilder.add(line);
    final column = Uint8List(2)
      ..buffer.asByteData().setUint16(0, curTok.column, Endian.big);
    bytesBuilder.add(column);
    return bytesBuilder.toBytes();
  }

  Uint8List _localNull() {
    final bytesBuilder = BytesBuilder();
    if (config.lineInfo) {
      bytesBuilder.add(_debugInfo());
    }
    bytesBuilder.addByte(HTOpCode.local);
    bytesBuilder.addByte(HTValueTypeCode.NULL);
    return bytesBuilder.toBytes();
  }

  Uint8List _localBool(bool value) {
    final bytesBuilder = BytesBuilder();
    if (config.lineInfo) {
      bytesBuilder.add(_debugInfo());
    }
    bytesBuilder.addByte(HTOpCode.local);
    bytesBuilder.addByte(HTValueTypeCode.boolean);
    bytesBuilder.addByte(value ? 1 : 0);
    return bytesBuilder.toBytes();
  }

  Uint8List _localConst(int constIndex, int type) {
    final bytesBuilder = BytesBuilder();
    if (config.lineInfo) {
      bytesBuilder.add(_debugInfo());
    }
    bytesBuilder.addByte(HTOpCode.local);
    bytesBuilder.addByte(type);
    bytesBuilder.add(_uint16(constIndex));
    return bytesBuilder.toBytes();
  }

  Uint8List _localSymbol({String? id, bool isGetKey = false}) {
    final symbolId = id ?? match(HTLexicon.identifier).lexeme;
    final bytesBuilder = BytesBuilder();
    if (config.lineInfo) {
      bytesBuilder.add(_debugInfo());
    }
    bytesBuilder.addByte(HTOpCode.local);
    bytesBuilder.addByte(HTValueTypeCode.symbol);
    bytesBuilder.add(_shortUtf8String(symbolId));
    bytesBuilder.addByte(isGetKey ? 1 : 0);
    if (expect([
          HTLexicon.angleLeft,
          HTLexicon.identifier,
          HTLexicon.angleRight
        ]) ||
        expect(
            [HTLexicon.angleLeft, HTLexicon.identifier, HTLexicon.angleLeft]) ||
        expect([HTLexicon.angleLeft, HTLexicon.identifier, HTLexicon.comma])) {
      bytesBuilder.addByte(1); // bool: has type args
      advance(1);
      final typeArgs = <Uint8List>[];
      while (curTok.type != HTLexicon.angleRight &&
          curTok.type != HTLexicon.endOfFile) {
        final typeArg = _parseTypeExpr();
        typeArgs.add(typeArg);
      }
      bytesBuilder.addByte(typeArgs.length);
      for (final arg in typeArgs) {
        bytesBuilder.add(arg);
      }
      match(HTLexicon.angleRight);
    } else {
      bytesBuilder.addByte(0); // bool: has type args
    }
    return bytesBuilder.toBytes();
  }

  Uint8List _localList(List<Uint8List> exprList) {
    final bytesBuilder = BytesBuilder();
    if (config.lineInfo) {
      bytesBuilder.add(_debugInfo());
    }
    bytesBuilder.addByte(HTOpCode.local);
    bytesBuilder.addByte(HTValueTypeCode.list);
    bytesBuilder.add(_uint16(exprList.length));
    for (final expr in exprList) {
      bytesBuilder.add(expr);
    }
    return bytesBuilder.toBytes();
  }

  Uint8List _localMap(Map<Uint8List, Uint8List> exprMap) {
    final bytesBuilder = BytesBuilder();
    if (config.lineInfo) {
      bytesBuilder.add(_debugInfo());
    }
    bytesBuilder.addByte(HTOpCode.local);
    bytesBuilder.addByte(HTValueTypeCode.map);
    bytesBuilder.add(_uint16(exprMap.length));
    for (final key in exprMap.keys) {
      bytesBuilder.add(key);
      bytesBuilder.add(exprMap[key]!);
    }
    return bytesBuilder.toBytes();
  }

  Uint8List _localGroup() {
    final bytesBuilder = BytesBuilder();
    bytesBuilder.addByte(HTOpCode.local);
    bytesBuilder.addByte(HTValueTypeCode.group);
    match(HTLexicon.roundLeft);
    var innerExpr = _parseExpr(endOfExec: true);
    match(HTLexicon.roundRight);
    bytesBuilder.add(innerExpr);
    return bytesBuilder.toBytes();
  }

  /// 使用递归向下的方法生成表达式，不断调用更底层的，优先级更高的子Parser
  ///
  /// 优先级最低的表达式，赋值表达式
  ///
  /// 赋值 = ，优先级 1，右合并
  ///
  /// 需要判断嵌套赋值、取属性、取下标的叠加
  ///
  /// [endOfExec]: 是否在解析完表达式后中断执行，这样可以返回当前表达式的值
  Uint8List _parseExpr({bool endOfExec = false}) {
    final bytesBuilder = BytesBuilder();
    final left = _parserTernaryExpr();
    if (HTLexicon.assignments.contains(curTok.type)) {
      if (!_leftValueLegality) {
        throw HTError.invalidLeftValue();
      }
      final op = advance(1).type;
      final right = _parseExpr(); // 右合并：先计算右边
      bytesBuilder.add(right);
      bytesBuilder.addByte(HTOpCode.register);
      bytesBuilder.addByte(HTRegIdx.assign);
      bytesBuilder.add(left);
      switch (op) {
        case HTLexicon.assign:
          bytesBuilder.addByte(HTOpCode.assign);
          break;
        case HTLexicon.assignMultiply:
          bytesBuilder.addByte(HTOpCode.assignMultiply);
          break;
        case HTLexicon.assignDevide:
          bytesBuilder.addByte(HTOpCode.assignDevide);
          break;
        case HTLexicon.assignAdd:
          bytesBuilder.addByte(HTOpCode.assignAdd);
          break;
        case HTLexicon.assignSubtract:
          bytesBuilder.addByte(HTOpCode.assignSubtract);
          break;
      }
    } else {
      bytesBuilder.add(left);
    }
    if (endOfExec) {
      bytesBuilder.addByte(HTOpCode.endOfExec);
    }

    return bytesBuilder.toBytes();
  }

  /// Ternary expression parser:
  ///
  /// ```
  /// e1 ? e2 : e3
  /// ```
  ///
  /// 优先级 3，右合并
  Uint8List _parserTernaryExpr() {
    final bytesBuilder = BytesBuilder();
    final condition = _parseLogicalOrExpr();
    bytesBuilder.add(condition);
    if (expect([HTLexicon.condition], consume: true)) {
      _leftValueLegality = false;
      bytesBuilder.addByte(HTOpCode.ifStmt);
      // right combination: recursively use this same function on next expr
      final thenBranch = _parserTernaryExpr();
      match(HTLexicon.colon);
      final elseBranch = _parserTernaryExpr();
      final thenBranchLength = thenBranch.length + 3;
      final elseBranchLength = elseBranch.length;
      bytesBuilder.add(_uint16(thenBranchLength));
      bytesBuilder.add(thenBranch);
      bytesBuilder.addByte(HTOpCode.skip); // 执行完 then 之后，直接跳过 else block
      bytesBuilder.add(_int16(elseBranchLength));
      bytesBuilder.add(elseBranch);
    }
    return bytesBuilder.toBytes();
  }

  /// 逻辑或 or ，优先级 5，左合并
  Uint8List _parseLogicalOrExpr() {
    final bytesBuilder = BytesBuilder();
    final left = _parseLogicalAndExpr();
    bytesBuilder.add(left); // 左合并：先计算左边
    if (curTok.type == HTLexicon.logicalOr) {
      _leftValueLegality = false;
      while (curTok.type == HTLexicon.logicalOr) {
        bytesBuilder.addByte(HTOpCode.register);
        bytesBuilder.addByte(HTRegIdx.orLeft);
        advance(1); // and operator
        bytesBuilder.addByte(HTOpCode.logicalOr);
        final right = _parseLogicalAndExpr();
        bytesBuilder.add(_uint16(right.length + 1)); // length of right value
        bytesBuilder.add(right);
        bytesBuilder.addByte(HTOpCode.endOfExec);
      }
    }
    return bytesBuilder.toBytes();
  }

  /// 逻辑和 and ，优先级 6，左合并
  Uint8List _parseLogicalAndExpr() {
    final bytesBuilder = BytesBuilder();
    final left = _parseEqualityExpr();
    bytesBuilder.add(left); // 左合并：先计算左边
    if (curTok.type == HTLexicon.logicalAnd) {
      _leftValueLegality = false;
      while (curTok.type == HTLexicon.logicalAnd) {
        bytesBuilder.addByte(HTOpCode.register);
        bytesBuilder.addByte(HTRegIdx.andLeft);
        advance(1); // and operator
        bytesBuilder.addByte(HTOpCode.logicalAnd);
        final right = _parseEqualityExpr();
        bytesBuilder.add(_uint16(right.length + 1)); // length of right value
        bytesBuilder.add(right);
        bytesBuilder.addByte(HTOpCode.endOfExec);
      }
    }
    return bytesBuilder.toBytes();
  }

  /// 逻辑相等 ==, !=，优先级 7，不合并
  Uint8List _parseEqualityExpr() {
    final bytesBuilder = BytesBuilder();
    final left = _parseRelationalExpr();
    bytesBuilder.add(left);
    // 不合并：不循环匹配，只 if 判断一次
    if (HTLexicon.equalitys.contains(curTok.type)) {
      _leftValueLegality = false;
      bytesBuilder.addByte(HTOpCode.register);
      bytesBuilder.addByte(HTRegIdx.equalLeft);
      final op = advance(1).type;
      final right = _parseRelationalExpr();
      bytesBuilder.add(right);
      switch (op) {
        case HTLexicon.equal:
          bytesBuilder.addByte(HTOpCode.equal);
          break;
        case HTLexicon.notEqual:
          bytesBuilder.addByte(HTOpCode.notEqual);
          break;
      }
    }
    return bytesBuilder.toBytes();
  }

  /// 逻辑比较 <, >, <=, >=，as, is, is! 优先级 8，不合并
  Uint8List _parseRelationalExpr() {
    final bytesBuilder = BytesBuilder();
    final left = _parseAdditiveExpr();
    bytesBuilder.add(left);
    if (HTLexicon.relationals.contains(curTok.type)) {
      _leftValueLegality = false;
      bytesBuilder.addByte(HTOpCode.register);
      bytesBuilder.addByte(HTRegIdx.relationLeft);
      final op = advance(1).type;
      switch (op) {
        case HTLexicon.lesser:
          final right = _parseAdditiveExpr();
          bytesBuilder.add(right);
          bytesBuilder.addByte(HTOpCode.lesser);
          break;
        case HTLexicon.greater:
          final right = _parseAdditiveExpr();
          bytesBuilder.add(right);
          bytesBuilder.addByte(HTOpCode.greater);
          break;
        case HTLexicon.lesserOrEqual:
          final right = _parseAdditiveExpr();
          bytesBuilder.add(right);
          bytesBuilder.addByte(HTOpCode.lesserOrEqual);
          break;
        case HTLexicon.greaterOrEqual:
          final right = _parseAdditiveExpr();
          bytesBuilder.add(right);
          bytesBuilder.addByte(HTOpCode.greaterOrEqual);
          break;
        case HTLexicon.AS:
          final right = _parseTypeExpr(localValue: true);
          bytesBuilder.add(right);
          bytesBuilder.addByte(HTOpCode.typeAs);
          break;
        case HTLexicon.IS:
          final right = _parseTypeExpr(localValue: true);
          bytesBuilder.add(right);
          final isNot = (peek(1).type == HTLexicon.logicalNot) ? true : false;
          bytesBuilder.addByte(isNot ? HTOpCode.typeIsNot : HTOpCode.typeIs);
          break;
      }
    }
    return bytesBuilder.toBytes();
  }

  /// 加法 +, -，优先级 13，左合并
  Uint8List _parseAdditiveExpr() {
    final bytesBuilder = BytesBuilder();
    final left = _parseMultiplicativeExpr();
    bytesBuilder.add(left);
    if (HTLexicon.additives.contains(curTok.type)) {
      _leftValueLegality = false;
      while (HTLexicon.additives.contains(curTok.type)) {
        bytesBuilder.addByte(HTOpCode.register);
        bytesBuilder.addByte(HTRegIdx.addLeft);
        final op = advance(1).type;
        final right = _parseMultiplicativeExpr();
        bytesBuilder.add(right);
        switch (op) {
          case HTLexicon.add:
            bytesBuilder.addByte(HTOpCode.add);
            break;
          case HTLexicon.subtract:
            bytesBuilder.addByte(HTOpCode.subtract);
            break;
        }
      }
    }
    return bytesBuilder.toBytes();
  }

  /// 乘法 *, /, %，优先级 14，左合并
  Uint8List _parseMultiplicativeExpr() {
    final bytesBuilder = BytesBuilder();
    final left = _parseUnaryPrefixExpr();
    bytesBuilder.add(left);
    if (HTLexicon.multiplicatives.contains(curTok.type)) {
      _leftValueLegality = false;
      while (HTLexicon.multiplicatives.contains(curTok.type)) {
        bytesBuilder.addByte(HTOpCode.register);
        bytesBuilder.addByte(HTRegIdx.multiplyLeft);
        final op = advance(1).type;
        final right = _parseUnaryPrefixExpr();
        bytesBuilder.add(right);
        switch (op) {
          case HTLexicon.multiply:
            bytesBuilder.addByte(HTOpCode.multiply);
            break;
          case HTLexicon.devide:
            bytesBuilder.addByte(HTOpCode.devide);
            break;
          case HTLexicon.modulo:
            bytesBuilder.addByte(HTOpCode.modulo);
            break;
        }
      }
    }
    return bytesBuilder.toBytes();
  }

  /// 前缀 -e, !e，++e, --e, 优先级 15，不合并
  Uint8List _parseUnaryPrefixExpr() {
    final bytesBuilder = BytesBuilder();
    // 因为是前缀所以要先判断操作符
    if (HTLexicon.unaryPrefixs.contains(curTok.type)) {
      _leftValueLegality = false;
      var op = advance(1).type;
      final value = _parseUnaryPostfixExpr();
      bytesBuilder.add(value);
      switch (op) {
        case HTLexicon.negative:
          bytesBuilder.addByte(HTOpCode.negative);
          break;
        case HTLexicon.logicalNot:
          bytesBuilder.addByte(HTOpCode.logicalNot);
          break;
        case HTLexicon.preIncrement:
          bytesBuilder.addByte(HTOpCode.preIncrement);
          break;
        case HTLexicon.preDecrement:
          bytesBuilder.addByte(HTOpCode.preDecrement);
          break;
      }
    } else {
      final value = _parseUnaryPostfixExpr();
      bytesBuilder.add(value);
    }
    return bytesBuilder.toBytes();
  }

  /// 后缀 e., e[], e(), e++, e-- 优先级 16，左合并
  Uint8List _parseUnaryPostfixExpr() {
    final bytesBuilder = BytesBuilder();
    final object = _parseLocalExpr();
    bytesBuilder.add(object); // object will stay in reg[14]
    while (HTLexicon.unaryPostfixs.contains(curTok.type)) {
      bytesBuilder.addByte(HTOpCode.register);
      bytesBuilder.addByte(HTRegIdx.postfixObject);
      final op = advance(1).type;
      switch (op) {
        case HTLexicon.memberGet:
          bytesBuilder
              .addByte(HTOpCode.objectSymbol); // save object symbol name in reg
          final key = _localSymbol(isGetKey: true); // shortUtf8String
          _leftValueLegality = true;
          bytesBuilder.add(key);
          bytesBuilder.addByte(HTOpCode.register);
          bytesBuilder.addByte(HTRegIdx.postfixKey);
          bytesBuilder.addByte(HTOpCode.memberGet);
          break;
        case HTLexicon.subGet:
          final key = _parseExpr(endOfExec: true);
          match(HTLexicon.squareRight);
          _leftValueLegality = true;
          bytesBuilder.addByte(HTOpCode.subGet);
          // sub get key is after opcode
          // it has to be exec with 'move reg index'
          bytesBuilder.add(key);
          break;
        case HTLexicon.call:
          _leftValueLegality = false;
          bytesBuilder.addByte(HTOpCode.call);
          final callArgs = _parseArguments();
          bytesBuilder.add(callArgs);
          break;
        case HTLexicon.postIncrement:
          _leftValueLegality = false;
          bytesBuilder.addByte(HTOpCode.postIncrement);
          break;
        case HTLexicon.postDecrement:
          _leftValueLegality = false;
          bytesBuilder.addByte(HTOpCode.postDecrement);
          break;
      }
    }
    return bytesBuilder.toBytes();
  }

  /// 优先级最高的表达式
  Uint8List _parseLocalExpr() {
    switch (curTok.type) {
      case HTLexicon.NULL:
        _leftValueLegality = false;
        advance(1);
        return _localNull();
      case HTLexicon.TRUE:
        _leftValueLegality = false;
        advance(1);
        return _localBool(true);
      case HTLexicon.FALSE:
        _leftValueLegality = false;
        advance(1);
        return _localBool(false);
      case HTLexicon.integer:
        _leftValueLegality = false;
        final value = curTok.literal;
        var index = addInt(value);
        advance(1);
        return _localConst(index, HTValueTypeCode.int64);
      case HTLexicon.float:
        _leftValueLegality = false;
        final value = curTok.literal;
        var index = addConstFloat(value);
        advance(1);
        return _localConst(index, HTValueTypeCode.float64);
      case HTLexicon.string:
        _leftValueLegality = false;
        final value = curTok.literal;
        var index = addConstString(value);
        advance(1);
        return _localConst(index, HTValueTypeCode.utf8String);
      case HTLexicon.identifier:
        _leftValueLegality = true;
        return _localSymbol();
      case HTLexicon.THIS:
        _leftValueLegality = false;
        advance(1);
        return _localSymbol(id: HTLexicon.THIS);
      case HTLexicon.SUPER:
        _leftValueLegality = false;
        advance(1);
        return _localSymbol(id: HTLexicon.SUPER);
      case HTLexicon.roundLeft:
        _leftValueLegality = false;
        return _localGroup();
      case HTLexicon.squareLeft:
        _leftValueLegality = false;
        advance(1);
        final exprList = <Uint8List>[];
        while (curTok.type != HTLexicon.squareRight) {
          exprList.add(_parseExpr(endOfExec: true));
          if (curTok.type != HTLexicon.squareRight) {
            match(HTLexicon.comma);
          }
        }
        match(HTLexicon.squareRight);
        return _localList(exprList);
      case HTLexicon.curlyLeft:
        _leftValueLegality = false;
        advance(1);
        var exprMap = <Uint8List, Uint8List>{};
        while (curTok.type != HTLexicon.curlyRight) {
          var key = _parseExpr(endOfExec: true);
          match(HTLexicon.colon);
          var value = _parseExpr(endOfExec: true);
          exprMap[key] = value;
          if (curTok.type != HTLexicon.curlyRight) {
            match(HTLexicon.comma);
          }
        }
        match(HTLexicon.curlyRight);
        return _localMap(exprMap);
      case HTLexicon.FUNCTION:
        return _parseFuncDeclaration(funcType: FunctionType.literal);
      default:
        throw HTError.unexpected(HTLexicon.expression, curTok.lexeme);
    }
  }

  Uint8List _parseTypeExpr({bool localValue = false, bool isParam = false}) {
    final bytesBuilder = BytesBuilder();
    if (localValue) {
      bytesBuilder.addByte(HTOpCode.local);
      bytesBuilder.addByte(HTValueTypeCode.type);
    }
    // normal type
    if (curTok.type == HTLexicon.identifier ||
        (curTok.type == HTLexicon.FUNCTION &&
            peek(1).type != HTLexicon.roundLeft)) {
      bytesBuilder.addByte(isParam
          ? TypeType.parameter.index
          : TypeType.normal.index); // enum: normal type
      final id = advance(1).lexeme;

      bytesBuilder.add(_shortUtf8String(id));

      final typeArgs = <Uint8List>[];
      if (expect([HTLexicon.angleLeft], consume: true)) {
        if (curTok.type == HTLexicon.angleRight) {
          throw HTError.emptyTypeArgs();
        }
        while ((curTok.type != HTLexicon.angleRight) &&
            (curTok.type != HTLexicon.endOfFile)) {
          typeArgs.add(_parseTypeExpr());
          expect([HTLexicon.comma], consume: true);
        }
        match(HTLexicon.angleRight);
      }

      bytesBuilder.addByte(typeArgs.length); // max 255
      for (final arg in typeArgs) {
        bytesBuilder.add(arg);
      }

      final isNullable = expect([HTLexicon.nullable], consume: true);
      bytesBuilder.addByte(isNullable ? 1 : 0); // bool isNullable

    } else if (curTok.type == HTLexicon.FUNCTION) {
      advance(1);
      bytesBuilder.addByte(TypeType.function.index); // enum: normal type

      // TODO: typeParameters 泛型参数

      final paramTypes = <Uint8List>[];
      match(HTLexicon.roundLeft);

      var minArity = 0;
      var isOptional = false;
      var isNamed = false;
      var isVariadic = false;
      final paramBytesBuilder = BytesBuilder();

      while (curTok.type != HTLexicon.roundRight &&
          curTok.type != HTLexicon.endOfFile) {
        if (!isOptional) {
          isOptional = expect([HTLexicon.squareLeft], consume: true);
          if (!isOptional && !isNamed) {
            isNamed = expect([HTLexicon.curlyLeft], consume: true);
          }
        }

        if (!isNamed) {
          isVariadic = expect([HTLexicon.varargs], consume: true);
        }

        if (!isNamed && !isVariadic && !isOptional) {
          ++minArity;
        }

        final paramType = _parseTypeExpr(isParam: true);
        paramBytesBuilder.add(paramType);
        paramBytesBuilder.addByte(isOptional ? 1 : 0);
        paramBytesBuilder.addByte(isNamed ? 1 : 0);
        paramBytesBuilder.addByte(isVariadic ? 1 : 0);

        paramTypes.add(paramBytesBuilder.toBytes());
        if (curTok.type != HTLexicon.roundRight) {
          match(HTLexicon.comma);
        }

        if (curTok.type != HTLexicon.squareRight &&
            curTok.type != HTLexicon.curlyRight &&
            curTok.type != HTLexicon.roundRight) {
          match(HTLexicon.comma);
        }

        if (isVariadic) {
          break;
        }
      }
      match(HTLexicon.roundRight);

      bytesBuilder.addByte(paramTypes.length); // uint8: length of param types
      for (final paramType in paramTypes) {
        bytesBuilder.add(paramType);
      }

      bytesBuilder.addByte(minArity);

      match(HTLexicon.arrow);

      final returnType = _parseTypeExpr();
      bytesBuilder.add(returnType);
    } else {
      throw HTError.unexpected(SemanticType.typeExpr, curTok.type);
    }

    return bytesBuilder.toBytes();
  }

  Uint8List _parseBlock(
      {CodeType codeType = CodeType.function,
      String? id,
      List<Uint8List> additionalVarDecl = const [],
      List<Uint8List> additionalStatements = const [],
      bool createNamespace = true,
      bool endOfExec = false}) {
    final bytesBuilder = BytesBuilder();
    final savedDeclBlock = _curBlock;
    _curBlock = BytecodeDeclarationBlock();
    match(HTLexicon.curlyLeft);
    if (createNamespace) {
      bytesBuilder.addByte(HTOpCode.block);
      if (id == null) {
        bytesBuilder.add(_shortUtf8String(HTLexicon.anonymousBlock));
      } else {
        bytesBuilder.add(_shortUtf8String(id));
      }
    }
    final declsBytesBuilder = BytesBuilder();
    final blockBytesBuilder = BytesBuilder();
    while (curTok.type != HTLexicon.curlyRight &&
        curTok.type != HTLexicon.endOfFile) {
      blockBytesBuilder.add(_parseStmt(codeType: codeType));
    }
    match(HTLexicon.curlyRight);
    // 添加前置变量表，总是按照：枚举、函数、类、变量这个顺序
    for (final decl in _curBlock.enumDecls.values) {
      declsBytesBuilder.add(decl);
    }
    for (final decl in _curBlock.funcDecls.values) {
      declsBytesBuilder.add(decl);
    }
    for (final decl in _curBlock.classDecls.values) {
      declsBytesBuilder.add(decl);
    }
    for (final decl in additionalVarDecl) {
      declsBytesBuilder.add(decl);
    }
    for (final decl in _curBlock.varDecls.values) {
      declsBytesBuilder.add(decl);
    }
    bytesBuilder.add(declsBytesBuilder.toBytes());
    for (final stmt in additionalStatements) {
      bytesBuilder.add(stmt);
    }
    bytesBuilder.add(blockBytesBuilder.toBytes());
    _curBlock = savedDeclBlock;
    if (createNamespace) {
      bytesBuilder.addByte(HTOpCode.endOfBlock);
    }
    if (endOfExec) {
      bytesBuilder.addByte(HTOpCode.endOfExec);
    }
    return bytesBuilder.toBytes();
  }

  Uint8List _parseArguments({bool hasLength = false}) {
    // 这里不判断左括号，已经跳过了
    final bytesBuilder = BytesBuilder();
    final positionalArgs = <Uint8List>[];
    final namedArgs = <String, Uint8List>{};
    while ((curTok.type != HTLexicon.roundRight) &&
        (curTok.type != HTLexicon.endOfFile)) {
      if (expect([HTLexicon.identifier, HTLexicon.colon], consume: false)) {
        final name = advance(2).lexeme;
        namedArgs[name] = _parseExpr(endOfExec: true);
      } else {
        positionalArgs.add(_parseExpr(endOfExec: true));
      }
      if (curTok.type != HTLexicon.roundRight) {
        match(HTLexicon.comma);
      }
    }
    match(HTLexicon.roundRight);
    bytesBuilder.addByte(positionalArgs.length);
    for (var i = 0; i < positionalArgs.length; ++i) {
      final argExpr = positionalArgs[i];
      if (hasLength) {
        bytesBuilder.add(_uint16(argExpr.length));
      }
      bytesBuilder.add(argExpr);
    }
    bytesBuilder.addByte(namedArgs.length);
    for (final name in namedArgs.keys) {
      final nameExpr = _shortUtf8String(name);
      bytesBuilder.add(nameExpr);
      final argExpr = namedArgs[name]!;
      if (hasLength) {
        bytesBuilder.add(_uint16(argExpr.length));
      }
      bytesBuilder.add(argExpr);
    }
    return bytesBuilder.toBytes();
  }

  Uint8List _parseExprStmt() {
    final bytesBuilder = BytesBuilder();
    bytesBuilder.add(_parseExpr());
    expect([HTLexicon.semicolon], consume: true);
    return bytesBuilder.toBytes();
  }

  Uint8List _parseReturnStmt() {
    advance(1); // keyword

    final bytesBuilder = BytesBuilder();
    if (curTok.type != HTLexicon.curlyRight &&
        curTok.type != HTLexicon.semicolon &&
        curTok.type != HTLexicon.endOfFile) {
      bytesBuilder.add(_parseExpr());
    }
    bytesBuilder.addByte(HTOpCode.endOfFunc);
    expect([HTLexicon.semicolon], consume: true);

    return bytesBuilder.toBytes();
  }

  Uint8List _parseIfStmt() {
    advance(1);
    final bytesBuilder = BytesBuilder();
    match(HTLexicon.roundLeft);
    bytesBuilder.add(_parseExpr()); // bool: condition
    match(HTLexicon.roundRight);
    bytesBuilder.addByte(HTOpCode.ifStmt);
    Uint8List thenBranch;
    if (curTok.type == HTLexicon.curlyLeft) {
      thenBranch = _parseBlock(id: HTLexicon.thenBranch);
    } else {
      thenBranch = _parseStmt(codeType: CodeType.function);
    }
    Uint8List? elseBranch;
    if (expect([HTLexicon.ELSE], consume: true)) {
      if (curTok.type == HTLexicon.curlyLeft) {
        elseBranch = _parseBlock(id: HTLexicon.elseBranch);
      } else {
        elseBranch = _parseStmt(codeType: CodeType.function);
      }
    }
    final thenBranchLength = thenBranch.length + 3;
    final elseBranchLength = elseBranch?.length ?? 0;

    bytesBuilder.add(_uint16(thenBranchLength));
    bytesBuilder.add(thenBranch);
    bytesBuilder.addByte(HTOpCode.skip); // 执行完 then 之后，直接跳过 else block
    bytesBuilder.add(_int16(elseBranchLength));
    if (elseBranch != null) {
      bytesBuilder.add(elseBranch);
    }

    return bytesBuilder.toBytes();
  }

  Uint8List _parseWhileStmt() {
    advance(1);
    final bytesBuilder = BytesBuilder();
    bytesBuilder.addByte(HTOpCode.loopPoint);
    Uint8List? condition;
    if (expect([HTLexicon.roundLeft], consume: true)) {
      condition = _parseExpr();
      match(HTLexicon.roundRight);
    }
    Uint8List loopBody;
    if (curTok.type == HTLexicon.curlyLeft) {
      loopBody = _parseBlock(id: SemanticType.whileStmt);
    } else {
      loopBody = _parseStmt(codeType: CodeType.function);
    }
    final loopLength = (condition?.length ?? 0) + loopBody.length + 5;
    bytesBuilder.add(_uint16(0)); // while loop continue ip
    bytesBuilder.add(_uint16(loopLength)); // while loop break ip
    if (condition != null) {
      bytesBuilder.add(condition);
      bytesBuilder.addByte(HTOpCode.whileStmt);
      bytesBuilder.addByte(1); // bool: has condition
    } else {
      bytesBuilder.addByte(HTOpCode.whileStmt);
      bytesBuilder.addByte(0); // bool: has condition
    }
    bytesBuilder.add(loopBody);
    bytesBuilder.addByte(HTOpCode.skip);
    bytesBuilder.add(_int16(-loopLength));
    return bytesBuilder.toBytes();
  }

  Uint8List _parseDoStmt() {
    advance(1);
    final bytesBuilder = BytesBuilder();
    bytesBuilder.addByte(HTOpCode.loopPoint);
    Uint8List loopBody;
    if (curTok.type == HTLexicon.curlyLeft) {
      loopBody = _parseBlock(id: SemanticType.whileStmt);
    } else {
      loopBody = _parseStmt(codeType: CodeType.function);
    }
    match(HTLexicon.WHILE);
    match(HTLexicon.roundLeft);
    final condition = _parseExpr();
    match(HTLexicon.roundRight);
    final loopLength = loopBody.length + condition.length + 1;
    bytesBuilder.add(_uint16(0)); // while loop continue ip
    bytesBuilder.add(_uint16(loopLength)); // while loop break ip
    bytesBuilder.add(loopBody);
    bytesBuilder.add(condition);
    bytesBuilder.addByte(HTOpCode.doStmt);
    return bytesBuilder.toBytes();
  }

  Uint8List _assembleLocalConstInt(int value, {bool endOfExec = false}) {
    _leftValueLegality = true;
    final bytesBuilder = BytesBuilder();

    final index = addInt(0);
    final constExpr = _localConst(index, HTValueTypeCode.int64);
    bytesBuilder.add(constExpr);
    if (endOfExec) bytesBuilder.addByte(HTOpCode.endOfExec);
    return bytesBuilder.toBytes();
  }

  Uint8List _assembleLocalSymbol(String id,
      {bool isGetKey = false, bool endOfExec = false}) {
    _leftValueLegality = true;
    final bytesBuilder = BytesBuilder();
    bytesBuilder.addByte(HTOpCode.local);
    bytesBuilder.addByte(HTValueTypeCode.symbol);
    bytesBuilder.add(_shortUtf8String(id));
    bytesBuilder.addByte(isGetKey ? 1 : 0); // bool: isGetKey
    bytesBuilder.addByte(0); // bool: has type args
    if (endOfExec) bytesBuilder.addByte(HTOpCode.endOfExec);
    return bytesBuilder.toBytes();
  }

  Uint8List _assembleMemberGet(Uint8List object, String key,
      {bool endOfExec = false}) {
    _leftValueLegality = true;
    final bytesBuilder = BytesBuilder();
    bytesBuilder.add(object);
    bytesBuilder.addByte(HTOpCode.register);
    bytesBuilder.addByte(HTRegIdx.postfixObject);
    bytesBuilder
        .addByte(HTOpCode.objectSymbol); // save object symbol name in reg
    final keySymbol = _assembleLocalSymbol(key, isGetKey: true);
    bytesBuilder.add(keySymbol);
    bytesBuilder.addByte(HTOpCode.register);
    bytesBuilder.addByte(HTRegIdx.postfixKey);
    bytesBuilder.addByte(HTOpCode.memberGet);
    if (endOfExec) bytesBuilder.addByte(HTOpCode.endOfExec);
    return bytesBuilder.toBytes();
  }

  Uint8List _assembleVarDeclStmt(String id,
      {Uint8List? initializer, bool lateInitialize = true}) {
    final bytesBuilder = BytesBuilder();
    bytesBuilder.addByte(HTOpCode.varDecl);
    bytesBuilder.add(_shortUtf8String(id));
    bytesBuilder.addByte(0); // bool: hasClassId
    bytesBuilder.addByte(initializer != null ? 1 : 0); // bool: isDynamic
    bytesBuilder.addByte(0); // bool: isExternal
    bytesBuilder.addByte(0); // bool: isImmutable
    bytesBuilder.addByte(0); // bool: isStatic
    bytesBuilder.addByte(lateInitialize ? 1 : 0); // bool: lateInitialize
    bytesBuilder.addByte(0); // bool: hasType

    if (initializer != null) {
      bytesBuilder.addByte(1); // bool: has initializer
      if (lateInitialize) {
        bytesBuilder.add(_uint16(curTok.line));
        bytesBuilder.add(_uint16(curTok.column));
        bytesBuilder.add(_uint16(initializer.length));
      }
      bytesBuilder.add(initializer);
    } else {
      bytesBuilder.addByte(0);
    }

    return bytesBuilder.toBytes();
  }

  // for 其实是拼装成的 while 语句
  Uint8List _parseForStmt() {
    advance(1);
    final bytesBuilder = BytesBuilder();
    bytesBuilder.addByte(HTOpCode.block);
    bytesBuilder.add(_shortUtf8String(SemanticType.forStmtInit));
    match(HTLexicon.roundLeft);
    final forStmtType = peek(2).lexeme;
    Uint8List? condition;
    Uint8List? assign;
    final shadowDecls = <Uint8List>[];
    Uint8List? increment;
    if (forStmtType == HTLexicon.IN) {
      if (!HTLexicon.varDeclKeywords.contains(curTok.type)) {
        throw HTError.unexpected(SemanticType.varDeclStmt, curTok.type);
      }
      final declPos = tokPos;
      // jump over keywrod
      advance(1);
      // get id of var decl and jump over in/of
      final id = advance(2).lexeme;
      final object = _parseExpr();
      // the intializer of the var is a member get expression: object.length
      final iterInit =
          _assembleMemberGet(object, HTLexicon.first, endOfExec: true);
      match(HTLexicon.roundRight);
      final blockStartPos = tokPos;
      // go back to var declaration
      tokPos = declPos;
      final iterDecl = _parseVarDeclStmt(
          typeInferrence: curTok.type != HTLexicon.VAR,
          isImmutable: curTok.type == HTLexicon.CONST,
          initializer: iterInit,
          addToBlock: false);

      final increId = HTLexicon.increment;
      final increInit = _assembleLocalConstInt(0, endOfExec: true);
      final increDecl = _assembleVarDeclStmt(increId, initializer: increInit);

      // 添加变量声明
      bytesBuilder.add(iterDecl);
      bytesBuilder.add(increDecl);

      final conditionBytesBuilder = BytesBuilder();
      final isNotEmptyExpr = _assembleMemberGet(object, HTLexicon.isNotEmpty);
      conditionBytesBuilder.add(isNotEmptyExpr);
      conditionBytesBuilder.addByte(HTOpCode.register);
      conditionBytesBuilder.addByte(HTRegIdx.andLeft);
      conditionBytesBuilder.addByte(HTOpCode.logicalAnd);
      final lesserLeftExpr = _assembleLocalSymbol(increId);
      final iterableLengthExpr = _assembleMemberGet(object, HTLexicon.length);
      final logicalAndRightLength =
          lesserLeftExpr.length + iterableLengthExpr.length + 4;
      conditionBytesBuilder.add(_uint16(logicalAndRightLength));
      conditionBytesBuilder.add(lesserLeftExpr);
      conditionBytesBuilder.addByte(HTOpCode.register);
      conditionBytesBuilder.addByte(HTRegIdx.relationLeft);
      conditionBytesBuilder.add(iterableLengthExpr);
      conditionBytesBuilder.addByte(HTOpCode.lesser);
      conditionBytesBuilder.addByte(HTOpCode.endOfExec);
      condition = conditionBytesBuilder.toBytes();

      final assignBytesBuilder = BytesBuilder();
      final getElemFunc = _assembleMemberGet(object, HTLexicon.elementAt);
      assignBytesBuilder.add(getElemFunc);
      assignBytesBuilder.addByte(HTOpCode.register);
      assignBytesBuilder.addByte(HTRegIdx.postfixObject);
      assignBytesBuilder.addByte(HTOpCode.call);
      assignBytesBuilder.addByte(1); // length of positionalArgs
      final getElemFuncCallArg = _assembleLocalSymbol(increId);
      assignBytesBuilder.add(getElemFuncCallArg);
      assignBytesBuilder.addByte(HTOpCode.endOfExec);
      assignBytesBuilder.addByte(0); // length of namedArgs
      assignBytesBuilder.addByte(HTOpCode.register);
      assignBytesBuilder.addByte(HTRegIdx.assign);
      final assignLeftExpr = _assembleLocalSymbol(id);
      assignBytesBuilder.add(assignLeftExpr);
      assignBytesBuilder.addByte(HTOpCode.assign);
      assign = assignBytesBuilder.toBytes();

      final incrementBytesBuilder = BytesBuilder();
      final preIncreExpr = _assembleLocalSymbol(increId);
      incrementBytesBuilder.add(preIncreExpr);
      incrementBytesBuilder.addByte(HTOpCode.preIncrement);
      increment = incrementBytesBuilder.toBytes();

      // go back to block start
      tokPos = blockStartPos;
    }
    // for (var i = 0; i < length; ++i)
    else {
      if (curTok.type != HTLexicon.semicolon) {
        if (!HTLexicon.varDeclKeywords.contains(curTok.type)) {
          throw HTError.unexpected(SemanticType.varDeclStmt, curTok.type);
        }

        final initDeclId = peek(1).lexeme;
        final initDecl = _parseVarDeclStmt(
            declId: initDeclId,
            typeInferrence: curTok.type != HTLexicon.VAR,
            isImmutable: curTok.type == HTLexicon.CONST,
            endOfStatement: true,
            addToBlock: false);

        final increId = HTLexicon.increment;
        final increInit = _assembleLocalSymbol(initDeclId, endOfExec: true);
        final increDecl = _assembleVarDeclStmt(increId, initializer: increInit);

        // 添加声明
        bytesBuilder.add(initDecl);
        bytesBuilder.add(increDecl);

        final shadowInit = _assembleLocalSymbol(increId, endOfExec: true);
        final shadowDecl = _assembleVarDeclStmt(initDeclId,
            initializer: shadowInit, lateInitialize: false);
        shadowDecls.add(shadowDecl);

        final assignBytesBuilder = BytesBuilder();
        final assignRightExpr = _assembleLocalSymbol(initDeclId);
        assignBytesBuilder.add(assignRightExpr);
        assignBytesBuilder.addByte(HTOpCode.register);
        assignBytesBuilder.addByte(HTRegIdx.assign);
        final assignLeftExpr = _assembleLocalSymbol(increId);
        assignBytesBuilder.add(assignLeftExpr);
        assignBytesBuilder.addByte(HTOpCode.assign);
        assign = assignBytesBuilder.toBytes();
      } else {
        advance(1);
      }

      if (curTok.type != HTLexicon.semicolon) {
        condition = _parseExpr();
      }
      match(HTLexicon.semicolon);

      if (curTok.type != HTLexicon.roundRight) {
        increment = _parseExpr();
      }
      match(HTLexicon.roundRight);
    }

    bytesBuilder.addByte(HTOpCode.loopPoint);
    final loop =
        _parseBlock(id: SemanticType.forStmt, additionalVarDecl: shadowDecls);
    final continueLength =
        (condition?.length ?? 0) + (assign?.length ?? 0) + loop.length + 2;
    final breakLength = continueLength + (increment?.length ?? 0) + 3;
    bytesBuilder.add(_uint16(continueLength));
    bytesBuilder.add(_uint16(breakLength));
    if (condition != null) bytesBuilder.add(condition);
    bytesBuilder.addByte(HTOpCode.whileStmt);
    bytesBuilder.addByte((condition != null) ? 1 : 0); // bool: has condition
    if (assign != null) bytesBuilder.add(assign);
    bytesBuilder.add(loop);
    if (increment != null) bytesBuilder.add(increment);
    bytesBuilder.addByte(HTOpCode.skip);
    bytesBuilder.add(_int16(-breakLength));

    bytesBuilder.addByte(HTOpCode.endOfBlock);
    return bytesBuilder.toBytes();
  }

  Uint8List _parseWhenStmt() {
    advance(1);
    final bytesBuilder = BytesBuilder();
    Uint8List? condition;
    if (expect([HTLexicon.roundLeft], consume: true)) {
      condition = _parseExpr();
      match(HTLexicon.roundRight);
    }
    final cases = <Uint8List>[];
    final branches = <Uint8List>[];
    Uint8List? elseBranch;
    match(HTLexicon.curlyLeft);
    while (curTok.type != HTLexicon.curlyRight &&
        curTok.type != HTLexicon.endOfFile) {
      if (curTok.lexeme == HTLexicon.ELSE) {
        advance(1);
        match(HTLexicon.arrow);
        if (curTok.type == HTLexicon.curlyLeft) {
          elseBranch = _parseBlock(id: SemanticType.whenStmt);
        } else {
          elseBranch = _parseStmt(codeType: CodeType.function);
        }
      } else {
        final caseExpr = _parseExpr(endOfExec: true);
        cases.add(caseExpr);
        match(HTLexicon.arrow);
        late final caseBranch;
        if (curTok.type == HTLexicon.curlyLeft) {
          caseBranch = _parseBlock(id: SemanticType.whenStmt);
        } else {
          caseBranch = _parseStmt(codeType: CodeType.function);
        }
        branches.add(caseBranch);
      }
    }

    match(HTLexicon.curlyRight);

    bytesBuilder.addByte(HTOpCode.anchor);
    if (condition != null) {
      bytesBuilder.add(condition);
    }
    bytesBuilder.addByte(HTOpCode.whenStmt);
    bytesBuilder.addByte(condition != null ? 1 : 0);
    bytesBuilder.addByte(cases.length);

    var curIp = 0;
    // the first ip in the branches list
    bytesBuilder.add(_uint16(0));
    for (var i = 1; i < branches.length; ++i) {
      curIp = curIp + branches[i - 1].length + 3;
      bytesBuilder.add(_uint16(curIp));
    }
    curIp = curIp + branches.last.length + 3;
    if (elseBranch != null) {
      bytesBuilder.add(_uint16(curIp)); // else branch ip
    } else {
      bytesBuilder.add(_uint16(0)); // has no else
    }
    final endIp = curIp + (elseBranch?.length ?? 0);
    bytesBuilder.add(_uint16(endIp));

    // calculate the length of the code, for goto the specific location of branches
    var offsetIp = (condition?.length ?? 0) + 3 + branches.length * 2 + 4;

    for (final expr in cases) {
      bytesBuilder.add(expr);
      offsetIp += expr.length;
    }

    for (var i = 0; i < branches.length; ++i) {
      bytesBuilder.add(branches[i]);
      bytesBuilder.addByte(HTOpCode.goto);
      bytesBuilder.add(_uint16(offsetIp + endIp));
    }

    if (elseBranch != null) {
      bytesBuilder.add(elseBranch);
    }

    return bytesBuilder.toBytes();
  }

  /// 变量声明语句
  Uint8List _parseVarDeclStmt(
      {String? declId,
      bool isMember = false,
      bool typeInferrence = false,
      bool isExternal = false,
      bool isImmutable = false,
      bool isStatic = false,
      bool lateInitialize = false,
      Uint8List? initializer,
      bool endOfStatement = false,
      bool addToBlock = true}) {
    advance(1);
    var id = match(HTLexicon.identifier).lexeme;

    if (isMember && isExternal) {
      if (!(_curClass!.isExternal) && !isStatic) {
        throw HTError.externMember();
      }
      id = '${_curClass!.id}.$id';
    }

    if (declId != null) {
      id = declId;
    }

    // if (_curBlock.contains(id)) {
    //   throw HTError.definedParser(id);
    // }

    final bytesBuilder = BytesBuilder();
    bytesBuilder.addByte(HTOpCode.varDecl);
    bytesBuilder.add(_shortUtf8String(id));
    if (isMember) {
      bytesBuilder.addByte(1); // bool: has class id
      bytesBuilder.add(_shortUtf8String(_curClass!.id));
    } else {
      bytesBuilder.addByte(0); // bool: has class id
    }
    bytesBuilder.addByte(typeInferrence ? 1 : 0);
    bytesBuilder.addByte(isExternal ? 1 : 0);
    bytesBuilder.addByte(isImmutable ? 1 : 0);
    bytesBuilder.addByte(isStatic ? 1 : 0);
    bytesBuilder.addByte(lateInitialize ? 1 : 0);

    if (expect([HTLexicon.colon], consume: true)) {
      bytesBuilder.addByte(1); // bool: has type
      bytesBuilder.add(_parseTypeExpr());
    } else {
      bytesBuilder.addByte(0); // bool: has type
    }

    if (expect([HTLexicon.assign], consume: true)) {
      final initializer = _parseExpr(endOfExec: true);
      bytesBuilder.addByte(1); // bool: has initializer
      if (lateInitialize) {
        bytesBuilder.add(_uint16(curTok.line));
        bytesBuilder.add(_uint16(curTok.column));
        bytesBuilder.add(_uint16(initializer.length));
      }
      bytesBuilder.add(initializer);
    } else if (initializer != null) {
      bytesBuilder.addByte(1); // bool: has initializer
      if (lateInitialize) {
        bytesBuilder.add(_uint16(curTok.line));
        bytesBuilder.add(_uint16(curTok.column));
        bytesBuilder.add(_uint16(initializer.length));
      }
      bytesBuilder.add(initializer);
    } else {
      if (isImmutable && !isExternal) {
        throw HTError.constMustInit(id);
      }

      bytesBuilder.addByte(0); // bool: has initializer
    }
    // 语句结尾
    if (endOfStatement) {
      match(HTLexicon.semicolon);
    } else {
      expect([HTLexicon.semicolon], consume: true);
    }

    final bytes = bytesBuilder.toBytes();
    if (addToBlock) {
      _curBlock.varDecls[id] = bytes;
    }
    return bytes;
  }

  Uint8List _parseFuncDeclaration(
      {FunctionType funcType = FunctionType.normal,
      bool isExternal = false,
      bool isStatic = false,
      bool isConst = false}) {
    final savedCurFuncType = _curFuncType;
    _curFuncType = funcType;

    advance(1);

    String? externalTypedef;
    if (!isExternal &&
        (isStatic ||
            funcType == FunctionType.normal ||
            funcType == FunctionType.literal)) {
      if (expect([HTLexicon.squareLeft], consume: true)) {
        if (isExternal) {
          throw HTError.internalFuncWithExternalTypeDef();
        }
        externalTypedef = match(HTLexicon.identifier).lexeme;
        match(HTLexicon.squareRight);
      }
    }

    var declId = '';
    late String id;

    if (funcType != FunctionType.literal) {
      if (funcType == FunctionType.constructor) {
        if (curTok.type == HTLexicon.identifier) {
          declId = advance(1).lexeme;
        }
      } else {
        declId = match(HTLexicon.identifier).lexeme;
      }
    }

    // if (!isExternal) {
    switch (funcType) {
      case FunctionType.constructor:
        id = (declId.isEmpty)
            ? HTLexicon.constructor
            : '${HTLexicon.constructor}$declId';
        // if (_curBlock.contains(id)) {
        //   throw HTError.definedParser(declId);
        // }
        break;
      case FunctionType.getter:
        id = HTLexicon.getter + declId;
        // if (_curBlock.contains(id)) {
        //   throw HTError.definedParser(declId);
        // }
        break;
      case FunctionType.setter:
        id = HTLexicon.setter + declId;
        // if (_curBlock.contains(id)) {
        //   throw HTError.definedParser(declId);
        // }
        break;
      case FunctionType.literal:
        id = HTLexicon.anonymousFunction +
            (Parser.anonymousFuncIndex++).toString();
        break;
      default:
        id = declId;
    }
    // } else {
    //   if (_curClass != null) {
    //     if (!(_curClass!.isExternal) && !isStatic) {
    //       throw HTError.externalMember();
    //     }
    //     if (isStatic || (funcType == FunctionType.constructor)) {
    //       id = (declId.isEmpty) ? _curClass!.id : '${_curClass!.id}.$declId';
    //     } else {
    //       id = declId;
    //     }
    //   } else {
    //     id = declId;
    //   }
    // }

    final bytesBuilder = BytesBuilder();
    if (funcType != FunctionType.literal) {
      bytesBuilder.addByte(HTOpCode.funcDecl);
      // funcBytesBuilder.addByte(HTOpCode.funcDecl);
      bytesBuilder.add(_shortUtf8String(id));
      bytesBuilder.add(_shortUtf8String(declId));

      // if (expect([HTLexicon.angleLeft], consume: true)) {
      //   // 泛型param
      //   super_class_type_args = _parseType();
      //   match(HTLexicon.angleRight);
      // }

      if (externalTypedef != null) {
        bytesBuilder.addByte(1);
        bytesBuilder.add(_shortUtf8String(externalTypedef));
      } else {
        bytesBuilder.addByte(0);
      }

      bytesBuilder.addByte(funcType.index);
      bytesBuilder.addByte(isExternal ? 1 : 0);
      bytesBuilder.addByte(isStatic ? 1 : 0);
      bytesBuilder.addByte(isConst ? 1 : 0);
    } else {
      bytesBuilder.addByte(HTOpCode.local);
      bytesBuilder.addByte(HTValueTypeCode.function);
      bytesBuilder.add(_shortUtf8String(id));

      if (externalTypedef != null) {
        bytesBuilder.addByte(1);
        bytesBuilder.add(_shortUtf8String(externalTypedef));
      } else {
        bytesBuilder.addByte(0);
      }
    }

    var isFuncVariadic = false;
    var minArity = 0;
    var maxArity = 0;
    var paramDecls = <Uint8List>[];

    if (funcType != FunctionType.getter &&
        expect([HTLexicon.roundLeft], consume: true)) {
      bytesBuilder.addByte(1); // bool: has parameter declarations
      var isOptional = false;
      var isNamed = false;
      var isVariadic = false;
      while ((curTok.type != HTLexicon.roundRight) &&
          (curTok.type != HTLexicon.squareRight) &&
          (curTok.type != HTLexicon.curlyRight) &&
          (curTok.type != HTLexicon.endOfFile)) {
        // 可选参数，根据是否有方括号判断，一旦开始了可选参数，则不再增加 minArity
        if (!isOptional) {
          isOptional = expect([HTLexicon.squareLeft], consume: true);
          if (!isOptional && !isNamed) {
            //命名参数，根据是否有花括号判断
            isNamed = expect([HTLexicon.curlyLeft], consume: true);
          }
        }

        if (!isNamed) {
          isVariadic = expect([HTLexicon.varargs], consume: true);
        }

        if (!isNamed && !isVariadic) {
          if (!isOptional) {
            ++minArity;
            ++maxArity;
          } else {
            ++maxArity;
          }
        }

        final paramBytesBuilder = BytesBuilder();
        var paramId = match(HTLexicon.identifier).lexeme;
        paramBytesBuilder.add(_shortUtf8String(paramId));
        paramBytesBuilder.addByte(isOptional ? 1 : 0);
        paramBytesBuilder.addByte(isNamed ? 1 : 0);
        paramBytesBuilder.addByte(isVariadic ? 1 : 0);

        // 参数类型
        if (expect([HTLexicon.colon], consume: true)) {
          paramBytesBuilder.addByte(1); // bool: has type
          paramBytesBuilder.add(_parseTypeExpr());
        } else {
          paramBytesBuilder.addByte(0); // bool: has type
        }

        Uint8List? initializer;
        // 参数默认值
        if ((isOptional || isNamed) &&
            (expect([HTLexicon.assign], consume: true))) {
          initializer = _parseExpr(endOfExec: true);
          paramBytesBuilder.addByte(1); // bool，表示有初始化表达式
          paramBytesBuilder.add(_uint16(initializer.length));
          paramBytesBuilder.add(initializer);
        } else {
          paramBytesBuilder.addByte(0);
        }
        paramDecls.add(paramBytesBuilder.toBytes());

        if (curTok.type != HTLexicon.squareRight &&
            curTok.type != HTLexicon.curlyRight &&
            curTok.type != HTLexicon.roundRight) {
          match(HTLexicon.comma);
        }

        if (isVariadic) {
          isFuncVariadic = true;
          break;
        }
      }

      if (isOptional) {
        match(HTLexicon.squareRight);
      } else if (isNamed) {
        match(HTLexicon.curlyRight);
      }

      match(HTLexicon.roundRight);

      // setter can only have one parameter
      if ((funcType == FunctionType.setter) && (minArity != 1)) {
        throw HTError.setterArity();
      }
    } else {
      bytesBuilder.addByte(0); // bool: has parameter declarations
    }

    bytesBuilder.addByte(isFuncVariadic ? 1 : 0);

    bytesBuilder.addByte(minArity);
    bytesBuilder.addByte(maxArity);
    bytesBuilder.addByte(paramDecls.length); // max 255
    for (var decl in paramDecls) {
      bytesBuilder.add(decl);
    }

    // the return value type declaration
    if (expect([HTLexicon.arrow], consume: true)) {
      if (funcType == FunctionType.constructor) {
        throw HTError.ctorReturn();
      }
      bytesBuilder.addByte(FunctionAppendixType
          .type.index); // enum: return type or super constructor
      bytesBuilder.add(_parseTypeExpr());
    }
    // referring to another constructor
    else if (expect([HTLexicon.colon], consume: true)) {
      if (funcType != FunctionType.constructor) {
        throw HTError.nonCotrWithReferCtor();
      }
      if (isExternal) {
        throw HTError.externalCtorWithReferCtor();
      }

      bytesBuilder.addByte(FunctionAppendixType
          .referConstructor.index); // enum: return type or super constructor
      if (advance(1).lexeme != HTLexicon.SUPER) {
        throw HTError.unexpected(HTLexicon.SUPER, curTok.lexeme);
      }
      final tokLexem = advance(1).type;
      if (tokLexem == HTLexicon.memberGet) {
        bytesBuilder.addByte(1); // bool: has super constructor name
        final superCtorId = match(HTLexicon.identifier).lexeme;
        bytesBuilder.add(_shortUtf8String(superCtorId));
        match(HTLexicon.roundLeft);
      } else if (tokLexem == HTLexicon.roundLeft) {
        bytesBuilder.addByte(0); // bool: has super constructor name
      }
      final callArgs = _parseArguments(hasLength: true);
      bytesBuilder.add(callArgs);
    } else {
      bytesBuilder.addByte(FunctionAppendixType.none.index);
    }

    // 处理函数定义部分的语句块
    if (curTok.type == HTLexicon.curlyLeft) {
      bytesBuilder.addByte(1); // bool: has definition
      bytesBuilder.add(_uint16(curTok.line));
      bytesBuilder.add(_uint16(curTok.column));
      final body = _parseBlock(id: HTLexicon.functionCall);
      bytesBuilder.add(_uint16(body.length + 1)); // definition bytes length
      bytesBuilder.add(body);
      bytesBuilder.addByte(HTOpCode.endOfFunc);
    } else {
      if (funcType != FunctionType.constructor &&
          funcType != FunctionType.literal &&
          !isExternal &&
          !(_curClass?.isAbstract ?? false)) {
        throw HTError.missingFuncBody(id);
      }
      bytesBuilder.addByte(0); // bool: has no definition
      expect([HTLexicon.semicolon], consume: true);
    }

    _curFuncType = savedCurFuncType;

    final bytes = bytesBuilder.toBytes();
    if (funcType != FunctionType.literal) {
      _curBlock.funcDecls[id] = bytes;
    }
    return bytes;
  }

  void _parseClassDeclStmt({bool isExternal = false, bool isAbstract = false}) {
    advance(1); // keyword
    final bytesBuilder = BytesBuilder();
    final id = match(HTLexicon.identifier).lexeme;
    bytesBuilder.addByte(HTOpCode.classDecl);
    bytesBuilder.add(_shortUtf8String(id));

    // if (expect([HTLexicon.angleLeft], consume: true)) {
    //   // 泛型param
    //   super_class_type_args = _parseType();
    //   match(HTLexicon.angleRight);
    // }

    // if (_curBlock.contains(id)) {
    //   throw HTError.definedParser(id);
    // }

    final savedClass = _curClass;

    _curClass = ClassInfo(id, isExternal: isExternal, isAbstract: isAbstract);

    // final savedClassName = _curClassName;
    // _curClassName = id;
    // final savedClassType = _curClassType;
    // _curClassType = classType;

    bytesBuilder.addByte(isExternal ? 1 : 0);
    bytesBuilder.addByte(isAbstract ? 1 : 0);

    Uint8List? superClassType;
    if (expect([HTLexicon.EXTENDS], consume: true)) {
      superClassType = _parseTypeExpr();

      // else if (!_curBlock.classDecls.containsKey(id)) {
      //   throw HTError.notClass(superClassId);
      // }

      bytesBuilder.addByte(1); // bool: has super class
      bytesBuilder.add(superClassType);

      // if (expect([HTLexicon.angleLeft], consume: true)) {
      //   // 泛型arg
      //   super_class_type_args = _parseType();
      //   match(HTLexicon.angleRight);
      // }
    } else {
      bytesBuilder.addByte(0); // bool: has super class
    }

    // TODO: deal with implements and mixins

    if (curTok.type == HTLexicon.curlyLeft) {
      bytesBuilder.addByte(1); // bool: has body
      final classDefinition =
          _parseBlock(id: id, codeType: CodeType.klass, createNamespace: false);

      bytesBuilder.add(classDefinition);
      bytesBuilder.addByte(HTOpCode.endOfExec);
    } else {
      bytesBuilder.addByte(0); // bool: has body
    }

    _curClass = savedClass;

    // _curClassName = savedClassName;
    // _curClassType = savedClassType;
    _curBlock.classDecls[id] = bytesBuilder.toBytes();
  }

  void _parseEnumDeclStmt({bool isExternal = false}) {
    advance(1);
    final bytesBuilder = BytesBuilder();
    final id = match(HTLexicon.identifier).lexeme;
    bytesBuilder.addByte(HTOpCode.enumDecl);
    bytesBuilder.add(_shortUtf8String(id));

    bytesBuilder.addByte(isExternal ? 1 : 0);

    // if (_curBlock.contains(id)) {
    //   throw HTError.definedParser(id);
    // }

    var enumerations = <String>[];
    if (expect([HTLexicon.curlyLeft], consume: true)) {
      while (curTok.type != HTLexicon.curlyRight &&
          curTok.type != HTLexicon.endOfFile) {
        enumerations.add(match(HTLexicon.identifier).lexeme);
        if (curTok.type != HTLexicon.curlyRight) {
          match(HTLexicon.comma);
        }
      }
      match(HTLexicon.curlyRight);
    } else {
      expect([HTLexicon.semicolon], consume: true);
    }

    bytesBuilder.add(_uint16(enumerations.length));
    for (final id in enumerations) {
      bytesBuilder.add(_shortUtf8String(id));
    }

    _curBlock.enumDecls[id] = bytesBuilder.toBytes();
  }
}
