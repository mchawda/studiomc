// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

/// Conversation management controls — rename, pin, export, delete.
///
/// Renders as a compact row of icon-buttons (for toolbar embedding) or as a
/// [PopupMenuButton] overflow menu depending on [displayMode].
///
/// All business logic lives outside — callers wire up [onRename], [onPin],
/// [onExport], and [onDelete].
class ConversationControls extends StatefulWidget {
  /// Current conversation title (shown in rename dialog).
  final String title;

  /// Whether the conversation is currently pinned.
  final bool isPinned;

  /// Full markdown text of the conversation (used for export).
  final String? markdownContent;

  /// Display mode — inline icon row or overflow popup menu.
  final ConversationControlsDisplay displayMode;

  // ── Callbacks ──
  final ValueChanged<String>? onRename;
  final ValueChanged<bool>? onPin;
  final VoidCallback? onExport;
  final VoidCallback? onDelete;

  const ConversationControls({
    super.key,
    required this.title,
    this.isPinned = false,
    this.markdownContent,
    this.displayMode = ConversationControlsDisplay.menu,
    this.onRename,
    this.onPin,
    this.onExport,
    this.onDelete,
  });

  @override
  State<ConversationControls> createState() => _ConversationControlsState();
}

enum ConversationControlsDisplay { inline, menu }

class _ConversationControlsState extends State<ConversationControls> {
  // ── Rename ──

