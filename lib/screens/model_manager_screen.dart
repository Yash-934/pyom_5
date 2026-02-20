import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_animate/flutter_animate.dart';

import '../providers/linux_environment_provider.dart';

class ModelManagerScreen extends StatefulWidget {
  const ModelManagerScreen({super.key});
  @override
  State<ModelManagerScreen> createState() => _ModelManagerScreenState();
}

class _ModelManagerScreenState extends State<ModelManagerScreen> {
  List<LLMModel> _models = [];
  LLMModel? _activeModel;
  bool _isRunning = false;
  final _promptController = TextEditingController();
  String _output = '';
  static const _kKey = 'llm_models_v2';

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  @override
  void dispose() {
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _loadModels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getStringList(_kKey) ?? [];
      setState(() {
        _models = raw.map((s) {
          try {
            final m = jsonDecode(s) as Map<String, dynamic>;
            return LLMModel.fromJson(m);
          } catch (_) { return null; }
        }).whereType<LLMModel>().toList();
      });
    } catch (_) {}
  }

  Future<void> _saveModels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_kKey, _models.map((m) => jsonEncode(m.toJson())).toList());
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          _buildHeader(theme),
          Expanded(child: _models.isEmpty ? _buildEmpty() : _buildList()),
          if (_activeModel != null) _buildInference(theme),
        ],
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      height: 48,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(128),
        border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Row(
        children: [
          Icon(Icons.psychology, color: theme.colorScheme.primary),
          const SizedBox(width: 10),
          Text('LLM Models (${_models.length})',
               style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold)),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.help_outline, size: 20),
            tooltip: 'Where to get models?',
            onPressed: _showHelp,
          ),
          FilledButton.icon(
            onPressed: _importModel,
            icon: const Icon(Icons.upload_file, size: 16),
            label: const Text('Import'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmpty() {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.psychology_outlined, size: 64, color: theme.colorScheme.onSurfaceVariant.withAlpha(100)),
          const SizedBox(height: 16),
          Text('No models imported', style: theme.textTheme.titleMedium),
          const SizedBox(height: 6),
          Text('Import a .gguf file to run local LLMs', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 20),
          FilledButton.icon(onPressed: _importModel, icon: const Icon(Icons.upload_file), label: const Text('Import .gguf Model')),
          const SizedBox(height: 10),
          TextButton(onPressed: _showHelp, child: const Text('Where to get models?')),
        ],
      ),
    );
  }

  Widget _buildList() {
    return ListView.builder(
      padding: const EdgeInsets.all(10),
      itemCount: _models.length,
      itemBuilder: (ctx, i) {
        final model = _models[i];
        return _ModelCard(
          model: model,
          isActive: _activeModel?.id == model.id,
          onRun: () => setState(() { _activeModel = model; _output = ''; }),
          onDelete: () => _delete(model),
        ).animate(delay: (i * 40).ms).fadeIn().slideY(begin: 0.1);
      },
    );
  }

  Widget _buildInference(ThemeData theme) {
    return Container(
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withAlpha(50),
        border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: Row(
              children: [
                Icon(Icons.smart_toy, size: 14, color: theme.colorScheme.primary),
                const SizedBox(width: 6),
                Expanded(child: Text(_activeModel!.name, style: theme.textTheme.labelMedium, overflow: TextOverflow.ellipsis)),
                IconButton(
                  icon: const Icon(Icons.close, size: 16), padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
                  onPressed: () => setState(() { _activeModel = null; _output = ''; }),
                ),
              ],
            ),
          ),
          // Output
          Flexible(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 10),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(color: const Color(0xFF1E1E1E), borderRadius: BorderRadius.circular(6)),
              child: SingleChildScrollView(
                child: SelectableText(
                  _output.isEmpty ? 'Model output will appear here…' : _output,
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.white, height: 1.4),
                ),
              ),
            ),
          ),
          // Input
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _promptController,
                    decoration: InputDecoration(
                      hintText: 'Enter your prompt…',
                      isDense: true,
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                    ),
                    onSubmitted: (_) => _sendPrompt(),
                  ),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _isRunning ? null : _sendPrompt,
                  style: FilledButton.styleFrom(padding: const EdgeInsets.all(12), minimumSize: Size.zero),
                  child: _isRunning
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.send, size: 18),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ─── Import model ──────────────────────────────────────────────────────────
  Future<void> _importModel() async {
    // On Android 13+ we need storage permission for file manager access
    if (Platform.isAndroid) {
      final status = await Permission.manageExternalStorage.request();
      if (status.isDenied) {
        // Try without full storage permission — file picker may still work
        // through the SAF (Storage Access Framework)
      }
    }

    try {
      final result = await FilePicker.platform.pickFiles(
        
      );

      if (result == null || result.files.isEmpty) return;
      final file = result.files.first;

      // Validate file
      final ext = file.name.toLowerCase();
      if (!ext.endsWith('.gguf') && !ext.endsWith('.bin') && !ext.endsWith('.ggml')) {
        if (!mounted) return;
        _showSnack('⚠️ File should be .gguf, .bin, or .ggml format');
      }

      if (file.path == null) {
        if (!mounted) return;
        _showSnack('Could not get file path. Try copying file to internal storage first.');
        return;
      }

      final model = LLMModel(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: file.name,
        path: file.path!,
        size: file.size,
        importedAt: DateTime.now(),
      );

      setState(() => _models.add(model));
      await _saveModels();

      if (!mounted) return;
      _showSnack('✅ ${file.name} imported!');
    } catch (e) {
      if (!mounted) return;
      _showSnack('Error importing file: $e');
    }
  }

  Future<void> _sendPrompt() async {
    if (_promptController.text.isEmpty || _activeModel == null) return;
    setState(() { _isRunning = true; _output = 'Generating response…\n\n'; });

    final result = await context.read<LinuxEnvironmentProvider>().runLlamaModel(
      _activeModel!.path,
      prompt: _promptController.text,
    );

    setState(() {
      _isRunning = false;
      _output = result.isSuccess ? result.output : 'Error: ${result.error}';
    });
    _promptController.clear();
  }

  void _delete(LLMModel model) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Model'),
        content: Text('Remove "${model.name}" from list?\n(The file itself will NOT be deleted)'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () async {
              setState(() {
                _models.removeWhere((m) => m.id == model.id);
                if (_activeModel?.id == model.id) _activeModel = null;
              });
              await _saveModels();
              if (mounted) Navigator.pop(ctx);
            },
            style: FilledButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.error),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
  }

  void _showHelp() {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Getting GGUF Models'),
        content: const SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Download from Hugging Face:', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 8),
              Text('1. Go to huggingface.co on your phone browser\n'
                   '2. Search for "GGUF" models\n'
                   '3. Download to your Downloads folder\n'
                   '4. Come back here and tap Import'),
              SizedBox(height: 12),
              Text('Recommended small models:', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 6),
              Text('• Phi-2 Q4_K_M (~1.6 GB) — fast'),
              Text('• Mistral-7B Q4_K_M (~4.1 GB)'),
              Text('• Llama-2-7B Q4_K_M (~3.8 GB)'),
              Text('• TinyLlama Q4_K_M (~0.7 GB) — best for 4GB RAM'),
              SizedBox(height: 12),
              Text('Import tip:', style: TextStyle(fontWeight: FontWeight.bold)),
              SizedBox(height: 4),
              Text('Tap Import → navigate to your Downloads folder → select the .gguf file.\n\n'
                   'If the file doesn\'t show, make sure "All files" filter is selected in the file manager.'),
            ],
          ),
        ),
        actions: [FilledButton(onPressed: () => Navigator.pop(ctx), child: const Text('Got it'))],
      ),
    );
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}

