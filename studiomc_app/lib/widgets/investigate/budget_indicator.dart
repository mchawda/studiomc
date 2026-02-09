import 'package:flutter/material.dart';

/// Widget for displaying resource usage (tool calls and time)
class BudgetIndicator extends StatelessWidget {
  final int toolCallsUsed;
  final int toolCallsLimit;
  final double timeUsedSeconds;
  final double timeLimitSeconds;

  const BudgetIndicator({
    super.key,
    required this.toolCallsUsed,
    required this.toolCallsLimit,
    required this.timeUsedSeconds,
    required this.timeLimitSeconds,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final toolCallsProgress = toolCallsUsed / toolCallsLimit;
    final timeProgress = timeUsedSeconds / timeLimitSeconds;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tool calls
          Row(
            children: [
              Text(
                'Tool calls: $toolCallsUsed/$toolCallsLimit',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: toolCallsProgress,
            minHeight: 4,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(
              theme.colorScheme.primary,
            ),
          ),
          const SizedBox(height: 12),
          // Time
          Row(
            children: [
              Text(
                'Time: ${timeUsedSeconds.toStringAsFixed(1)}s / ${timeLimitSeconds.toStringAsFixed(0)}s',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.7),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          LinearProgressIndicator(
            value: timeProgress,
            minHeight: 4,
            backgroundColor: theme.colorScheme.surfaceContainerHighest,
            valueColor: AlwaysStoppedAnimation<Color>(
              theme.colorScheme.primary,
            ),
          ),
        ],
      ),
    );
  }
}
