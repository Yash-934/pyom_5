import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/project_provider.dart';
import '../providers/linux_environment_provider.dart';
import '../providers/editor_provider.dart';
import '../widgets/file_explorer.dart';
import '../widgets/code_editor.dart';
import '../widgets/terminal_panel.dart';
import '../widgets/output_panel.dart';
import 'project_screen.dart';
import 'settings_screen.dart';
import 'package_manager_screen.dart';
import 'model_manager_screen.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  int _selectedIndex = 0;
  bool _showTerminal = false;
  bool _showOutput = false;
  double _terminalHeight = 200;
  double _outputHeight = 150;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 720;
        return isWide
            ? _buildDesktopLayout(context)
            : _buildMobileLayout(context);
      },
    );
  }

  Widget _buildDesktopLayout(BuildContext context) {
    final theme = Theme.of(context);
    final projectProvider = context.watch<ProjectProvider>();

    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            minWidth: 60,
            selectedIndex: _selectedIndex,
            onDestinationSelected: (index) {
              if (index == 5) {
                _showSettings();
              } else {
                setState(() => _selectedIndex = index);
              }
            },
            labelType: NavigationRailLabelType.all,
            destinations: const [
              NavigationRailDestination(icon: Icon(Icons.folder_outlined), selectedIcon: Icon(Icons.folder), label: Text('Explorer')),
              NavigationRailDestination(icon: Icon(Icons.search_outlined), selectedIcon: Icon(Icons.search), label: Text('Search')),
              NavigationRailDestination(icon: Icon(Icons.extension_outlined), selectedIcon: Icon(Icons.extension), label: Text('Packages')),
              NavigationRailDestination(icon: Icon(Icons.psychology_outlined), selectedIcon: Icon(Icons.psychology), label: Text('Models')),
            ],
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 8.0),
                  child: IconButton(
                    icon: const Icon(Icons.settings_outlined),
                    onPressed: _showSettings,
                  ),
                ),
              ),
            ),
          ),
          const VerticalDivider(thickness: 1, width: 1),
          Expanded(
            child: Column(
              children: [
                _buildAppBar(theme, projectProvider, true),
                Expanded(
                  child: Row(
                    children: [
                      if (_selectedIndex == 0)
                        const SizedBox(width: 240, child: FileExplorer()),
                      if (_selectedIndex == 0)
                        const VerticalDivider(thickness: 1, width: 1),
                      Expanded(
                        flex: 3,
                        child: Column(
                          children: [
                            Expanded(
                              child: projectProvider.hasOpenFile
                                  ? const CodeEditor()
                                  : _buildEmptyState(theme, projectProvider),
                            ),
                            if (_showOutput) ...[
                              _buildResizeHandle(isOutput: true),
                              SizedBox(
                                height: _outputHeight,
                                child: OutputPanel(onClose: () => setState(() => _showOutput = false)),
                              ),
                            ],
                            if (_showTerminal) ...[
                              _buildResizeHandle(isOutput: false),
                              SizedBox(
                                height: _terminalHeight,
                                child: TerminalPanel(onClose: () => setState(() => _showTerminal = false)),
                              ),
                            ],
                          ],
                        ),
                      ),
                      if (_selectedIndex == 2)
                        const SizedBox(width: 300, child: PackageManagerScreen()),
                      if (_selectedIndex == 3)
                        const SizedBox(width: 320, child: ModelManagerScreen()),
                    ],
                  ),
                ),
                _buildStatusBar(theme),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMobileLayout(BuildContext context) {
    final theme = Theme.of(context);
    final projectProvider = context.watch<ProjectProvider>();

    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        title: Text(projectProvider.currentProject?.name ?? 'Pyom IDE'),
        actions: [
          IconButton(icon: const Icon(Icons.terminal), onPressed: () => setState(() => _showTerminal = !_showTerminal)),
          IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => _runCurrentFile(context)),
          PopupMenuButton<int>(
            onSelected: (value) {
              if (value == 0) _showSettings();
              if (value == 1) setState(() => _showOutput = !_showOutput);
              if (value == 2) _saveCurrentFileToDownloads(context);
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 0, child: Row(children: [Icon(Icons.settings, size: 16), SizedBox(width: 8), Text('Settings')])),
              const PopupMenuItem(value: 1, child: Row(children: [Icon(Icons.terminal, size: 16), SizedBox(width: 8), Text('Toggle Output')])),
              const PopupMenuItem(value: 2, child: Row(children: [Icon(Icons.download, size: 16), SizedBox(width: 8), Text('Save to Downloads')])),
            ],
          ),
        ],
      ),
      drawer: const Drawer(
        child: Column(
          children: [
            DrawerHeader(child: Text('Pyom IDE', style: TextStyle(fontSize: 24))),
            Expanded(child: FileExplorer()),
          ],
        ),
      ),
      body: Column(
        children: [
          _buildAppBar(theme, projectProvider, false),
          Expanded(
            child: projectProvider.hasOpenFile
                ? const CodeEditor()
                : _buildEmptyState(theme, projectProvider),
          ),
          if (_showOutput) ...[
            _buildResizeHandle(isOutput: true),
            SizedBox(
              height: _outputHeight,
              child: OutputPanel(onClose: () => setState(() => _showOutput = false)),
            ),
          ],
          if (_showTerminal) ...[
            _buildResizeHandle(isOutput: false),
            SizedBox(
              height: _terminalHeight,
              child: TerminalPanel(onClose: () => setState(() => _showTerminal = false)),
            ),
          ],
          _buildStatusBar(theme),
        ],
      ),
    );
  }

  Widget _buildAppBar(ThemeData theme, ProjectProvider projectProvider, bool isDesktop) {
    final openFiles = projectProvider.currentProject?.files.where((f) => f.isOpen).toList() ?? [];
    
    return Container(
      height: 40,
      decoration: BoxDecoration(color: theme.colorScheme.surface, border: Border(bottom: BorderSide(color: theme.colorScheme.outlineVariant))),
      child: Row(
        children: [
          if (isDesktop && projectProvider.hasOpenProject) ...[
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(projectProvider.currentProject!.name, style: theme.textTheme.titleSmall),
            ),
            const VerticalDivider(),
          ],
          Expanded(
            child: openFiles.isEmpty
                ? const SizedBox.shrink()
                : ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: openFiles.length,
                    itemBuilder: (context, index) {
                      final file = openFiles[index];
                      final isActive = file.id == projectProvider.currentFile?.id;
                      return Material(
                        color: isActive ? theme.colorScheme.primaryContainer : Colors.transparent,
                        child: InkWell(
                          onTap: () => projectProvider.openFile(file.id),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                            child: Row(
                              children: [
                                Icon(file.isPythonFile ? Icons.code : Icons.description, size: 16, color: isActive ? theme.colorScheme.onPrimaryContainer : theme.colorScheme.onSurfaceVariant),
                                const SizedBox(width: 8),
                                Text(file.name, style: theme.textTheme.bodySmall?.copyWith(fontWeight: isActive ? FontWeight.bold : FontWeight.normal)),
                                const SizedBox(width: 8),
                                InkWell(
                                  onTap: () => projectProvider.closeFileTab(file.id),
                                  child: const Icon(Icons.close, size: 12),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (isDesktop) ...[
             IconButton(icon: const Icon(Icons.terminal), onPressed: () => setState(() => _showTerminal = !_showTerminal), tooltip: 'Toggle Terminal'),
             IconButton(icon: const Icon(Icons.play_arrow), onPressed: () => _runCurrentFile(context), tooltip: 'Run File'),
          ]
        ],
      ),
    );
  }

  Widget _buildResizeHandle({required bool isOutput}) {
    return GestureDetector(
      onVerticalDragUpdate: (details) {
        setState(() {
          if (isOutput) {
            _outputHeight = (_outputHeight - details.delta.dy).clamp(60.0, 350.0);
          } else {
            _terminalHeight = (_terminalHeight - details.delta.dy).clamp(80.0, 400.0);
          }
        });
      },
      child: MouseRegion(
        cursor: SystemMouseCursors.resizeRow,
        child: Container(
          height: 6,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: 48, height: 3,
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme, ProjectProvider projectProvider) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(projectProvider.hasOpenProject ? Icons.code_off : Icons.folder_open, size: 64, color: theme.colorScheme.onSurfaceVariant.withAlpha(128)),
          const SizedBox(height: 16),
          Text(projectProvider.hasOpenProject ? 'Select a file to edit' : 'No project open', style: theme.textTheme.titleLarge?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          Text(projectProvider.hasOpenProject ? 'Click on a file in the explorer' : 'Create or open a project to start', style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant.withAlpha(178))),
          const SizedBox(height: 24),
          if (!projectProvider.hasOpenProject)
            FilledButton.icon(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const ProjectScreen())),
              icon: const Icon(Icons.add), label: const Text('Create Project'),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusBar(ThemeData theme) {
    final linuxProvider = context.watch<LinuxEnvironmentProvider>();
    final projectProvider = context.watch<ProjectProvider>();
    final pythonVersion = linuxProvider.currentEnvironment?.metadata['python_version'] as String? ?? '3.x';

    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant))),
      child: Row(
        children: [
          Icon(linuxProvider.isReady ? Icons.check_circle : Icons.error, size: 12, color: linuxProvider.isReady ? Colors.green : theme.colorScheme.error),
          const SizedBox(width: 4),
          Text(linuxProvider.isReady ? 'Python $pythonVersion' : 'Environment Error', style: theme.textTheme.bodySmall?.copyWith(fontSize: 11)),
          const SizedBox(width: 16),
          if (projectProvider.hasOpenFile) Text(projectProvider.currentFile!.name, style: theme.textTheme.bodySmall?.copyWith(fontSize: 11)),
          const Spacer(),
          if (linuxProvider.isReady) ...[
            Icon(Icons.memory, size: 12, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text('CPU: ${linuxProvider.stats.cpuUsage.toStringAsFixed(1)}%', style: theme.textTheme.bodySmall?.copyWith(fontSize: 11)),
            const SizedBox(width: 12),
            Icon(Icons.storage, size: 12, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(width: 4),
            Text('MEM: ${linuxProvider.stats.memoryUsage.toStringAsFixed(1)}%', style: theme.textTheme.bodySmall?.copyWith(fontSize: 11)),
          ],
        ],
      ),
    );
  }

  Future<void> _runCurrentFile(BuildContext context) async {
    final projectProvider = context.read<ProjectProvider>();
    final linuxProvider = context.read<LinuxEnvironmentProvider>();
    final editorProvider = context.read<EditorProvider>();

    if (!projectProvider.hasOpenFile) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No file open')));
      return;
    }
    if (!projectProvider.currentFile!.isPythonFile) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Only Python files can be run')));
      return;
    }
    if (!linuxProvider.isReady) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Linux environment not configured. Go to Settings → Install Environment.'),
          action: SnackBarAction(label: 'Setup', onPressed: _showSettings),
        ),
      );
      return;
    }

    await projectProvider.saveFile(projectProvider.currentFile!.content);
    setState(() { _showOutput = true; });

    editorProvider.startExecution();
    final result = await linuxProvider.executePythonCode(projectProvider.currentFile!.content);
    editorProvider.setExecutionResult(
      output: result.output,
      error: result.error,
      executionTime: result.executionTime,
    );
  }

  Future<void> _saveCurrentFileToDownloads(BuildContext context) async {
    final projectProvider = context.read<ProjectProvider>();
    final linuxProvider = context.read<LinuxEnvironmentProvider>();
    if (!projectProvider.hasOpenFile) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No file open')));
      return;
    }
    // Save latest content first
    await projectProvider.saveFile(projectProvider.currentFile!.content);
    try {
      final savedPath = await linuxProvider.saveFileToDownloads(
        projectProvider.currentFile!.path,
        projectProvider.currentFile!.name,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('✅ Saved to $savedPath')),
      );
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Error: $e')));
    }
  }

  void _showSettings() {
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => const SettingsScreen()));
  }
}
