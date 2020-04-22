// Copyright 2020 The Chromium Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:vm_service/vm_service.dart';

import '../../flutter/common_widgets.dart';
import '../../flutter/theme.dart';
import 'codeview.dart';
import 'common.dart';
import 'debugger_controller.dart';

// TODO(devoncarew): Allow scrolling horizontally as well.

// TODO(devoncarew): Show some small UI indicator when we receive stdout/stderr.

// TODO(devoncarew): Support hyperlinking to stack traces.

// TODO(devoncarew): Support copy all to clipboard.

/// Display the stdout and stderr output from the process under debug.
class Console extends StatefulWidget {
  const Console({
    Key key,
    this.controller,
  }) : super(key: key);

  final DebuggerController controller;

  @override
  _ConsoleState createState() => _ConsoleState();
}

class _ConsoleState extends State<Console> {
  ScrollController scrollController;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();

    scrollController?.dispose();
    scrollController = ScrollController();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final textStyle =
        theme.textTheme.bodyText2.copyWith(fontFamily: 'RobotoMono');

    return OutlinedBorder(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          debuggerSectionTitle(theme, text: 'Console'),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: denseSpacing),
              child: ValueListenableBuilder<List<String>>(
                valueListenable: widget.controller.stdio,
                builder: (context, lines, _) {
                  if (scrollController.hasClients) {
                    // If we're at the end already, scroll to expose the new
                    // content.
                    // TODO(devoncarew): We should generalize the
                    // auto-scroll-to-bottom feature.
                    final pos = scrollController.position;
                    if (pos.pixels == pos.maxScrollExtent) {
                      SchedulerBinding.instance.addPostFrameCallback((_) {
                        _scrollToBottom();
                      });
                    }
                  }

                  return ListView.builder(
                    itemCount: lines.length,
                    itemExtent: CodeView.rowHeight,
                    controller: scrollController,
                    itemBuilder: (context, index) {
                      return Text(
                        lines[index],
                        maxLines: 1,
                        style: textStyle,
                      );
                    },
                  );
                },
              ),
            ),
          ),
          ExpressionArea(controller: widget.controller),
        ],
      ),
    );
  }

  @override
  void dispose() {
    scrollController?.dispose();

    super.dispose();
  }

  void _scrollToBottom() async {
    if (mounted && scrollController.hasClients) {
      await scrollController.animateTo(
        scrollController.position.maxScrollExtent,
        duration: rapidDuration,
        curve: defaultCurve,
      );

      // Scroll again if we've received new content in the interim.
      final pos = scrollController.position;
      if (pos.pixels != pos.maxScrollExtent) {
        scrollController.jumpTo(pos.maxScrollExtent);
      }
    }
  }
}

class ExpressionArea extends StatefulWidget {
  const ExpressionArea({
    Key key,
    this.controller,
  }) : super(key: key);

  final DebuggerController controller;

  @override
  _ExpressionAreaState createState() => _ExpressionAreaState();
}

class _ExpressionAreaState extends State<ExpressionArea> {
  TextEditingController editingController = TextEditingController();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // todo: handle key up, down to navigate previous evaluations

    return Container(
      padding: const EdgeInsets.symmetric(
        vertical: densePadding,
        horizontal: denseSpacing,
      ),
      decoration: BoxDecoration(
        border: Border(top: BorderSide(color: theme.focusColor)),
      ),
      child: Row(
        children: [
          const Text('> '),
          Expanded(
            child: SizedBox(
              height: 20.0,
              child: TextField(
                decoration: const InputDecoration(
                  isDense: true,
                  border: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                controller: editingController,
                //onSubmitted: _handleExpression,
                onEditingComplete: _handleExpression,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _handleExpression() {
    String expr = editingController.text;

    expr = expr.trim();
    if (expr.isEmpty) {
      return;
    }

    widget.controller.printToConsole('$expr: ', writeOnNewLine: true);

    widget.controller.evaluateInFrame(expr).then((Response response) async {
      if (response == null) {
        widget.controller.printToConsole('$response\n');
      } else if (response is ErrorRef) {
        // TODO(devoncarew): Write as stderr.
        widget.controller.printToConsole('${response.message}\n');

        // TODO(devoncarew): Handle the optional stacktrace (from Error).

      } else if (response is InstanceRef) {
        if (response.valueAsString != null) {
          widget.controller.printToConsole('${_valueAsString(response)}\n');
        } else {
          final result = await widget.controller.invoke(
              response.id, 'toString', <String>[],
              disableBreakpoints: true);

          if (result is ErrorRef) {
            // TODO(devoncarew): Write as stderr.
            widget.controller.printToConsole('${result.message}\n');
          } else if (result is InstanceRef) {
            widget.controller.printToConsole('${_valueAsString(result)}\n');
          } else {
            widget.controller.printToConsole('$response\n');
          }
        }
      } else {
        widget.controller.printToConsole('$response\n');
      }
    }).catchError((e) {
      // TODO(devoncarew): Write as stderr.
      widget.controller.printToConsole('$e\n');
    });
  }
}

String _valueAsString(InstanceRef ref) {
  if (ref == null || ref.valueAsString == null) {
    return null;
  }

  if (ref.valueAsStringIsTruncated == true) {
    return '${ref.valueAsString}...';
  } else {
    return ref.valueAsString;
  }
}
