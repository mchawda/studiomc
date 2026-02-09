import 'package:flutter/material.dart';

class AutoTuneCard extends StatelessWidget {
  final int contextLength;
  final int batchSize;
  final int prefetchDepth;

  const AutoTuneCard({
    super.key,
    required this.contextLength,
    required this.batchSize,
    required this.prefetchDepth,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Card(
      child: ExpansionTile(
        title: Text(
          'Settings optimized for your hardware',
          style: theme.textTheme.titleMedium,
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DetailRow(
                  label: 'Context length',
                  value: contextLength.toString(),
                ),
                const SizedBox(height: 8),
                _DetailRow(
                  label: 'Batch size',
                  value: batchSize.toString(),
                ),
                const SizedBox(height: 8),
                _DetailRow(
                  label: 'Prefetch depth',
                  value: '$prefetchDepth layers',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final String label;
  final String value;

  const _DetailRow({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.colorScheme.secondary,
          ),
        ),
        Text(
          value,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
