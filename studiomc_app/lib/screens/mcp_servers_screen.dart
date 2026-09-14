// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'package:studiomc_app/services/mcp_service.dart';

/// Settings screen — manage Model Context Protocol servers.
///
/// MCP is the open protocol that lets third-party tool servers
/// (filesystem, GitHub, Notion, custom shell scripts, …) plug into
/// Studiomc. Add a server here and its tools become available to the
/// orchestrator and chat surface.
class McpServersScreen extends StatefulWidget {
  const McpServersScreen({super.key});

  @override
  State<McpServersScreen> createState() => _McpServersScreenState();
}

class _McpServersScreenState extends State<McpServersScreen> {
  late final McpService _service;
  Future<List<McpServer>>? _serversFuture;
  Future<List<McpTool>>? _toolsFuture;

  @override
  void initState() {
    super.initState();
    _service = context.read<McpService>();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _serversFuture = _service.listServers();
      _toolsFuture = _service.listTools();
    });
  }

  Future<void> _addServer() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => _AddServerDialog(service: _service),
    );
    if (result == true) _refresh();
  }

  Future<void> _toggleServer(McpServer server) async {
    try {
      if (server.running) {
        await _service.stopServer(server.id);
      } else {
        await _service.startServer(server.id);
      }
      _refresh();
    } catch (e) {
      _showError('Failed to ${server.running ? "stop" : "start"}: $e');
    }
  }

  Future<void> _deleteServer(McpServer server) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove server?'),
        content: Text('Remove "${server.name}"? Cached tools will be cleared.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            style: FilledButton.styleFrom(foregroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await _service.deleteServer(server.id);
      _refresh();
    } catch (e) {
      _showError('Delete failed: $e');
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('MCP Servers', style: GoogleFonts.inter(fontWeight: FontWeight.w600)),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
          ),
          const SizedBox(width: 4),
          FilledButton.icon(
            onPressed: _addServer,
            icon: const Icon(Icons.add),
            label: const Text('Add server'),
          ),
          const SizedBox(width: 16),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          _Header(
            title: 'Connected MCP servers',
            subtitle:
                'Each server adds tools the assistant can use during a conversation. Studiomc spawns stdio servers as subprocesses; HTTP servers are called over the network.',
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<McpServer>>(
            future: _serversFuture,
            builder: (ctx, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const _LoadingCard();
              }
              if (snap.hasError) {
                return _ErrorCard(
                  message: 'Could not reach the MCP service.\n${snap.error}',
                  onRetry: _refresh,
                );
              }
              final servers = snap.data ?? const [];
              if (servers.isEmpty) {
                return _EmptyState(
                  icon: Icons.extension_outlined,
                  title: 'No MCP servers yet',
                  subtitle:
                      'Add a server like @modelcontextprotocol/server-filesystem to give the assistant new abilities.',
                  action: FilledButton.icon(
                    onPressed: _addServer,
                    icon: const Icon(Icons.add),
                    label: const Text('Add your first server'),
                  ),
                );
              }
              return Column(
                children: [
                  for (final s in servers)
                    _ServerCard(
                      server: s,
                      onToggle: () => _toggleServer(s),
                      onDelete: () => _deleteServer(s),
                      onRestart: () async {
                        try {
                          await _service.restartServer(s.id);
                          _refresh();
                        } catch (e) {
                          _showError('Restart failed: $e');
                        }
                      },
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: 24),
          _Header(
            title: 'Available tools',
            subtitle:
                'The unified catalogue exposed to the orchestrator. Tools from disabled or stopped servers are hidden.',
          ),
          const SizedBox(height: 12),
          FutureBuilder<List<McpTool>>(
            future: _toolsFuture,
            builder: (ctx, snap) {
              if (snap.connectionState == ConnectionState.waiting) {
                return const _LoadingCard();
              }
              if (snap.hasError) {
                return _ErrorCard(
                  message: 'Could not load tools.\n${snap.error}',
                  onRetry: _refresh,
                );
              }
              final tools = snap.data ?? const [];
              if (tools.isEmpty) {
                return _EmptyState(
                  icon: Icons.handyman_outlined,
                  title: 'No tools discovered yet',
                  subtitle: 'Start a server to populate the catalogue.',
                );
              }
              return Card(
                clipBehavior: Clip.antiAlias,
                child: Column(
                  children: [
                    for (var i = 0; i < tools.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _ToolTile(tool: tools[i]),
                    ],
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ── Add server dialog ──────────────────────────────────────────────


class _AddServerDialog extends StatefulWidget {
  const _AddServerDialog({required this.service});
  final McpService service;

  @override
  State<_AddServerDialog> createState() => _AddServerDialogState();
}

class _AddServerDialogState extends State<_AddServerDialog> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _description = TextEditingController();
  final _command = TextEditingController();
  final _args = TextEditingController();
  final _url = TextEditingController();
  final _env = TextEditingController();
  String _transport = 'stdio';
  bool _autoStart = true;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    _command.dispose();
    _args.dispose();
    _url.dispose();
    _env.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final args = _args.text
          .split(RegExp(r'\s+'))
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
      final env = <String, String>{};
      for (final line in _env.text.split('\n')) {
        final trimmed = line.trim();
        if (trimmed.isEmpty) continue;
        final idx = trimmed.indexOf('=');
        if (idx <= 0) continue;
        env[trimmed.substring(0, idx).trim()] = trimmed.substring(idx + 1).trim();
      }
      await widget.service.addServer(
        name: _name.text.trim(),
        description: _description.text.trim().isEmpty ? null : _description.text.trim(),
        transport: _transport,
        command: _transport == 'stdio' ? _command.text.trim() : null,
        args: args,
        env: env,
        url: _transport != 'stdio' ? _url.text.trim() : null,
        autoStart: _autoStart,
      );
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
    final isStdio = _transport == 'stdio';
    return AlertDialog(
      title: const Text('Add MCP server'),
      content: SizedBox(
        width: 520,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextFormField(
                  controller: _name,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'Filesystem',
                  ),
                  validator: (v) =>
                      (v == null || v.trim().isEmpty) ? 'required' : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _description,
                  decoration: const InputDecoration(
                    labelText: 'Description (optional)',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _transport,
                  decoration: const InputDecoration(labelText: 'Transport'),
                  items: const [
                    DropdownMenuItem(value: 'stdio', child: Text('stdio (subprocess)')),
                    DropdownMenuItem(value: 'http', child: Text('http')),
                    DropdownMenuItem(value: 'sse', child: Text('sse')),
                  ],
                  onChanged: (v) => setState(() => _transport = v ?? 'stdio'),
                ),
                const SizedBox(height: 12),
                if (isStdio) ...[
                  TextFormField(
                    controller: _command,
                    decoration: const InputDecoration(
                      labelText: 'Command',
                      hintText: 'npx',
                    ),
                    validator: (v) => isStdio && (v == null || v.trim().isEmpty)
                        ? 'required for stdio'
                        : null,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _args,
                    decoration: const InputDecoration(
                      labelText: 'Arguments (space separated)',
                      hintText: '-y @modelcontextprotocol/server-filesystem /tmp',
                    ),
                  ),
                ] else ...[
                  TextFormField(
                    controller: _url,
                    decoration: const InputDecoration(
                      labelText: 'URL',
                      hintText: 'https://example.com/mcp',
                    ),
                    validator: (v) => !isStdio && (v == null || v.trim().isEmpty)
                        ? 'required for http/sse'
                        : null,
                  ),
                ],
                const SizedBox(height: 12),
                TextFormField(
                  controller: _env,
                  decoration: const InputDecoration(
                    labelText: 'Environment (KEY=value per line)',
                  ),
                  minLines: 2,
                  maxLines: 4,
                ),
                const SizedBox(height: 12),
                SwitchListTile.adaptive(
                  contentPadding: EdgeInsets.zero,
                  value: _autoStart,
                  onChanged: (v) => setState(() => _autoStart = v),
                  title: const Text('Auto-start on launch'),
                  subtitle: const Text('Spawn this server when Studiomc boots.'),
                ),
                if (_error != null) ...[
                  const SizedBox(height: 8),
                  Text(_error!, style: const TextStyle(color: Colors.red)),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Add server'),
        ),
      ],
    );
  }
}

// ── Building blocks ────────────────────────────────────────────────


class _Header extends StatelessWidget {
  const _Header({required this.title, required this.subtitle});
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(height: 4),
        Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
      ],
    );
  }
}

class _ServerCard extends StatelessWidget {
  const _ServerCard({
    required this.server,
    required this.onToggle,
    required this.onRestart,
    required this.onDelete,
  });

  final McpServer server;
  final VoidCallback onToggle;
  final VoidCallback onRestart;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = server.running
        ? Colors.green.shade600
        : (server.lastError != null ? Colors.red.shade400 : theme.dividerColor);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    server.name,
                    style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  ),
                ),
                Chip(
                  label: Text(server.transport),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                ),
                const SizedBox(width: 8),
                IconButton(
                  tooltip: server.running ? 'Stop' : 'Start',
                  icon: Icon(server.running ? Icons.stop_circle : Icons.play_circle),
                  onPressed: onToggle,
                ),
                IconButton(
                  tooltip: 'Restart',
                  icon: const Icon(Icons.refresh),
                  onPressed: onRestart,
                ),
                IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: onDelete,
                ),
              ],
            ),
            if (server.description != null && server.description!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(server.description!, style: theme.textTheme.bodySmall),
            ],
            const SizedBox(height: 8),
            if (server.command != null)
              SelectableText(
                '${server.command} ${server.args.join(' ')}',
                style: GoogleFonts.jetBrainsMono(fontSize: 12, color: theme.hintColor),
              ),
            if (server.url != null)
              SelectableText(
                server.url!,
                style: GoogleFonts.jetBrainsMono(fontSize: 12, color: theme.hintColor),
              ),
            if (server.lastError != null && server.lastError!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Last error: ${server.lastError}',
                style: theme.textTheme.bodySmall?.copyWith(color: Colors.red),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ToolTile extends StatelessWidget {
  const _ToolTile({required this.tool});
  final McpTool tool;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      title: Row(
        children: [
          Text(tool.name, style: GoogleFonts.jetBrainsMono(fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Text(
            '· ${tool.serverName}',
            style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
          ),
        ],
      ),
      subtitle: tool.description != null && tool.description!.isNotEmpty
          ? Text(tool.description!)
          : null,
      trailing: IconButton(
        tooltip: 'Copy schema',
        icon: const Icon(Icons.code),
        onPressed: () {
          Clipboard.setData(ClipboardData(text: tool.inputSchema.toString()));
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Input schema copied')),
          );
        },
      ),
    );
  }
}

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();
  @override
  Widget build(BuildContext context) => const Card(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: Center(child: CircularProgressIndicator()),
        ),
      );
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(message),
              const SizedBox(height: 8),
              FilledButton.tonal(onPressed: onRetry, child: const Text('Retry')),
            ],
          ),
        ),
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.action,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          children: [
            Icon(icon, size: 40, color: theme.hintColor),
            const SizedBox(height: 12),
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(subtitle, textAlign: TextAlign.center, style: theme.textTheme.bodySmall),
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
