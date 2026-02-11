// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class CodeBlockWidget extends StatefulWidget {
  final String code;
  final String language;

  const CodeBlockWidget({
    super.key,
    required this.code,
    this.language = '',
  });

  @override
  State<CodeBlockWidget> createState() => _CodeBlockWidgetState();
}

class _CodeBlockWidgetState extends State<CodeBlockWidget> {
  bool _copied = false;

  void _copyCode() {
    Clipboard.setData(ClipboardData(text: widget.code));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final bgColor = isDark
        ? const Color(0xFF0D1117) // GitHub dark code bg
        : const Color(0xFFF6F8FA); // GitHub light code bg
    final headerColor = isDark
        ? const Color(0xFF161B22)
        : const Color(0xFFEAEEF2);

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header with language label and copy button
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            color: headerColor,
            child: Row(
              children: [
                if (widget.language.isNotEmpty)
                  Text(
                    widget.language,
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                const Spacer(),
                SizedBox(
                  height: 28,
                  child: TextButton.icon(
                    onPressed: _copyCode,
                    icon: Icon(
                      _copied ? Icons.check_rounded : Icons.copy_rounded,
                      size: 14,
                    ),
                    label: Text(
                      _copied ? 'Copied!' : 'Copy',
                      style: GoogleFonts.inter(fontSize: 9),
                    ),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      foregroundColor: _copied
                          ? const Color(0xFF10B981)
                          : theme.colorScheme.secondary,
                      visualDensity: VisualDensity.compact,
                    ),
                  ),
                ),
              ],
            ),
          ),
          // Code body
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            color: bgColor,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SelectableText(
                widget.code,
                style: GoogleFonts.jetBrainsMono(
                  fontSize: 9,
                  height: 1.6,
                  color: isDark
                      ? const Color(0xFFE6EDF3)
                      : const Color(0xFF24292F),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
