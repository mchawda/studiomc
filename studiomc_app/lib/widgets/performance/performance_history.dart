import 'package:flutter/material.dart';

class PerformanceHistory extends StatelessWidget {
  final List<Map<String, dynamic>> history;

  const PerformanceHistory({
    super.key,
    required this.history,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Recent Performance',
          style: theme.textTheme.titleLarge,
        ),
        const SizedBox(height: 12),
        if (history.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Center(
              child: Text(
                'No history available',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.secondary,
                ),
              ),
            ),
          )
        else
          ...history.map((entry) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Card(
                  child: ListTile(
                    title: Text(
                      entry['title'] ?? 'Chat',
                      style: theme.textTheme.bodyMedium,
                    ),
                    trailing: Text(
                      '${entry['tokPerS']?.toStringAsFixed(1) ?? '0.0'} tok/s',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                  ),
                ),
              )),
      ],
    );
  }
}
