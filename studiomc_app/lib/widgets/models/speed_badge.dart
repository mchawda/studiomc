// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';
import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/theme/app_theme.dart';

class SpeedBadge extends StatelessWidget {
  final SpeedRating speedRating;

  const SpeedBadge({
    super.key,
    required this.speedRating,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final speedInfo = _getSpeedInfo(speedRating);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: speedInfo.color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: speedInfo.color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Text(
        speedInfo.label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: speedInfo.color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  _SpeedInfo _getSpeedInfo(SpeedRating rating) {
    switch (rating) {
      case SpeedRating.fast:
        return _SpeedInfo(AppTheme.speedFast, 'Fast');
      case SpeedRating.ok:
        return _SpeedInfo(AppTheme.speedOk, 'OK');
      case SpeedRating.slow:
        return _SpeedInfo(AppTheme.speedSlow, 'Slow');
      case SpeedRating.painful:
        return _SpeedInfo(AppTheme.speedPainful, 'Painful');
    }
  }
}

class _SpeedInfo {
  final Color color;
  final String label;

  _SpeedInfo(this.color, this.label);
}
