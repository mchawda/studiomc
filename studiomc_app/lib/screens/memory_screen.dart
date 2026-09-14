// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:studiomc_app/services/memory_service.dart';

/// Settings screen — long-term memory editor.
///
/// Studiomc stores discrete "memories" (preferences, facts, project
/// context) and surfaces relevant ones into every chat's system prompt.
/// This screen lets the user audit, pin, edit, and delete what the
/// assistant remembers — privacy-first by design.
class MemoryScreen extends StatefulWidget {
  const MemoryScreen({super.key});

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  late final MemoryService _service;
  Future<List<MemoryEntry>>? _future;

  @override
  void initState() {
    super.initState();
    _service = context.read<MemoryService>();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _future = _service.list();
    });
  }

  Future<void> _addMemory() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => _AddMemoryDialog(service: _service),
    );
    if (result == true) _refresh();
  }

  Future<void> _editMemory(MemoryEntry mem) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => _AddMemoryDialog(service: _service, existing: mem),
    );
    if (result == true) _refresh();
  }

  Future<void> _deleteMemory(MemoryEntry mem) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget this?'),
        content: Text(
          mem.content,
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    await _service.delete(mem.id);
    _refresh();
  }

  Future<void> _togglePin(MemoryEntry mem) async {
    await _service.update(mem.id, pinned: !mem.pinned);
    _refresh();
  }

  Future<void> _clearAll() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Forget everything?'),
        content: const Text(
          'This permanently removes every memory the assistant has stored. This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Forget all'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    final removed = await _service.clearAll();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Cleared $removed memories')),
      );
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Memory', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          IconButton(
            tooltip: 'Forget everything',
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _clearAll,
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: _addMemory,
            icon: const Icon(Icons.add),
            label: const Text('Add memory'),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: FutureBuilder<List<MemoryEntry>>(
        future: _future,
        builder: (ctx, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snap.hasError) {
            return _ErrorView(message: '${snap.error}', onRetry: _refresh);
          }
          final memories = snap.data ?? const [];
          if (memories.isEmpty) {
            return _EmptyView(onAdd: _addMemory);
          }

          final pinned = memories.where((m) => m.pinned).toList();
          final rest = memories.where((m) => !m.pinned).toList();

          return ListView(
            padding: const EdgeInsets.all(20),
            children: [
              _Header(count: memories.length),
              const SizedBox(height: 20),
              if (pinned.isNotEmpty) ...[
                _SectionHeader(label: 'Pinned', count: pinned.length),
                const SizedBox(height: 8),
                for (final m in pinned)
                  _MemoryCard(
                    memory: m,
                    onTogglePin: () => _togglePin(m),
                    onEdit: () => _editMemory(m),
                    onDelete: () => _deleteMemory(m),
                  ),
                const SizedBox(height: 20),
              ],
              if (rest.isNotEmpty) ...[
                _SectionHeader(label: 'Memories', count: rest.length),
                const SizedBox(height: 8),
                for (final m in rest)
                  _MemoryCard(
                    memory: m,
                    onTogglePin: () => _togglePin(m),
                    onEdit: () => _editMemory(m),
                    onDelete: () => _deleteMemory(m),
                  ),
              ],
            ],
          );
        },
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.psychology_alt_outlined, size: 22),
                const SizedBox(width: 10),
                Text(
                  'What Studiomc remembers about you',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'These memories are stored locally on this device, sent to the model only when relevant, and are fully under your control. $count entries today.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label, required this.count});
  final String label;
  final int count;
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      child: Row(
        children: [
          Text(label.toUpperCase(),
              style: theme.textTheme.labelSmall?.copyWith(letterSpacing: 1.5, color: theme.hintColor)),
          const SizedBox(width: 8),
          Text('· $count', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        ],
      ),
    );
  }
}

class _MemoryCard extends StatelessWidget {
  const _MemoryCard({
    required this.memory,
    required this.onTogglePin,
    required this.onEdit,
    required this.onDelete,
  });

