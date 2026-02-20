import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../providers/project_provider.dart';
import '../models/project.dart';
import '../screens/project_screen.dart';

class FileExplorer extends StatelessWidget {
  final Function(ProjectFile)? onFileSelected;

  const FileExplorer({
    super.key,
    this.onFileSelected,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final projectProvider = context.watch<ProjectProvider>();
    
    return Container(
      color: theme.colorScheme.surface,
      child: Column(
        children: [
          // Header
          Container(
            height: 40,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withAlpha(128),
              border: Border(
                bottom: BorderSide(
                  color: theme.colorScheme.outlineVariant,
                ),
              ),
            ),
            child: Row(
              children: [
                Text(
                  'EXPLORER',
                  style: theme.textTheme.labelSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const Spacer(),
                if (projectProvider.hasOpenProject) ...[
                  IconButton(
                    onPressed: () => _showNewFileDialog(context),
                    icon: const Icon(Icons.add, size: 18),
                    tooltip: 'New File',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
                  IconButton(
                    onPressed: () => _showProjectOptions(context),
                    icon: const Icon(Icons.more_vert, size: 18),
                    tooltip: 'More',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
                ],
              ],
            ),
          ),
          
          // Content
          Expanded(
            child: projectProvider.hasOpenProject
                ? _buildFileTree(context, projectProvider)
                : _buildNoProjectState(context),
          ),
        ],
      ),
    );
  }

  Widget _buildNoProjectState(BuildContext context) {
    final theme = Theme.of(context);
    
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_open,
            size: 48,
            color: theme.colorScheme.onSurfaceVariant.withAlpha(128),
          ),
          const SizedBox(height: 16),
          Text(
            'No project open',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => const ProjectScreen(),
                ),
              );
            },
            icon: const Icon(Icons.add),
            label: const Text('Open Project'),
          ),
        ],
      ),
    );
  }

  Widget _buildFileTree(BuildContext context, ProjectProvider provider) {
    final project = provider.currentProject!;
    
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: project.files.length,
      itemBuilder: (context, index) {
        final file = project.files[index];
        final isSelected = provider.currentFile?.id == file.id;
        
        return _FileTreeItem(
          file: file,
          isSelected: isSelected,
          onTap: () {
            provider.openFile(file.id);
            onFileSelected?.call(file);
          },
          onRename: () => _showRenameDialog(context, file),
          onDelete: () => _showDeleteConfirmation(context, file),
        );
      },
    );
  }

  void _showNewFileDialog(BuildContext context) {
    final controller = TextEditingController();
    
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('New File'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'File name',
            hintText: 'example.py',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                context.read<ProjectProvider>().createFile(controller.text);
                Navigator.pop(dialogContext);
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(BuildContext context, ProjectFile file) {
    final controller = TextEditingController(text: file.name);
    final provider = context.read<ProjectProvider>();

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Rename File'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'New name',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              if (controller.text.isNotEmpty) {
                provider.renameFile(file.id, controller.text);
                Navigator.pop(dialogContext);
              }
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  void _showDeleteConfirmation(BuildContext context, ProjectFile file) {
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Delete File'),
        content: Text('Are you sure you want to delete "${file.name}"?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              context.read<ProjectProvider>().deleteFile(file.id);
              Navigator.pop(dialogContext);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  void _showProjectOptions(BuildContext context) {
    showModalBottomSheet(
      context: context,
      builder: (modalContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.folder_open),
              title: const Text('Open Different Project'),
              onTap: () {
                Navigator.pop(modalContext);
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const ProjectScreen(),
                  ),
                );
              },
            ),
            ListTile(
              leading: const Icon(Icons.close),
              title: const Text('Close Project'),
              onTap: () {
                context.read<ProjectProvider>().closeProject();
                Navigator.pop(modalContext);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _FileTreeItem extends StatelessWidget {
  final ProjectFile file;
  final bool isSelected;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _FileTreeItem({
    required this.file,
    required this.isSelected,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return InkWell(
      onTap: onTap,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected 
              ? theme.colorScheme.primaryContainer 
              : Colors.transparent,
        ),
        child: Row(
          children: [
            Icon(
              _getFileIcon(),
              size: 16,
              color: isSelected 
                  ? theme.colorScheme.onPrimaryContainer 
                  : _getFileColor(theme),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                file.name,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: isSelected 
                      ? theme.colorScheme.onPrimaryContainer 
                      : theme.colorScheme.onSurface,
                  fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (file.isModified)
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: isSelected 
                      ? theme.colorScheme.onPrimaryContainer 
                      : theme.colorScheme.primary,
                  shape: BoxShape.circle,
                ),
              ),
          ],
        ),
      ),
    );
  }

  IconData _getFileIcon() {
    if (file.isPythonFile) return Icons.code;
    if (file.name.endsWith('.md')) return Icons.description;
    if (file.name.endsWith('.json')) return Icons.data_object;
    if (file.name.endsWith('.txt')) return Icons.text_snippet;
    if (file.name.endsWith('.yaml') || file.name.endsWith('.yml')) {
      return Icons.settings;
    }
    return Icons.insert_drive_file;
  }

  Color _getFileColor(ThemeData theme) {
    if (file.isPythonFile) return Colors.blue;
    if (file.name.endsWith('.md')) return Colors.green;
    if (file.name.endsWith('.json')) return Colors.orange;
    return theme.colorScheme.onSurfaceVariant;
  }
}
