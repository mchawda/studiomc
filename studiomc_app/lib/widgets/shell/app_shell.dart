import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/services/database_service.dart';
import 'package:studiomc_app/widgets/chat/conversation_controls.dart';

/// Perplexity-inspired app shell.
/// Collapsed state = slim icon rail (like Perplexity's left nav).
/// Expanded state = full sidebar with live chat history from backend.
class AppShell extends StatefulWidget {
  final Widget child;

  const AppShell({super.key, required this.child});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  bool _sidebarExpanded = false;

  // ── Chat history state ──
  List<Chat> _chats = [];
  bool _chatsLoading = false;
  bool _chatsLoaded = false;

  // ── Load chats from local SQLite ──

  Future<void> _loadChats() async {
    if (_chatsLoading) return;
    setState(() => _chatsLoading = true);

    try {
      final db = context.read<DatabaseService>();
      final rows = await db.getChats();
      final chats = rows.map((r) {
        return Chat(
          id: r['id'] as String? ?? '',
          title: r['title'] as String? ?? 'Untitled',
          modelId: r['model_id'] as String? ?? '',
          mode: PresetMode.defaultMode,
          createdAt:
              DateTime.tryParse(r['created_at'] as String? ?? '') ??
                  DateTime.now(),
          updatedAt:
              DateTime.tryParse(r['updated_at'] as String? ?? '') ??
                  DateTime.now(),
          isPinned: false,
        );
      }).toList();

      if (mounted) {
        setState(() {
          _chats = chats;
          _chatsLoading = false;
          _chatsLoaded = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _chatsLoading = false;
          _chatsLoaded = true;
        });
      }
    }
  }

  // ── Chat action handlers (local SQLite) ──

  Future<void> _renameChat(String chatId, String newTitle) async {
    final db = context.read<DatabaseService>();
    await db.updateChat(chatId, {'title': newTitle});
    _loadChats();
  }

  Future<void> _pinChat(String chatId, bool pin) async {
    // Pin not yet a DB column — ignore silently
  }

