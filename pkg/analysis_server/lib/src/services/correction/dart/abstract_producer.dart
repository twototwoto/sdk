// Copyright (c) 2019, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math' as math;

import 'package:analysis_server/src/services/correction/util.dart';
import 'package:analysis_server/src/utilities/flutter.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/session.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/diagnostic/diagnostic.dart';
import 'package:analyzer/source/source_range.dart';
import 'package:analyzer/src/dart/analysis/session_helper.dart';
import 'package:analyzer/src/dart/ast/utilities.dart';
import 'package:analyzer/src/generated/resolver.dart';
import 'package:analyzer_plugin/utilities/assist/assist.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_builder_dart.dart';
import 'package:analyzer_plugin/utilities/change_builder/change_workspace.dart';
import 'package:analyzer_plugin/utilities/fixes/fixes.dart';
import 'package:meta/meta.dart';

/// An object that can compute a correction (fix or assist).
abstract class CorrectionProducer extends _AbstractCorrectionProducer {
  /// Return the arguments that should be used when composing the message for an
  /// assist, or `null` if the assist message has no parameters or if this
  /// producer doesn't support assists.
  List<Object> get assistArguments => null;

  /// Return the assist kind that should be used to build an assist, or `null`
  /// if this producer doesn't support assists.
  AssistKind get assistKind => null;

  /// Return the arguments that should be used when composing the message for a
  /// fix, or `null` if the fix message has no parameters or if this producer
  /// doesn't support fixes.
  List<Object> get fixArguments => null;

  /// Return the fix kind that should be used to build a fix, or `null` if this
  /// producer doesn't support fixes.
  FixKind get fixKind => null;

  Future<void> compute(DartChangeBuilder builder);

  /// Return `true` if the [node] might be a type name.
  bool mightBeTypeIdentifier(AstNode node) {
    if (node is SimpleIdentifier) {
      var parent = node.parent;
      if (parent is TypeName) {
        return true;
      }
      return _isNameOfType(node.name);
    }
    return false;
  }

  /// Return `true` if the [name] is capitalized.
  bool _isNameOfType(String name) {
    if (name.isEmpty) {
      return false;
    }
    var firstLetter = name.substring(0, 1);
    if (firstLetter.toUpperCase() != firstLetter) {
      return false;
    }
    return true;
  }
}

class CorrectionProducerContext {
  final int selectionOffset;
  final int selectionLength;
  final int selectionEnd;

  final CompilationUnit unit;
  final CorrectionUtils utils;
  final String file;

  final TypeProvider typeProvider;
  final Flutter flutter;

  final AnalysisSession session;
  final AnalysisSessionHelper sessionHelper;
  final ResolvedUnitResult resolvedResult;
  final ChangeWorkspace workspace;

  final Diagnostic diagnostic;

  AstNode _node;

  CorrectionProducerContext({
    @required this.resolvedResult,
    @required this.workspace,
    this.diagnostic,
    this.selectionOffset = -1,
    this.selectionLength = 0,
  })  : file = resolvedResult.path,
        flutter = Flutter.of(resolvedResult),
        session = resolvedResult.session,
        sessionHelper = AnalysisSessionHelper(resolvedResult.session),
        typeProvider = resolvedResult.typeProvider,
        selectionEnd = (selectionOffset ?? 0) + (selectionLength ?? 0),
        unit = resolvedResult.unit,
        utils = CorrectionUtils(resolvedResult);

  AstNode get node => _node;

  /// Return `true` if the lint with the given [name] is enabled.
  bool isLintEnabled(String name) {
    var analysisOptions = session.analysisContext.analysisOptions;
    return analysisOptions.isLintEnabled(name);
  }

  bool setupCompute() {
    final locator = NodeLocator(selectionOffset, selectionEnd);
    _node = locator.searchWithin(resolvedResult.unit);
    return _node != null;
  }
}

/// An object that can dynamically compute multiple corrections (fixes or
/// assists).
abstract class MultiCorrectionProducer extends _AbstractCorrectionProducer {
  /// Return each of the individual producers generated by this producer.
  Iterable<CorrectionProducer> get producers;
}