  final MemoryEntry memory;
  final VoidCallback onTogglePin;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            IconButton(
              tooltip: memory.pinned ? 'Unpin' : 'Pin',
              icon: Icon(
                memory.pinned ? Icons.push_pin : Icons.push_pin_outlined,
                color: memory.pinned ? theme.colorScheme.primary : null,
              ),
              onPressed: onTogglePin,
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (memory.key != null && memory.key!.isNotEmpty)
                    Text(
                      memory.key!,
                      style: theme.textTheme.labelSmall?.copyWith(
                        color: theme.hintColor,
                        letterSpacing: 1.2,
                      ),
                    ),
                  Text(memory.content, style: theme.textTheme.bodyMedium),
                  if (memory.tags.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: [
                        for (final t in memory.tags)
                          Chip(
                            label: Text(t),
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 4),
                  Text(
                    'Updated ${memory.updatedAt.split("T").first} · ${memory.scope}'
                    '${memory.confidence < 1.0 ? " · confidence ${(memory.confidence * 100).round()}%" : ""}',
                    style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Edit',
              icon: const Icon(Icons.edit_outlined),
              onPressed: onEdit,
            ),
            IconButton(
              tooltip: 'Forget',
              icon: const Icon(Icons.close),
              onPressed: onDelete,
            ),
          ],
        ),
      ),
    );
  }
}

class _AddMemoryDialog extends StatefulWidget {
  const _AddMemoryDialog({required this.service, this.existing});
  final MemoryService service;
  final MemoryEntry? existing;

  @override
  State<_AddMemoryDialog> createState() => _AddMemoryDialogState();
}

class _AddMemoryDialogState extends State<_AddMemoryDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _content;
  late final TextEditingController _key;
  late final TextEditingController _tags;
  late bool _pinned;
  bool _saving = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _content = TextEditingController(text: widget.existing?.content ?? '');
    _key = TextEditingController(text: widget.existing?.key ?? '');
    _tags = TextEditingController(text: (widget.existing?.tags ?? []).join(', '));
    _pinned = widget.existing?.pinned ?? false;
  }

  @override
  void dispose() {
    _content.dispose();
    _key.dispose();
    _tags.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final tags = _tags.text
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList(growable: false);
      if (widget.existing == null) {
        await widget.service.add(
          content: _content.text,
          key: _key.text.trim().isEmpty ? null : _key.text.trim(),
          tags: tags,
          pinned: _pinned,
        );
      } else {
        await widget.service.update(
          widget.existing!.id,
          content: _content.text,
          key: _key.text.trim().isEmpty ? null : _key.text.trim(),
          tags: tags,
          pinned: _pinned,
        );
      }
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = '$e';
          _saving = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEdit = widget.existing != null;
    return AlertDialog(
      title: Text(isEdit ? 'Edit memory' : 'Add memory'),
      content: SizedBox(
        width: 480,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextFormField(
                controller: _content,
                decoration: const InputDecoration(
                  labelText: 'Memory',
                  hintText: 'Prefers metric units. Builds enterprise software.',
                ),
                minLines: 2,
                maxLines: 5,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _key,
                decoration: const InputDecoration(
                  labelText: 'Label (optional)',
                  hintText: 'preferences',
                ),
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _tags,
                decoration: const InputDecoration(
                  labelText: 'Tags (comma separated)',
                ),
              ),
              const SizedBox(height: 12),
              SwitchListTile.adaptive(
                contentPadding: EdgeInsets.zero,
                value: _pinned,
                onChanged: (v) => setState(() => _pinned = v),
                title: const Text('Pin this memory'),
                subtitle: const Text('Always inject into the prompt regardless of relevance.'),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: const TextStyle(color: Colors.red)),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(isEdit ? 'Save' : 'Add'),
        ),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(40),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline, size: 40),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 16),
              FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}

class _EmptyView extends StatelessWidget {
  const _EmptyView({required this.onAdd});
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.psychology_alt_outlined, size: 56, color: theme.hintColor),
            const SizedBox(height: 16),
            Text('No memories yet', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'As you chat, Studiomc will offer to remember stable facts and preferences. You can also add memories manually here.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onAdd,
              icon: const Icon(Icons.add),
              label: const Text('Add a memory'),
            ),
          ],
        ),
      ),
    );
  }
}
