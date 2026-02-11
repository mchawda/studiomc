// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';
import 'package:studiomc_app/theme/app_theme.dart';

class SuggestionCard extends StatelessWidget {
  final String suggestion;
  final VoidCallback? onAction;

  const SuggestionCard({
    super.key,
    required this.suggestion,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      color: AppTheme.warning.withValues(alpha: 0.1),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Icon(
              Icons.lightbulb_outline,
              color: AppTheme.warning,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                suggestion,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (onAction != null) ...[
              const SizedBox(width: 12),
              TextButton(
                onPressed: onAction,
                child: const Text('Try it'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
