// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Compact branch navigation indicator for message trees.
///
/// Displays "Branch 1 of 3" with left/right arrows.
/// Only rendered when [totalBranches] > 1.
///
/// Designed to sit unobtrusively below a [MessageBubble] without
/// cluttering the chat flow.
class BranchIndicator extends StatelessWidget {
  /// 1-based index of the currently visible branch.
  final int currentBranch;

  /// Total sibling branches at this point in the tree.
  final int totalBranches;

  /// Navigate to the previous sibling branch.
  final VoidCallback? onPrevious;

  /// Navigate to the next sibling branch.
  final VoidCallback? onNext;

  const BranchIndicator({
    super.key,
    required this.currentBranch,
    required this.totalBranches,
    this.onPrevious,
    this.onNext,
  });

  @override
  Widget build(BuildContext context) {
    // Don't render at all when there's only one branch
    if (totalBranches <= 1) return const SizedBox.shrink();

    final theme = Theme.of(context);
    final hasPrev = currentBranch > 1;
    final hasNext = currentBranch < totalBranches;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Left arrow
          _NavArrow(
            icon: Icons.chevron_left_rounded,
            enabled: hasPrev,
            onTap: hasPrev ? onPrevious : null,
          ),

          const SizedBox(width: 2),

          // Label
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.account_tree_outlined,
                  size: 12,
                  color: theme.colorScheme.primary.withValues(alpha: 0.7),
                ),
                const SizedBox(width: 4),
                Text(
                  '$currentBranch of $totalBranches',
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.secondary,
                    letterSpacing: 0.1,
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(width: 2),

          // Right arrow
          _NavArrow(
            icon: Icons.chevron_right_rounded,
            enabled: hasNext,
            onTap: hasNext ? onNext : null,
          ),
        ],
      ),
    );
  }
}

// ── Tiny navigation arrow ──

class _NavArrow extends StatelessWidget {
  final IconData icon;
  final bool enabled;
  final VoidCallback? onTap;

  const _NavArrow({
    required this.icon,
    required this.enabled,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return SizedBox(
      width: 24,
      height: 24,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Center(
            child: Icon(
              icon,
              size: 16,
              color: enabled
                  ? theme.colorScheme.onSurface
                  : theme.colorScheme.secondary.withValues(alpha: 0.3),
            ),
          ),
        ),
      ),
    );
  }
}
