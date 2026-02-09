import 'package:flutter/material.dart';
import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/widgets/investigate/trace_step_widget.dart';
import 'package:studiomc_app/widgets/investigate/budget_indicator.dart';

/// Main panel widget for displaying investigation trace
class TracePanel extends StatelessWidget {
  final List<TraceStep> steps;
  final int toolCallsUsed;
  final int toolCallsLimit;
  final double timeUsedSeconds;
  final double timeLimitSeconds;
  final bool hasResults;

  const TracePanel({
    super.key,
    required this.steps,
    required this.toolCallsUsed,
    required this.toolCallsLimit,
    required this.timeUsedSeconds,
    required this.timeLimitSeconds,
    this.hasResults = true,
  });

  /// Static demo method with sample data
  static TracePanel demo() {
    return TracePanel(
      steps: const [
        TraceStep(
          id: 'ts-1',
          type: 'search',
          description: 'Searching knowledge base for relevant documents',
          result: 'Found 4 relevant chunks',
          durationMs: 45,
        ),
        TraceStep(
          id: 'ts-2',
          type: 'open',
          description: 'Opening document: resume_guide.pdf',
          result: 'Document loaded successfully',
          durationMs: 12,
        ),
        TraceStep(
          id: 'ts-3',
          type: 'table_extract',
          description: 'Extracting table data from document',
          result: 'Extracted 3 tables',
          durationMs: 28,
        ),
        TraceStep(
          id: 'ts-4',
          type: 'open',
          description: 'Opening document: cover_letter_examples.pdf',
          result: 'Document loaded successfully',
          durationMs: 8,
        ),
        TraceStep(
          id: 'ts-5',
          type: 'cite',
          description: 'Citing relevant sections',
          result: 'Added 2 citations',
          durationMs: 5,
        ),
      ],
      toolCallsUsed: 5,
      toolCallsLimit: 6,
      timeUsedSeconds: 4.8,
      timeLimitSeconds: 20.0,
      hasResults: true,
    );
  }

  bool get _isBudgetExceeded {
    return toolCallsUsed >= toolCallsLimit || timeUsedSeconds >= timeLimitSeconds;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          children: [
            Icon(
              Icons.search,
              size: 20,
              color: theme.colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Text(
              'Investigation Trace',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // Trace steps
        if (steps.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 24),
            child: Center(
              child: Text(
                'No trace steps available',
                style: theme.textTheme.bodyMedium?.copyWith(
                  color: theme.colorScheme.onSurface.withOpacity(0.6),
                ),
              ),
            ),
          )
        else
          ...steps.asMap().entries.map((entry) {
            final index = entry.key;
            final step = entry.value;
            final isLast = index == steps.length - 1;
            return TraceStepWidget(
              step: step,
              isLast: isLast,
            );
          }),

        const SizedBox(height: 16),

        // Budget indicator
        BudgetIndicator(
          toolCallsUsed: toolCallsUsed,
          toolCallsLimit: toolCallsLimit,
          timeUsedSeconds: timeUsedSeconds,
          timeLimitSeconds: timeLimitSeconds,
        ),

        // Banners
        if (_isBudgetExceeded) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.amber.withOpacity(0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Colors.amber.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.warning_amber_rounded,
                  size: 20,
                  color: Colors.amber.shade700,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Stopped: Budget exceeded',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.amber.shade900,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],

        if (!hasResults && steps.isNotEmpty) ...[
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: theme.colorScheme.errorContainer.withOpacity(0.3),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: theme.colorScheme.error.withOpacity(0.3),
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 20,
                  color: theme.colorScheme.error,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'No evidence found',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onErrorContainer,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}