  Future<void> _exportChat(String chatId, String title) async {
    final db = context.read<DatabaseService>();
    final messages = await db.getMessages(chatId);
    if (messages.isEmpty || !mounted) return;

    final buf = StringBuffer();
    buf.writeln('# $title\n');
    for (final m in messages) {
      final role = (m['role'] as String?) ?? 'user';
      final content = (m['content'] as String?) ?? '';
      buf.writeln('**${role[0].toUpperCase()}${role.substring(1)}:**\n');
      buf.writeln('$content\n');
      buf.writeln('---\n');
    }

    try {
      final safeName = title
          .replaceAll(RegExp(r'[^\w\s\-]'), '')
          .trim()
          .replaceAll(RegExp(r'\s+'), '_');

      final outputPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Export conversation as Markdown',
        fileName: '$safeName.md',
        type: FileType.custom,
        allowedExtensions: ['md'],
      );

      if (outputPath != null) {
        await File(outputPath).writeAsString(buf.toString());
      }
    } catch (_) {}
  }

  Future<void> _deleteChat(String chatId) async {
    final db = context.read<DatabaseService>();
    await db.deleteChat(chatId);
    _loadChats();

    if (mounted) {
      final uri = GoRouterState.of(context).uri.toString();
      if (uri.contains(chatId)) {
        context.go('/chat');
      }
    }
  }

  // ── Date grouping ──

  String? _getCurrentChatId(BuildContext context) {
    final uri = GoRouterState.of(context).uri.toString();
    final match = RegExp(r'^/chat/(.+)$').firstMatch(uri);
    return match?.group(1);
  }

  Map<String, List<Chat>> _groupChats() {
    final grouped = <String, List<Chat>>{};
    final pinned = _chats.where((c) => c.isPinned).toList();
    final unpinned = _chats.where((c) => !c.isPinned).toList();

    if (pinned.isNotEmpty) grouped['Pinned'] = pinned;

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    for (final chat in unpinned) {
      final chatDay = DateTime(
        chat.updatedAt.year,
        chat.updatedAt.month,
        chat.updatedAt.day,
      );
      final diff = today.difference(chatDay).inDays;

      final label = diff == 0
          ? 'Today'
          : diff == 1
              ? 'Yesterday'
              : diff <= 7
                  ? 'This Week'
                  : 'Older';

      grouped.putIfAbsent(label, () => []).add(chat);
    }

    return grouped;
  }

  String _relativeTime(DateTime date) {
    final diff = DateTime.now().difference(date);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${date.month}/${date.day}';
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isMobile = width < 768;

    if (isMobile) {
      return Scaffold(
        body: widget.child,
        drawer: _buildExpandedSidebar(context),
        bottomNavigationBar: _buildBottomNav(context),
      );
    }

    return Scaffold(
      body: Row(
        children: [
          // Icon rail (always visible on desktop, like Perplexity)
          _buildIconRail(context),
          // Expanded sidebar overlay
          if (_sidebarExpanded) _buildExpandedSidebar(context),
          // Main content
          Expanded(child: widget.child),
        ],
      ),
    );
  }

  // ── Icon rail — always visible, like Perplexity's left nav ──
  Widget _buildIconRail(BuildContext context) {
    final theme = Theme.of(context);
    final currentPath = GoRouterState.of(context).uri.toString();

    return Container(
      width: 64,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          right: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: Column(
        children: [
          const SizedBox(height: 20),

          // App logo — uses the actual icon asset
          _buildRailIcon(
            context,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.asset(
                'assets/images/app_icon.png',
                width: 36,
                height: 36,
                fit: BoxFit.cover,
              ),
            ),
            tooltip: 'Studiomc',
            onTap: () => context.go('/chat'),
          ),

          const SizedBox(height: 12),

          // New chat
          _buildRailIcon(
            context,
            child: Icon(
              Icons.add,
              size: 22,
              color: theme.colorScheme.onSurface,
            ),
            tooltip: 'New Chat',
            onTap: () => context.go('/chat'),
          ),

          const SizedBox(height: 4),

          // History (expand sidebar)
          _buildRailIcon(
            context,
            child: Icon(
              Icons.history_rounded,
              size: 22,
              color: _sidebarExpanded
                  ? theme.colorScheme.primary
                  : theme.colorScheme.secondary,
            ),
            tooltip: 'History',
            onTap: () {
              setState(() => _sidebarExpanded = !_sidebarExpanded);
              if (_sidebarExpanded && !_chatsLoaded) {
                _loadChats();
              }
            },
          ),

          const SizedBox(height: 4),

          // Discover / Models
          _buildRailIcon(
            context,
            child: Icon(
              Icons.explore_outlined,
              size: 22,
              color: currentPath.startsWith('/models')
                  ? theme.colorScheme.primary
                  : theme.colorScheme.secondary,
            ),
            tooltip: 'Discover',
            onTap: () => context.go('/models'),
          ),

          const SizedBox(height: 4),

          // Documents
          _buildRailIcon(
            context,
            child: Icon(
              Icons.description_outlined,
              size: 22,
              color: currentPath == '/documents'
                  ? theme.colorScheme.primary
                  : theme.colorScheme.secondary,
            ),
            tooltip: 'Documents',
            onTap: () => context.go('/documents'),
          ),

          const SizedBox(height: 4),

          // Personalize
          _buildRailIcon(
            context,
            child: Icon(
              Icons.auto_awesome_outlined,
              size: 22,
              color: currentPath == '/training'
                  ? theme.colorScheme.primary
                  : theme.colorScheme.secondary,
            ),
            tooltip: 'Personalize',
            onTap: () => context.go('/training'),
          ),

          const Spacer(),

          // Settings
          _buildRailIcon(
            context,
            child: Icon(
              Icons.settings_outlined,
              size: 22,
              color: currentPath == '/settings'
                  ? theme.colorScheme.primary
                  : theme.colorScheme.secondary,
            ),
            tooltip: 'Settings',
            onTap: () => context.go('/settings'),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildRailIcon(
    BuildContext context, {
    required Widget child,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      preferBelow: false,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: SizedBox(
          width: 48,
          height: 48,
          child: Center(child: child),
        ),
      ),
    );
  }

  // ── Expanded sidebar — live chat history ──
  Widget _buildExpandedSidebar(BuildContext context) {
    final theme = Theme.of(context);
    final currentChatId = _getCurrentChatId(context);
    final grouped = _groupChats();

    // Ordered group labels
    const groupOrder = ['Pinned', 'Today', 'Yesterday', 'This Week', 'Older'];

    return Container(
      width: 220,
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor,
        border: Border(
          right: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 24, 12, 8),
            child: Row(
              children: [
                Text('History', style: theme.textTheme.headlineSmall),
                const Spacer(),
                // Refresh
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    icon: _chatsLoading
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: theme.colorScheme.secondary,
                            ),
                          )
                        : Icon(Icons.refresh_rounded, size: 16),
                    onPressed: _chatsLoading ? null : _loadChats,
                    style: IconButton.styleFrom(
                      foregroundColor: theme.colorScheme.secondary,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ),
                SizedBox(
                  width: 32,
                  height: 32,
                  child: IconButton(
                    icon: const Icon(Icons.close, size: 16),
                    onPressed: () =>
                        setState(() => _sidebarExpanded = false),
                    style: IconButton.styleFrom(
                      foregroundColor: theme.colorScheme.secondary,
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ),
              ],
            ),
          ),

          // New Chat button
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            child: SizedBox(
              width: double.infinity,
              child: TextButton.icon(
                onPressed: () => context.go('/chat'),
                icon: Icon(Icons.add, size: 18),
                label: Text(
                  'New Chat',
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: theme.colorScheme.primary,
                  backgroundColor:
                      theme.colorScheme.primary.withValues(alpha: 0.06),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 10),
                ),
              ),
            ),
          ),

          const SizedBox(height: 4),

          // Chat list
          Expanded(
            child: _chatsLoading && _chats.isEmpty
                ? Center(
                    child: SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                  )
                : _chats.isEmpty
                    ? _buildEmptyState(theme)
                    : ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 12),
                        children: [
                          for (final group in groupOrder)
                            if (grouped.containsKey(group)) ...[
                              _buildSectionLabel(context, group),
                              for (final chat in grouped[group]!)
                                _ChatListItem(
                                  chat: chat,
                                  isActive: chat.id == currentChatId,
                                  relativeTime:
                                      _relativeTime(chat.updatedAt),
                                  onTap: () =>
                                      context.go('/chat/${chat.id}'),
                                  onRename: (title) =>
                                      _renameChat(chat.id, title),
                                  onPin: (pin) =>
                                      _pinChat(chat.id, pin),
                                  onExport: () =>
                                      _exportChat(chat.id, chat.title),
                                  onDelete: () => _deleteChat(chat.id),
                                ),
                            ],
                        ],
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 40,
              color: theme.colorScheme.secondary.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 12),
            Text(
              'No conversations yet',
              style: GoogleFonts.inter(
                fontSize: 9,
                color: theme.colorScheme.secondary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Start a new chat to begin',
              style: GoogleFonts.inter(
                fontSize: 9,
                color: theme.colorScheme.secondary.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSectionLabel(BuildContext context, String label) {
    final theme = Theme.of(context);
    IconData? icon;
    if (label == 'Pinned') icon = Icons.push_pin_rounded;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 20, 8, 6),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, size: 11, color: theme.colorScheme.secondary),
            const SizedBox(width: 4),
          ],
          Text(
            label.toUpperCase(),
            style: theme.textTheme.labelSmall,
          ),
        ],
      ),
    );
  }

  Widget _buildBottomNav(BuildContext context) {
    final currentPath = GoRouterState.of(context).uri.toString();
    int currentIndex = 0;
    if (currentPath.startsWith('/chat')) currentIndex = 0;
    if (currentPath == '/documents') currentIndex = 1;
    if (currentPath == '/training') currentIndex = 2;
    if (currentPath == '/models') currentIndex = 3;
    if (currentPath == '/settings') currentIndex = 4;

    return NavigationBar(
      selectedIndex: currentIndex,
      onDestinationSelected: (i) {
        switch (i) {
          case 0:
            context.go('/chat');
          case 1:
            context.go('/documents');
          case 2:
            context.go('/training');
          case 3:
            context.go('/models');
          case 4:
            context.go('/settings');
        }
      },
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.chat_outlined),
          selectedIcon: Icon(Icons.chat),
          label: 'Chat',
        ),
        NavigationDestination(
          icon: Icon(Icons.description_outlined),
          selectedIcon: Icon(Icons.description),
          label: 'Docs',
        ),
        NavigationDestination(
          icon: Icon(Icons.auto_awesome_outlined),
          selectedIcon: Icon(Icons.auto_awesome),
          label: 'Personalize',
        ),
        NavigationDestination(
          icon: Icon(Icons.explore_outlined),
          selectedIcon: Icon(Icons.explore),
          label: 'Discover',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_outlined),
          selectedIcon: Icon(Icons.settings),
          label: 'Settings',
        ),
      ],
    );
  }
}

