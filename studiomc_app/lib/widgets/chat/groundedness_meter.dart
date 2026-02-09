import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Visual indicator showing how well an AI response is supported by sources.
///
/// Displays a percentage, a color-coded progress bar, and source count:
/// - **Green** (>70 %): well-supported
/// - **Amber** (40–70 %): partially supported
/// - **Red** (<40 %): weakly supported
/// - Special "No sources found" banner when [percentage] is 0.
///
/// Only shown in **Docs** and **Investigate** modes.
class GroundednessMeter extends StatelessWidget {
  /// Groundedness score, 0.0 – 1.0.
  final double percentage;

  /// Number of source documents cited.
  final int sourceCount;

  /// Compact mode — smaller text, thinner bar. Good for inline use.
  final bool compact;

  const GroundednessMeter({
    super.key,
    required this.percentage,
    this.sourceCount = 0,
    this.compact = false,
  });

  // ── Color logic — green >70%, amber 40-70%, red <40% ──

  static Color barColor(double pct) {
    if (pct > 0.7) return const Color(0xFF10B981); // green / well-supported
    if (pct >= 0.4) return const Color(0xFFF59E0B); // amber / partial
    if (pct > 0) return const Color(0xFFF43F5E); // red / weak
    return const Color(0xFF9CA3AF); // gray — no sources
  }

  String get _label {
    if (percentage <= 0) return 'No sources found';
    final pct = (percentage * 100).round();
    return '$pct% grounded';
  }

  String get _qualityLabel {
    if (percentage > 0.7) return 'Well Grounded';
    if (percentage >= 0.4) return 'Partially Grounded';
    if (percentage > 0) return 'Low Confidence';
    return '';
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = barColor(percentage);

    // No-sources banner
    if (percentage <= 0) return _buildNoSourcesBanner(theme);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 14,
        vertical: compact ? 6 : 10,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header row: icon + label + quality badge
          Row(
            children: [
              Icon(
                Icons.verified_outlined,
                size: compact ? 14 : 16,
                color: color,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  _label,
                  style: GoogleFonts.inter(
                    fontSize: compact ? 11 : 12,
                    fontWeight: FontWeight.w500,
                    color: color,
                  ),
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _qualityLabel,
                  style: GoogleFonts.inter(
                    fontSize: compact ? 9 : 10,
                    fontWeight: FontWeight.w600,
                    color: color,
                  ),
                ),
              ),
            ],
          ),

          SizedBox(height: compact ? 6 : 8),

          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: compact ? 3 : 4,
              child: LinearProgressIndicator(
                value: percentage.clamp(0.0, 1.0),
                backgroundColor: color.withValues(alpha: 0.12),
                valueColor: AlwaysStoppedAnimation<Color>(color),
              ),
            ),
          ),

          // Source count
          if (sourceCount > 0) ...[
            SizedBox(height: compact ? 4 : 6),
            Row(
              children: [
                Icon(
                  Icons.library_books_outlined,
                  size: compact ? 11 : 12,
                  color: theme.colorScheme.secondary,
                ),
                const SizedBox(width: 4),
                Text(
                  'Based on $sourceCount source${sourceCount != 1 ? 's' : ''}',
                  style: GoogleFonts.inter(
                    fontSize: compact ? 10 : 11,
                    fontWeight: FontWeight.w400,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNoSourcesBanner(ThemeData theme) {
    final bannerColor = theme.colorScheme.secondary;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: compact ? 10 : 14,
        vertical: compact ? 6 : 10,
      ),
      decoration: BoxDecoration(
        color: bannerColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: bannerColor.withValues(alpha: 0.12)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: compact ? 14 : 16,
            color: bannerColor,
          ),
          const SizedBox(width: 8),
          Text(
            'No sources found',
            style: GoogleFonts.inter(
              fontSize: compact ? 11 : 12,
              fontWeight: FontWeight.w500,
              color: bannerColor,
            ),
          ),
        ],
      ),
    );
  }
}
