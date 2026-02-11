// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';

class PerformanceMetrics extends StatelessWidget {
  final int ttftMs;
  final double tokPerS;

  const PerformanceMetrics({
    super.key,
    required this.ttftMs,
    required this.tokPerS,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Key Metrics',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        _MetricGauge(
          label: 'TTFT',
          value: '${ttftMs}ms',
          progress: _calculateTtftProgress(ttftMs),
          color: theme.colorScheme.primary,
        ),
        const SizedBox(height: 16),
        _MetricGauge(
          label: 'tok/s',
          value: tokPerS.toStringAsFixed(1),
          progress: _calculateTokPerSProgress(tokPerS),
          color: theme.colorScheme.primary,
        ),
      ],
    );
  }

  double _calculateTtftProgress(int ttftMs) {
    // Normalize TTFT: 0ms = 1.0, 2000ms+ = 0.0
    if (ttftMs <= 0) return 1.0;
    if (ttftMs >= 2000) return 0.0;
    return 1.0 - (ttftMs / 2000);
  }

  double _calculateTokPerSProgress(double tokPerS) {
    // Normalize tok/s: 50+ = 1.0, 0 = 0.0
    if (tokPerS <= 0) return 0.0;
    if (tokPerS >= 50) return 1.0;
    return tokPerS / 50;
  }
}

class _MetricGauge extends StatelessWidget {
  final String label;
  final String value;
  final double progress;
  final Color color;

  const _MetricGauge({
    required this.label,
    required this.value,
    required this.progress,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: theme.textTheme.bodyMedium,
            ),
            Text(
              value,
              style: theme.textTheme.bodyMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: progress,
            minHeight: 8,
            backgroundColor: theme.colorScheme.outline.withValues(alpha: 0.2),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }
}
