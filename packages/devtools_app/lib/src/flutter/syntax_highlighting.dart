// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'dart:convert';
import 'dart:io';

//Future<String> loadPolyfillScript() {
//  return asset.loadString('assets/scripts/inspector_polyfill_script.dart');
//}

// https://macromates.com/manual/en/language_grammars

void main() {
  final String source = File('assets/syntax/dart.json').readAsStringSync();

  final Grammar dartGrammar = Grammar(source);
  print(dartGrammar);

  final highlighter = Highlighter(dartGrammar, _sampleSource.split('\n'));

  print('');

  final lines = highlighter.getStylesForRange(0);
  for (var line in lines) {
    print(line.styles.join());
  }
}

// todo: test basic parsing

class Grammar {
  Grammar(String syntaxDefinition) {
    _definition = jsonDecode(syntaxDefinition);

    _parsePatternRules();
    _parseRepositoryRules();
  }

  final List<Rule> _patternRules = [];
  final Map<String, Rule> _repositoryRules = {};

  Map _definition;

  /// The name of the grammar.
  String get name => _definition['name'];

  /// The file type extensions that the grammar should be used with.
  List<String> get fileTypes =>
      (_definition['fileTypes'] as List).cast<String>();

  /// A unique name for the grammar.
  String get scopeName => _definition['scopeName'];

  void _parseRepositoryRules() {
    final Map repository = _definition['repository'];
    for (String name in repository.keys) {
      _repositoryRules[name] = Rule.parse(this, repository[name], name: name);
    }

    print('rules:');
    for (var rule in _repositoryRules.values) {
      print('  $rule');
    }
  }

  void _parsePatternRules() {
    final List<dynamic> patterns = _definition['patterns'];
    for (Map info in patterns) {
      _patternRules.add(Rule.parse(this, info));
    }

    print('pattern rules:');
    for (var rule in _patternRules) {
      print('  $rule');
    }
  }

  SimpleRule _getRule(String name) {
    return _repositoryRules[name];
  }

  @override
  String toString() => '$name: $fileTypes';
}

abstract class Rule {
  factory Rule.parse(Grammar grammar, Map info, {String name}) {
    if (info.containsKey('include')) {
      return ReferenceRule(grammar, info);
    }
    return SimpleRule(grammar, info, name: name);
  }
}

class SimpleRule implements Rule {
  SimpleRule(this.grammar, Map info, {String name}) {
    _name = name ?? info['name'];
    info.remove('name');

    contentName = info.remove('contentName');

    _parseRegExes(info);

    if (_has(info, 'patterns')) {
      _parsePatterns(info);
    }

    if (_has(info, 'beginCaptures')) {
      beginCaptures = _parseCapture(info, 'beginCaptures');
    }
    if (_has(info, 'endCaptures')) {
      endCaptures = _parseCapture(info, 'endCaptures');
    }
    if (_has(info, 'captures')) {
      beginCaptures = _parseCapture(info, 'captures');
      endCaptures = beginCaptures;
    }
  }

  final Grammar grammar;

  String _name;
  String contentName;

  RegExp match;
  RegExp begin;
  RegExp end;
  RegExp _while;

  List<Rule> patterns;
  Map<int, String> beginCaptures;
  Map<int, String> endCaptures;

  bool _has(Map info, String property) => info.containsKey(property);

  void _parseRegExes(Map info) {
    match = _regEx(info, 'match');
    begin = _regEx(info, 'begin');
    end = _regEx(info, 'end');
    _while = _regEx(info, 'while');
  }

  void _parsePatterns(Map info) {
    patterns =
        (info['patterns'] as List).map((m) => Rule.parse(grammar, m)).toList();
    info.remove('patterns');
  }

  Map<int, String> _parseCapture(Map info, String kind) {
    final Map m = info.remove(kind);
    final Map<int, String> result = {};
    for (String index in m.keys) {
      result[int.parse(index)] = m[index]['name'];
    }
    return result;
  }

  String get name => _name;

  bool get isMatchRule => match != null;

  bool get isBeginEnd => begin != null;

  RegExp _regEx(Map info, String name) {
    return _has(info, name) ? RegExp(info.remove(name)) : null;
  }

  @override
  String toString() =>
      '$name ${isMatchRule ? 'match' : isBeginEnd ? 'being/end' : ''} '
      '${patterns != null ? 'patterns' : ''}';
}

class ReferenceRule implements Rule {
  ReferenceRule(this.grammar, Map info) {
    ref = (info['include'] as String).substring(1);
  }

  final Grammar grammar;

  String ref;

  SimpleRule get resolve => grammar._getRule(ref);

  @override
  String toString() => '#$ref';
}

class Highlighter {
  Highlighter(this.grammar, this.lines);

  final Grammar grammar;
  final List<String> lines;

  final List<LineStyle> _styles = [];

  List<LineStyle> getStylesForRange(int start, [int end]) {
    end ??= lines.length;

    while (_styles.length < end) {
      _styles.add(_processLine(lines[_styles.length]));
    }

    return _styles.sublist(start, end);
  }

  LineStyle _processLine(String line) {
    final styles = <Style>[];

    // todo: handle multiple matches
    // todo: iterate through the string

    for (var r in grammar._patternRules) {
      if (r is ReferenceRule) {
        r = (r as ReferenceRule).resolve;
      }

      final rule = r as SimpleRule;

      if (rule.isMatchRule) {
        final match = rule.match.firstMatch(line);
        if (match != null) {
          if (match.start != 0) {
            styles.add(Style(line.substring(0, match.start)));
          }
          styles.add(Style(line.substring(match.start, match.end), rule.name));
          if (match.end != line.length) {
            styles.add(Style(line.substring(match.end)));
          }

          break;
        }
      }
    }

    if (styles.isEmpty) {
      styles.add(Style(line));
    }

    return LineStyle(styles);
  }
}

class LineStyle {
  LineStyle(this.styles);

  final List<Style> styles;
}

class Style {
  Style(this.string, [this.attribute]);

  final String string;
  final String attribute;

  @override
  String toString() =>
      attribute == null ? '"$string"' : '"$string"[$attribute]';
}

const _sampleSource = '''
#!/usr/bin/env dart

// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:math' as math;

class Circle {
  @deprecated
  double radius;

  // Regular comment.
  Circle(this.radius);

  double get area => math.pi * math.pow(radius, 2);
}

/// Dartdoc comment.
void main() {
  // Before Dart 2.1, you had to provide a trailing `.0` – `42.0` – when
  // assigning to fields or parameters of type `double`.
  // A value like `42` was not allowed.

  print(Circle(2.0).area); // Before Dart 2.1, the trailing `.0` is required.

  // With Dart 2.1, you can provide whole-number values when assigning to
  // a double without the trailing `.0`.
  print(Circle(2).area); // Legal with Dart 2.1
}
''';
