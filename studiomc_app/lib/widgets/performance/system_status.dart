// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';

class SystemStatus extends StatelessWidget {
  final int ramUsedMb;
  final int ramTotalMb;
  final int? vramUsedMb;
  final int? vramTotalMb;
  final double diskMbps;

  const SystemStatus({
    super.key,
    required this.ramUsedMb,
    required this.ramTotalMb,
    this.vramUsedMb,
    this.vramTotalMb,
    required this.diskMbps,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'System Status',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 16),
        _SystemBar(
          label: 'RAM',
          value: ramTotalMb > 0
              ? '${(ramUsedMb / 1024).toStringAsFixed(1)} / ${(ramTotalMb / 1024).toStringAsFixed(0)} GB'
              : '—',
          progress: ramTotalMb > 0 ? ramUsedMb / ramTotalMb : 0,
        ),
        if (vramUsedMb != null && vramTotalMb != null && vramTotalMb! > 0) ...[
          const SizedBox(height: 12),
          _SystemBar(
            label: 'GPU Memory',
            value: '${(vramUsedMb! / 1024).toStringAsFixed(1)} / ${(vramTotalMb! / 1024).toStringAsFixed(0)} GB',
            progress: vramUsedMb! / vramTotalMb!,
          ),
        ],
        const SizedBox(height: 12),
        _SystemBar(
          label: 'Disk',
          value: '${diskMbps.toStringAsFixed(0)} MB/s',
          progress: _calculateDiskProgress(diskMbps),
        ),
      ],
    );
  }

  double _calculateDiskProgress(double diskMbps) {
    // Normalize disk speed: 5000+ MB/s = 1.0, 0 = 0.0
    if (diskMbps <= 0) return 0.0;
    if (diskMbps >= 5000) return 1.0;
    return diskMbps / 5000;
  }
}

class _SystemBar extends StatelessWidget {
  final String label;
  final String value;
  final double progress;

  const _SystemBar({
    required this.label,
    required this.value,
    required this.progress,
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
            valueColor: AlwaysStoppedAnimation<Color>(
              theme.colorScheme.primary,
            ),
          ),
        ),
      ],
    );
  }
}
