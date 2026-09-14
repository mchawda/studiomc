// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:studiomc_app/services/search_service.dart';

/// One actionable entry in the command palette. Either an "action"
/// (navigate somewhere, run something) or a "result" (open a chat,
/// document, memory, tool, ...).
class PaletteEntry {
  PaletteEntry({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.kind,
    required this.onSelect,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final String kind; // 'chat' | 'document' | 'action' | 'tool' | 'memory'
  final FutureOr<void> Function() onSelect;
}

/// The command palette — Cmd-K / Ctrl-K everywhere in the app.
///
/// Default actions surface the most common navigation targets so the
/// palette is useful even with an empty backend. Typing a query streams
/// hits from the supervisor's `/search` endpoint and merges them with
/// the actions that match the same prefix.
class CommandPalette extends StatefulWidget {
  const CommandPalette({super.key});

  static Future<void> show(BuildContext context) {
    return showGeneralDialog<void>(
      context: context,
      barrierLabel: 'Command palette',
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.45),
      transitionDuration: const Duration(milliseconds: 140),
      pageBuilder: (ctx, anim, secondary) {
        return const Align(
          alignment: Alignment(0, -0.4),
          child: CommandPalette(),
        );
      },
      transitionBuilder: (ctx, anim, secondary, child) {
        final curve = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
        return FadeTransition(
          opacity: curve,
          child: ScaleTransition(
            scale: Tween<double>(begin: 0.97, end: 1.0).animate(curve),
            child: child,
          ),
        );
      },
    );
  }

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  late final SearchService _search = SearchService();
  Timer? _debounce;
  String _query = '';
  List<SearchHit> _hits = const [];
  bool _loading = false;
  String? _error;
  int _highlight = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _focusNode.requestFocus();
    });
    _controller.addListener(_onChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    final value = _controller.text.trim();
    setState(() {
      _query = value;
      _highlight = 0;
    });
    _debounce?.cancel();
    if (value.isEmpty) {
      setState(() {
        _hits = const [];
        _loading = false;
        _error = null;
      });
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 180), _runSearch);
  }

  Future<void> _runSearch() async {
    if (_query.isEmpty) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final hits = await _search.search(_query, limit: 12);
      if (!mounted) return;
      setState(() {
        _hits = hits;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _hits = const [];
        _loading = false;
        _error = '$e';
      });
    }
  }

  List<PaletteEntry> _allEntries(BuildContext context) {
    final actions = _defaultActions(context);
    final filteredActions = _query.isEmpty
        ? actions
        : actions
            .where((a) =>
                a.title.toLowerCase().contains(_query.toLowerCase()) ||
                a.subtitle.toLowerCase().contains(_query.toLowerCase()))
            .toList(growable: false);
    final hitEntries = _hits.map((h) => _entryFromHit(context, h)).toList(growable: false);
    return [...filteredActions, ...hitEntries];
  }

  List<PaletteEntry> _defaultActions(BuildContext context) {
    return [
      PaletteEntry(
        title: 'New chat',
        subtitle: 'Start a fresh conversation',
        icon: Icons.add_comment_outlined,
        kind: 'action',
        onSelect: () => context.go('/chat'),
      ),
      PaletteEntry(
        title: 'Models',
        subtitle: 'Browse and download models',
        icon: Icons.psychology_outlined,
        kind: 'action',
        onSelect: () => context.go('/models'),
      ),
      PaletteEntry(
        title: 'Documents',
        subtitle: 'Your indexed files and collections',
        icon: Icons.folder_outlined,
        kind: 'action',
        onSelect: () => context.go('/documents'),
      ),
      PaletteEntry(
        title: 'Training',
        subtitle: 'Personalize a model on your data',
        icon: Icons.fitness_center_outlined,
        kind: 'action',
        onSelect: () => context.go('/training'),
      ),
      PaletteEntry(
        title: 'Memory',
        subtitle: 'What Studiomc remembers about you',
        icon: Icons.psychology_alt_outlined,
        kind: 'action',
        onSelect: () => context.go('/settings/memory'),
      ),
      PaletteEntry(
        title: 'MCP servers',
        subtitle: 'Connect external tool servers',
        icon: Icons.extension_outlined,
        kind: 'action',
        onSelect: () => context.go('/settings/mcp'),
      ),
      PaletteEntry(
        title: 'Settings',
        subtitle: 'Preferences, privacy and diagnostics',
        icon: Icons.settings_outlined,
        kind: 'action',
        onSelect: () => context.go('/settings'),
      ),
    ];
  }

  PaletteEntry _entryFromHit(BuildContext context, SearchHit hit) {
    switch (hit.type) {
      case 'chat':
        return PaletteEntry(
          title: hit.title,
          subtitle: hit.snippet,
          icon: Icons.chat_bubble_outline,
          kind: 'chat',
          onSelect: () => context.go('/chat/${hit.id}'),
        );
      case 'document':
        return PaletteEntry(
          title: hit.title,
          subtitle: hit.snippet,
          icon: Icons.description_outlined,
          kind: 'document',
          onSelect: () => context.go('/documents'),
        );
      default:
        return PaletteEntry(
          title: hit.title,
          subtitle: hit.snippet,
          icon: Icons.search_outlined,
          kind: hit.type,
          onSelect: () {},
        );
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final entries = _allEntries(context);
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      setState(() {
        _highlight = (_highlight + 1).clamp(0, entries.length - 1);
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      setState(() {
        _highlight = (_highlight - 1).clamp(0, entries.length - 1);
      });
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      if (entries.isNotEmpty) {
        _select(entries[_highlight]);
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _select(PaletteEntry entry) async {
    Navigator.of(context).pop();
    await entry.onSelect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = _allEntries(context);

    return Material(
      color: Colors.transparent,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: theme.dividerColor),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 32,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Focus(
            autofocus: true,
            onKeyEvent: _onKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 12, 12),
                  child: Row(
                    children: [
                      Icon(Icons.search, color: theme.hintColor, size: 18),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          focusNode: _focusNode,
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            isCollapsed: true,
                            hintText: 'Search chats, documents, or jump to a screen…',
                            hintStyle: theme.textTheme.bodyMedium?.copyWith(
                              color: theme.hintColor,
                            ),
                          ),
                          style: theme.textTheme.bodyLarge,
                        ),
                      ),
                      if (_loading)
                        const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      const SizedBox(width: 8),
                      _Hint(label: 'esc'),
                    ],
                  ),
                ),
                const Divider(height: 1),
                Flexible(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 420),
                    child: entries.isEmpty
                        ? _emptyState(theme)
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(vertical: 6),
                            itemCount: entries.length,
                            itemBuilder: (ctx, idx) {
                              final entry = entries[idx];
                              final selected = idx == _highlight;
                              return _PaletteRow(
                                entry: entry,
                                selected: selected,
                                onTap: () => _select(entry),
                              );
                            },
                          ),
                  ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(
                    children: [
                      _Hint(label: '↑↓'),
                      const SizedBox(width: 6),
                      Text('navigate', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
                      const SizedBox(width: 14),
                      _Hint(label: '⏎'),
                      const SizedBox(width: 6),
                      Text('open', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
                      const Spacer(),
                      if (_error != null)
                        Text(_error!,
                            style: theme.textTheme.labelSmall?.copyWith(color: Colors.red))
                      else
                        Text(
                          '${entries.length} result${entries.length == 1 ? '' : 's'}',
                          style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _emptyState(ThemeData theme) => Padding(
        padding: const EdgeInsets.all(40),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.search_off, color: theme.hintColor, size: 28),
              const SizedBox(height: 8),
              Text(
                _query.isEmpty
                    ? 'Type a query, or pick an action below.'
                    : 'No results for "$_query"',
                style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor),
              ),
            ],
          ),
        ),
      );
}

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final PaletteEntry entry;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bg = selected
        ? theme.colorScheme.primary.withValues(alpha: 0.10)
        : Colors.transparent;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: bg,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Icon(entry.icon, size: 18, color: theme.colorScheme.onSurface.withValues(alpha: 0.85)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(entry.title, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                  if (entry.subtitle.isNotEmpty)
                    Text(
                      entry.subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                border: Border.all(color: theme.dividerColor),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                entry.kind,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 10,
                  color: theme.hintColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Hint extends StatelessWidget {
  const _Hint({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: theme.dividerColor),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: GoogleFonts.jetBrainsMono(fontSize: 10, color: theme.hintColor),
      ),
    );
  }
}
