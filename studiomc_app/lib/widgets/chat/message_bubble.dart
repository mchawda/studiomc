// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/widgets/chat/code_block_widget.dart';

/// Clean message layout — no heavy colored bubbles.
/// User messages right-aligned with subtle bg, assistant left-aligned on white.
class MessageBubble extends StatelessWidget {
  final Message message;
  final VoidCallback? onRegenerate;
  final VoidCallback? onCopy;

  const MessageBubble({
    super.key,
    required this.message,
    this.onRegenerate,
    this.onCopy,
  });

  @override
  Widget build(BuildContext context) {
    if (message.role == MessageRole.system) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final isUser = message.role == MessageRole.user;
    final isAssistant = message.role == MessageRole.assistant;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                Container(
                  constraints: BoxConstraints(
                    maxWidth: MediaQuery.of(context).size.width * 0.65,
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
                  decoration: BoxDecoration(
                    color: isUser
                        ? theme.colorScheme.surfaceContainerHighest
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(18),
                  ),
                  child: _buildMessageContent(context, theme, isUser),
                ),
                if (isAssistant) ...[
                  const SizedBox(height: 4),
                  _buildAssistantActions(theme),
                ],
              ],
            ),
          ),

          if (isUser) const SizedBox(width: 12),
        ],
      ),
    );
  }

  Widget _buildAvatar(ThemeData theme, {required bool isUser}) {
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Center(
        child: Text(
          'MC',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 9,
            fontWeight: FontWeight.w700,
            color: theme.colorScheme.primary,
          ),
        ),
      ),
    );
  }

  Widget _buildMessageContent(BuildContext context, ThemeData theme, bool isUser) {
    final textColor = theme.colorScheme.onSurface;
    final parts = _parseContent(message.content);

    if (parts.length == 1 && parts.first.isCode == false) {
      return _buildStreamingText(theme, parts.first.text, textColor, message.isStreaming);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: parts.map((part) {
        if (part.isCode) {
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: CodeBlockWidget(code: part.text, language: part.language ?? ''),
          );
        }
        return _buildStreamingText(theme, part.text, textColor, false);
      }).toList(),
    );
  }

  Widget _buildStreamingText(ThemeData theme, String text, Color textColor, bool isStreaming) {
    return RichText(
      text: TextSpan(
        style: GoogleFonts.inter(
          fontSize: 9,
          fontWeight: FontWeight.w400,
          color: textColor,
          height: 1.7,
        ),
        children: [
          TextSpan(text: text),
          if (isStreaming) WidgetSpan(child: _StreamingCursor(color: textColor)),
        ],
      ),
    );
  }

  Widget _buildAssistantActions(ThemeData theme) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _ActionButton(
          icon: Icons.copy_rounded,
          tooltip: 'Copy',
          onPressed: () {
            Clipboard.setData(ClipboardData(text: message.content));
            onCopy?.call();
          },
        ),
        const SizedBox(width: 2),
        _ActionButton(icon: Icons.refresh_rounded, tooltip: 'Regenerate', onPressed: onRegenerate),
      ],
    );
  }

  List<_ContentPart> _parseContent(String content) {
    final parts = <_ContentPart>[];
    final codeBlockRegex = RegExp(r'```(\w*)\n([\s\S]*?)```', multiLine: true);

    int lastEnd = 0;
    for (final match in codeBlockRegex.allMatches(content)) {
      if (match.start > lastEnd) {
        final textBefore = content.substring(lastEnd, match.start).trim();
        if (textBefore.isNotEmpty) parts.add(_ContentPart(text: textBefore));
      }
      parts.add(_ContentPart(text: match.group(2)?.trim() ?? '', isCode: true, language: match.group(1)));
      lastEnd = match.end;
    }
    if (lastEnd < content.length) {
      final remaining = content.substring(lastEnd).trim();
      if (remaining.isNotEmpty) parts.add(_ContentPart(text: remaining));
    }
    if (parts.isEmpty) parts.add(_ContentPart(text: content));
    return parts;
  }
}

class _ContentPart {
  final String text;
  final bool isCode;
  final String? language;
  _ContentPart({required this.text, this.isCode = false, this.language});
}

class _StreamingCursor extends StatefulWidget {
  final Color color;
  const _StreamingCursor({required this.color});

  @override
  State<_StreamingCursor> createState() => _StreamingCursorState();
}

class _StreamingCursorState extends State<_StreamingCursor> with SingleTickerProviderStateMixin {
  late AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(duration: const Duration(milliseconds: 600), vsync: this)
      ..repeat(reverse: true);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Opacity(
          opacity: _controller.value,
          child: Container(
            width: 2,
            height: 16,
            margin: const EdgeInsets.only(left: 2),
            color: widget.color,
          ),
        );
      },
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  const _ActionButton({required this.icon, required this.tooltip, this.onPressed});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 30,
      height: 30,
      child: IconButton(
        icon: Icon(icon, size: 15),
        tooltip: tooltip,
        onPressed: onPressed,
        style: IconButton.styleFrom(
          foregroundColor: theme.colorScheme.secondary,
          padding: EdgeInsets.zero,
        ),
      ),
    );
  }
}
