// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';
import 'package:studiomc_app/models/app_models.dart';

/// Widget for displaying a single trace step in a vertical timeline
class TraceStepWidget extends StatefulWidget {
  final TraceStep step;
  final bool isLast;

  const TraceStepWidget({
    super.key,
    required this.step,
    this.isLast = false,
  });

  @override
  State<TraceStepWidget> createState() => _TraceStepWidgetState();
}

class _TraceStepWidgetState extends State<TraceStepWidget>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      duration: const Duration(milliseconds: 300),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
    );
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  IconData _getIcon(String type) {
    switch (type.toLowerCase()) {
      case 'search':
        return Icons.search;
      case 'grep':
        return Icons.find_in_page;
      case 'open':
        return Icons.open_in_new;
      case 'summarize':
        return Icons.summarize;
      case 'table_extract':
        return Icons.table_chart;
      case 'cite':
        return Icons.format_quote;
      default:
        return Icons.circle;
    }
  }

  Color _getIconColor(String type, ThemeData theme) {
    switch (type.toLowerCase()) {
      case 'search':
        return Colors.blue;
      case 'grep':
        return Colors.purple;
      case 'open':
        return Colors.green;
      case 'summarize':
        return Colors.orange;
      case 'table_extract':
        return Colors.teal;
      case 'cite':
        return Colors.amber;
      default:
        return theme.colorScheme.primary;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final iconColor = _getIconColor(widget.step.type, theme);

    return FadeTransition(
      opacity: _fadeAnimation,
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Timeline connector + icon
            SizedBox(
              width: 28,
              child: Column(
                children: [
                  Container(
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: iconColor,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: theme.colorScheme.surface,
                        width: 2,
                      ),
                    ),
                    child: Icon(
                      _getIcon(widget.step.type),
                      size: 12,
                      color: theme.colorScheme.surface,
                    ),
                  ),
                  if (!widget.isLast)
                    Expanded(
                      child: Container(
                        width: 1,
                        color: theme.dividerColor,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Step content
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            widget.step.description,
                            style: theme.textTheme.bodyMedium,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '${widget.step.durationMs}ms',
                            style: theme.textTheme.labelSmall?.copyWith(
                              fontFeatures: [const FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