/// The behavior shared by [CorrectionProducer] and [MultiCorrectionProducer].
abstract class _AbstractCorrectionProducer {
  /// The context used to produce corrections.
  CorrectionProducerContext _context;

  /// The most deeply nested node that completely covers the highlight region of
  /// the diagnostic, or `null` if there is no diagnostic, such a node does not
  /// exist, or if it hasn't been computed yet. Use [coveredNode] to access this
  /// field.
  AstNode _coveredNode;

  /// Initialize a newly created producer.
  _AbstractCorrectionProducer();

  /// The most deeply nested node that completely covers the highlight region of
  /// the diagnostic, or `null` if there is no diagnostic or if such a node does
  /// not exist.
  AstNode get coveredNode {
    // TODO(brianwilkerson) Consider renaming this to `coveringNode`.
    if (_coveredNode == null) {
      var diagnostic = this.diagnostic;
      if (diagnostic == null) {
        return null;
      }
      var errorOffset = diagnostic.problemMessage.offset;
      var errorLength = diagnostic.problemMessage.length;
      _coveredNode =
          NodeLocator2(errorOffset, math.max(errorOffset + errorLength - 1, 0))
              .searchWithin(unit);
    }
    return _coveredNode;
  }

  /// Return the diagnostic being fixed, or `null` if this producer is being
  /// used to produce an assist.
  Diagnostic get diagnostic => _context.diagnostic;

  /// Returns the EOL to use for this [CompilationUnit].
  String get eol => utils.endOfLine;

  String get file => _context.file;

  Flutter get flutter => _context.flutter;

  /// Return the library element for the library in which a correction is being
  /// produced.
  LibraryElement get libraryElement => resolvedResult.libraryElement;

  AstNode get node => _context.node;

  ResolvedUnitResult get resolvedResult => _context.resolvedResult;

  int get selectionLength => _context.selectionLength;

  int get selectionOffset => _context.selectionOffset;

  AnalysisSessionHelper get sessionHelper => _context.sessionHelper;

  TypeProvider get typeProvider => _context.typeProvider;

  /// Return the type system appropriate to the library in which the correction
  /// was requested.
  TypeSystem get typeSystem => _context.resolvedResult.typeSystem;

  CompilationUnit get unit => _context.unit;

  CorrectionUtils get utils => _context.utils;

  /// Configure this producer based on the [context].
  void configure(CorrectionProducerContext context) {
    _context = context;
  }

  /// Return the function body of the most deeply nested method or function that
  /// encloses the [node], or `null` if the node is not in a method or function.
  FunctionBody getEnclosingFunctionBody() {
    var closure = node.thisOrAncestorOfType<FunctionExpression>();
    if (closure != null) {
      return closure.body;
    }
    var function = node.thisOrAncestorOfType<FunctionDeclaration>();
    if (function != null) {
      return function.functionExpression.body;
    }
    var constructor = node.thisOrAncestorOfType<ConstructorDeclaration>();
    if (constructor != null) {
      return constructor.body;
    }
    var method = node.thisOrAncestorOfType<MethodDeclaration>();
    if (method != null) {
      return method.body;
    }
    return null;
  }

  /// Return the text of the given [range] in the unit.
  String getRangeText(SourceRange range) {
    return utils.getRangeText(range);
  }

  /// Return `true` the lint with the given [name] is enabled.
  bool isLintEnabled(String name) {
    return _context.isLintEnabled(name);
  }

  /// Return `true` if the selection covers an operator of the given
  /// [binaryExpression].
  bool isOperatorSelected(BinaryExpression binaryExpression) {
    AstNode left = binaryExpression.leftOperand;
    AstNode right = binaryExpression.rightOperand;
    // between the nodes
    if (selectionOffset >= left.end &&
        selectionOffset + selectionLength <= right.offset) {
      return true;
    }
    // or exactly select the node (but not with infix expressions)
    if (selectionOffset == left.offset &&
        selectionOffset + selectionLength == right.end) {
      if (left is BinaryExpression || right is BinaryExpression) {
        return false;
      }
      return true;
    }
    // invalid selection (part of node, etc)
    return false;
  }
}