// ── Individual chat list item with hover controls ──

class _ChatListItem extends StatefulWidget {
  final Chat chat;
  final bool isActive;
  final String relativeTime;
  final VoidCallback onTap;
  final ValueChanged<String> onRename;
  final ValueChanged<bool> onPin;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  const _ChatListItem({
    required this.chat,
    required this.isActive,
    required this.relativeTime,
    required this.onTap,
    required this.onRename,
    required this.onPin,
    required this.onExport,
    required this.onDelete,
  });

  @override
  State<_ChatListItem> createState() => _ChatListItemState();
}

class _ChatListItemState extends State<_ChatListItem> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onSecondaryTapUp: (details) {
          _showContextMenu(context, details.globalPosition);
        },
        onLongPress: () {
          _showContextMenu(
            context,
            Offset.zero, // fallback — shows at default position
          );
        },
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 1),
          decoration: BoxDecoration(
            color: widget.isActive
                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                : _hovered
                    ? theme.colorScheme.surfaceContainerHighest
                    : null,
            borderRadius: BorderRadius.circular(10),
          ),
          child: ListTile(
            dense: true,
            contentPadding: const EdgeInsets.symmetric(horizontal: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            title: Text(
              widget.chat.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: widget.isActive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.onSurface,
                fontWeight:
                    widget.isActive ? FontWeight.w500 : FontWeight.w400,
              ),
            ),
            subtitle: Text(
              widget.relativeTime,
              style: GoogleFonts.inter(
                fontSize: 9,
                color: theme.colorScheme.secondary,
              ),
            ),
            trailing: AnimatedOpacity(
              opacity: _hovered || widget.isActive ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: ConversationControls(
                title: widget.chat.title,
                isPinned: widget.chat.isPinned,
                displayMode: ConversationControlsDisplay.menu,
                onRename: widget.onRename,
                onPin: widget.onPin,
                onExport: widget.onExport,
                onDelete: widget.onDelete,
              ),
            ),
            onTap: widget.onTap,
          ),
        ),
      ),
    );
  }

  void _showContextMenu(BuildContext context, Offset position) {
    final theme = Theme.of(context);
    final RenderBox? overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    showMenu<String>(
      context: context,
      position: position == Offset.zero
          ? RelativeRect.fromLTRB(100, 200, 100, 200)
          : RelativeRect.fromRect(
              position & const Size(1, 1),
              Offset.zero & overlay.size,
            ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: theme.scaffoldBackgroundColor,
      elevation: 4,
      items: [
        PopupMenuItem(
          value: 'rename',
          height: 40,
          child: _menuRow(theme, Icons.edit_outlined, 'Rename'),
        ),
        PopupMenuItem(
          value: 'pin',
          height: 40,
          child: _menuRow(
            theme,
            widget.chat.isPinned
                ? Icons.push_pin_rounded
                : Icons.push_pin_outlined,
            widget.chat.isPinned ? 'Unpin' : 'Pin to top',
          ),
        ),
        PopupMenuItem(
          value: 'export',
          height: 40,
          child: _menuRow(theme, Icons.ios_share_rounded, 'Export'),
        ),
        const PopupMenuDivider(height: 8),
        PopupMenuItem(
          value: 'delete',
          height: 40,
          child: _menuRow(
            theme,
            Icons.delete_outline_rounded,
            'Delete',
            color: theme.colorScheme.error,
          ),
        ),
      ],
    ).then((value) {
      if (value == null) return;
      switch (value) {
        case 'rename':
          _showRenameInline();
        case 'pin':
          widget.onPin(!widget.chat.isPinned);
        case 'export':
          widget.onExport();
        case 'delete':
          widget.onDelete();
      }
    });
  }

  Widget _menuRow(ThemeData theme, IconData icon, String label,
      {Color? color}) {
    return Row(
      children: [
        Icon(icon, size: 16, color: color ?? theme.colorScheme.secondary),
        const SizedBox(width: 10),
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 9,
            color: color ?? theme.colorScheme.onSurface,
          ),
        ),
      ],
    );
  }

  Future<void> _showRenameInline() async {
    final controller = TextEditingController(text: widget.chat.title);
    final theme = Theme.of(context);

    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        backgroundColor: theme.scaffoldBackgroundColor,
        title: Text(
          'Rename conversation',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 9,
            fontWeight: FontWeight.w500,
            color: theme.colorScheme.onSurface,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: GoogleFonts.inter(
            fontSize: 9,
            color: theme.colorScheme.onSurface,
          ),
          decoration: InputDecoration(
            hintText: 'Conversation title',
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: theme.dividerColor),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              Navigator.of(ctx).pop(v.isEmpty ? null : v);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );

    controller.dispose();

    if (newTitle != null &&
        newTitle.isNotEmpty &&
        newTitle != widget.chat.title) {
      widget.onRename(newTitle);
    }
  }
}
