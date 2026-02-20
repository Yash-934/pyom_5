import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../providers/project_provider.dart';
import '../providers/editor_provider.dart';

class CodeEditor extends StatefulWidget {
  const CodeEditor({super.key});

  @override
  State<CodeEditor> createState() => _CodeEditorState();
}

class _CodeEditorState extends State<CodeEditor> {
  late TextEditingController _controller;
  late FocusNode _focusNode;
  final ScrollController _scrollController = ScrollController();

  String? _lastFileId;
  bool _isSyncing = false;
  Timer? _autoSaveTimer;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController();
    _focusNode = FocusNode();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncFromProvider();
      context.read<ProjectProvider>().addListener(_onProviderChanged);
    });

    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _autoSaveTimer?.cancel();
    try {
      context.read<ProjectProvider>().removeListener(_onProviderChanged);
    } catch (_) {}
    _controller.dispose();
    _focusNode.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onProviderChanged() {
    if (!mounted) return;
    final newFileId = context.read<ProjectProvider>().currentFile?.id;
    if (newFileId != _lastFileId) {
      _syncFromProvider();
    }
  }

  void _syncFromProvider() {
    if (!mounted) return;
    final provider = context.read<ProjectProvider>();
    _lastFileId = provider.currentFile?.id;

    final content = provider.currentFile?.content ?? '';
    if (_controller.text != content) {
      _isSyncing = true;
      _controller.text = content;
      _controller.selection = const TextSelection.collapsed(offset: 0);
      _isSyncing = false;
    }
    context.read<EditorProvider>().clearHistory();
  }

  void _onTextChanged() {
    if (_isSyncing) return;

    final projectProvider = context.read<ProjectProvider>();
    final editorProvider = context.read<EditorProvider>();

    if (projectProvider.hasOpenFile) {
      projectProvider.markFileModified();
      editorProvider.pushState(_controller.text);

      _autoSaveTimer?.cancel();
      _autoSaveTimer = Timer(const Duration(seconds: 2), () {
        if (mounted && projectProvider.hasOpenFile) {
          projectProvider.saveFile(_controller.text, silent: true);
        }
      });
    }
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;

    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;

    if (ctrl && event.logicalKey == LogicalKeyboardKey.keyS) {
      _saveFile();
    } else if (ctrl && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (HardwareKeyboard.instance.isShiftPressed) {
        _redo();
      } else {
        _undo();
      }
    } else if (ctrl && event.logicalKey == LogicalKeyboardKey.keyY) {
      _redo();
    } else if (ctrl && event.logicalKey == LogicalKeyboardKey.keyF) {
      context.read<EditorProvider>().startSearch();
    } else if (event.logicalKey == LogicalKeyboardKey.tab) {
      _insertText('  ');
    } else if (event.logicalKey == LogicalKeyboardKey.enter) {
      _handleAutoIndent();
    }
  }

  void _handleAutoIndent() {
    final text = _controller.text;
    final sel = _controller.selection;
    if (!sel.isValid || !sel.isCollapsed) return;

    try {
      final lineStart = text.lastIndexOf('\n', sel.start - 1) + 1;
      final currentLine = text.substring(lineStart, sel.start);
      final indent = RegExp(r'^\s*').stringMatch(currentLine) ?? '';
      final extra = currentLine.trimRight().endsWith(':') ? '  ' : '';
      _insertText('\n$indent$extra');
    } catch (e) {
      _insertText('\n');
    }
  }

  void _insertText(String text) {
    final selection = _controller.selection;
    final newText = _controller.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    _controller.text = newText;
    _controller.selection = TextSelection.collapsed(
      offset: selection.start + text.length,
    );
  }

  void _undo() {
    final editorProvider = context.read<EditorProvider>();
    final previousState = editorProvider.undo(_controller.text);
    if (previousState != null) {
      final sel = _controller.selection;
      _controller.text = previousState;
      _controller.selection = sel;
    }
  }

  void _redo() {
    final editorProvider = context.read<EditorProvider>();
    final nextState = editorProvider.redo(_controller.text);
if (nextState != null) {
      final sel = _controller.selection;
      _controller.text = nextState;
      _controller.selection = sel;
    }
  }

  void _saveFile() {
    final projectProvider = context.read<ProjectProvider>();
    if (projectProvider.hasOpenFile) {
      projectProvider.saveFile(_controller.text);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('File saved'), duration: Duration(seconds: 1)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final projectProvider = context.watch<ProjectProvider>();
    final editorProvider = context.watch<EditorProvider>();

    if (!projectProvider.hasOpenFile) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.code_off, size: 64, color: theme.disabledColor),
            const SizedBox(height: 16),
            const Text('No file is open.'),
            const Text('Select a file from the explorer to start editing.'),
          ],
        ),
      );
    }

    return Column(
      children: [
        _buildToolbar(context, editorProvider),
        if (editorProvider.isSearching) _buildSearchBar(context, editorProvider),
        Expanded(
          child: Row(
            children: [
              if (editorProvider.showLineNumbers) _buildLineNumbers(context, editorProvider),
              Expanded(
                child: KeyboardListener(
                  focusNode: _focusNode,
                  onKeyEvent: _handleKeyEvent,
                  child: TextField(
                    controller: _controller,
                    scrollController: _scrollController,
                    maxLines: null,
                    expands: true,
                    decoration: const InputDecoration(
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.all(8),
                    ),
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: editorProvider.fontSize,
                      height: 1.5,
                    ),
                    cursorColor: theme.colorScheme.primary,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    smartQuotesType: SmartQuotesType.disabled,
                    smartDashesType: SmartDashesType.disabled,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildToolbar(BuildContext context, EditorProvider editorProvider) {
    // ... Implementation from previous step
    return Container(); 
  }

  Widget _buildSearchBar(BuildContext context, EditorProvider provider) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Row(
        children: [
          Expanded(
            child: TextField(
              autofocus: true,
              decoration: const InputDecoration(hintText: 'Find...', isDense: true, border: OutlineInputBorder(), prefixIcon: Icon(Icons.search, size: 16)),
              onChanged: provider.setSearchQuery,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              decoration: const InputDecoration(hintText: 'Replace...', isDense: true, border: OutlineInputBorder()),
              onChanged: (val) {}, // provider.setReplaceQuery,
            ),
          ),
          IconButton(icon: const Icon(Icons.arrow_upward, size: 16), tooltip: 'Find previous', onPressed: () => _findInText(provider, forward: false)),
          IconButton(icon: const Icon(Icons.arrow_downward, size: 16), tooltip: 'Find next', onPressed: () => _findInText(provider, forward: true)),
          IconButton(icon: const Icon(Icons.find_replace, size: 16), tooltip: 'Replace', onPressed: () {}), //_replaceInText
          IconButton(icon: const Icon(Icons.close, size: 16), onPressed: provider.stopSearch),
        ],
      ),
    );
  }
  
  void _findInText(EditorProvider provider, {required bool forward}) {
    final query = provider.searchQuery;
    if (query.isEmpty) return;
    final text = _controller.text;
    final currentPos = _controller.selection.baseOffset;
    
    final idx = forward 
      ? text.indexOf(query, currentPos + 1)
      : text.lastIndexOf(query, currentPos -1);

    if (idx != -1) {
      _controller.selection = TextSelection(baseOffset: idx, extentOffset: idx + query.length);
    } else {
      // Wrap search
      final wrapIdx = forward ? text.indexOf(query) : text.lastIndexOf(query);
      if(wrapIdx != -1){
        _controller.selection = TextSelection(baseOffset: wrapIdx, extentOffset: wrapIdx + query.length);
      }
    }
  }

  Widget _buildLineNumbers(BuildContext context, EditorProvider editorProvider) {
    // ... Implementation from previous step
    return Container();
  }
}