class LLMModel {
  final String id, name, path;
  final int size;
  final DateTime importedAt;

  LLMModel({required this.id, required this.name, required this.path, required this.size, required this.importedAt});

  factory LLMModel.fromJson(Map<String, dynamic> j) => LLMModel(
    id: j['id'], name: j['name'], path: j['path'],
    size: j['size'] ?? 0, importedAt: DateTime.tryParse(j['importedAt'] ?? '') ?? DateTime.now(),
  );

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'path': path, 'size': size, 'importedAt': importedAt.toIso8601String()};

  String get formattedSize {
    if (size < 1048576) return '${(size / 1024).toStringAsFixed(1)} KB';
    if (size < 1073741824) return '${(size / 1048576).toStringAsFixed(1)} MB';
    return '${(size / 1073741824).toStringAsFixed(2)} GB';
  }
}

class _ModelCard extends StatelessWidget {
  final LLMModel model;
  final bool isActive;
  final VoidCallback onRun, onDelete;

  const _ModelCard({required this.model, required this.isActive, required this.onRun, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: isActive ? theme.colorScheme.primaryContainer : null,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 42, height: 42,
              decoration: BoxDecoration(
                color: isActive ? theme.colorScheme.primary : theme.colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(Icons.psychology, color: isActive ? theme.colorScheme.onPrimary : theme.colorScheme.onPrimaryContainer),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(model.name, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis),
                  Text(model.formattedSize, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
                ],
              ),
            ),
            if (isActive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withAlpha(30),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: theme.colorScheme.primary),
                ),
                child: Text('ACTIVE', style: TextStyle(color: theme.colorScheme.primary, fontSize: 10, fontWeight: FontWeight.bold)),
              )
            else
              Row(
                children: [
                  FilledButton.tonal(
                    onPressed: onRun,
                    style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), minimumSize: Size.zero),
                    child: const Text('Run'),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: onDelete,
                    icon: Icon(Icons.delete_outline, size: 18, color: theme.colorScheme.error),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