  Future<void> _showRenameDialog() async {
    final controller = TextEditingController(text: widget.title);
    final theme = Theme.of(context);

    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
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
              hintStyle: GoogleFonts.inter(
                fontSize: 9,
                color: theme.colorScheme.secondary,
              ),
              filled: true,
              fillColor: theme.colorScheme.surfaceContainerHighest,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: theme.dividerColor),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: theme.dividerColor),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: theme.colorScheme.primary,
                  width: 1.5,
                ),
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
            ),
            onSubmitted: (value) {
              Navigator.of(ctx).pop(value.trim());
            },
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.secondary,
                textStyle: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                ),
              ),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final value = controller.text.trim();
                Navigator.of(ctx).pop(value.isEmpty ? null : value);
              },
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.primary,
                foregroundColor: theme.colorScheme.onPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                textStyle: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                ),
              ),
              child: const Text('Rename'),
            ),
          ],
        );
      },
    );

    controller.dispose();

    if (newTitle != null && newTitle.isNotEmpty && newTitle != widget.title) {
      widget.onRename?.call(newTitle);
    }
  }

  // ── Export — save to file via file_picker, clipboard fallback ──

  Future<void> _handleExport() async {
    final content = widget.markdownContent;
    if (content == null || content.isEmpty) {
      widget.onExport?.call();
      return;
    }

    try {
      final safeName = widget.title
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
        await File(outputPath).writeAsString(content);

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Exported to ${outputPath.split('/').last}',
                style: GoogleFonts.inter(fontSize: 9),
              ),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
              duration: const Duration(seconds: 3),
            ),
          );
        }
      }
    } catch (_) {
      // Fallback: copy to clipboard
      await Clipboard.setData(ClipboardData(text: content));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Copied to clipboard',
              style: GoogleFonts.inter(fontSize: 9),
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }

    widget.onExport?.call();
  }

  // ── Delete ──

  Future<void> _showDeleteConfirmation() async {
    final theme = Theme.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          backgroundColor: theme.scaffoldBackgroundColor,
          title: Text(
            'Delete conversation?',
            style: GoogleFonts.spaceGrotesk(
              fontSize: 9,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
          ),
          content: Text(
            'This will permanently remove "${widget.title}" and all its messages. This action cannot be undone.',
            style: GoogleFonts.inter(
              fontSize: 9,
              color: theme.colorScheme.secondary,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              style: TextButton.styleFrom(
                foregroundColor: theme.colorScheme.secondary,
                textStyle: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                ),
              ),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(
                backgroundColor: theme.colorScheme.error,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
                textStyle: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w500,
                ),
              ),
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );

    if (confirmed == true) {
      widget.onDelete?.call();
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return widget.displayMode == ConversationControlsDisplay.inline
        ? _buildInline(context)
        : _buildMenu(context);
  }

  // ── Inline mode — row of icon buttons ──

  Widget _buildInline(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = theme.colorScheme.secondary;
    const iconSize = 18.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _MiniIconButton(
          icon: Icons.edit_outlined,
          tooltip: 'Rename',
          color: iconColor,
          size: iconSize,
          onPressed: _showRenameDialog,
        ),
        _MiniIconButton(
          icon: widget.isPinned
              ? Icons.push_pin_rounded
              : Icons.push_pin_outlined,
          tooltip: widget.isPinned ? 'Unpin' : 'Pin',
          color: widget.isPinned ? theme.colorScheme.primary : iconColor,
          size: iconSize,
          onPressed: () => widget.onPin?.call(!widget.isPinned),
        ),
        _MiniIconButton(
          icon: Icons.ios_share_rounded,
          tooltip: 'Export as Markdown',
          color: iconColor,
          size: iconSize,
          onPressed: _handleExport,
        ),
        _MiniIconButton(
          icon: Icons.delete_outline_rounded,
          tooltip: 'Delete',
          color: iconColor,
          size: iconSize,
          onPressed: _showDeleteConfirmation,
        ),
      ],
    );
  }

  // ── Popup menu mode ──

  Widget _buildMenu(BuildContext context) {
    final theme = Theme.of(context);

    return PopupMenuButton<_Action>(
      icon: Icon(
        Icons.more_horiz_rounded,
        size: 20,
        color: theme.colorScheme.secondary,
      ),
      tooltip: 'Conversation options',
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: theme.scaffoldBackgroundColor,
      elevation: 4,
      position: PopupMenuPosition.under,
      onSelected: (action) {
        switch (action) {
          case _Action.rename:
            _showRenameDialog();
          case _Action.pin:
            widget.onPin?.call(!widget.isPinned);
          case _Action.export:
            _handleExport();
          case _Action.delete:
            _showDeleteConfirmation();
        }
      },
      itemBuilder: (context) => [
        _buildMenuItem(
          theme,
          icon: Icons.edit_outlined,
          label: 'Rename',
          value: _Action.rename,
        ),
        _buildMenuItem(
          theme,
          icon: widget.isPinned
              ? Icons.push_pin_rounded
              : Icons.push_pin_outlined,
          label: widget.isPinned ? 'Unpin' : 'Pin to top',
          value: _Action.pin,
          iconColor: widget.isPinned ? theme.colorScheme.primary : null,
        ),
        _buildMenuItem(
          theme,
          icon: Icons.ios_share_rounded,
          label: 'Export as Markdown',
          value: _Action.export,
        ),
        const PopupMenuDivider(height: 8),
        _buildMenuItem(
          theme,
          icon: Icons.delete_outline_rounded,
          label: 'Delete',
          value: _Action.delete,
          iconColor: theme.colorScheme.error,
          textColor: theme.colorScheme.error,
        ),
      ],
    );
  }

  PopupMenuItem<_Action> _buildMenuItem(
    ThemeData theme, {
    required IconData icon,
    required String label,
    required _Action value,
    Color? iconColor,
    Color? textColor,
  }) {
    return PopupMenuItem<_Action>(
      value: value,
      height: 42,
      child: Row(
        children: [
          Icon(icon, size: 18, color: iconColor ?? theme.colorScheme.secondary),
          const SizedBox(width: 12),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 9,
              fontWeight: FontWeight.w400,
              color: textColor ?? theme.colorScheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }
}

enum _Action { rename, pin, export, delete }

// ── Tiny icon button used in inline mode ──

class _MiniIconButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final double size;
  final VoidCallback? onPressed;

  const _MiniIconButton({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.size,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        icon: Icon(icon, size: size),
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          foregroundColor: color,
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }
}
