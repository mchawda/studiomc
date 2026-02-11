import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Visual indicator showing how well an AI response is grounded in sources.
///
/// Displays a circular progress indicator with the percentage, color-coded:
/// - **Green** (>80 %): well-supported
/// - **Amber** (50–80 %): partially supported
/// - **Red** (<50 %): weakly supported
///
/// Below the indicator: "X of Y claims supported" text.
/// Expandable section showing unsupported claims when tapped.
///
/// Only shown in **Docs** and **Investigate** chat modes.
class GroundednessMeter extends StatefulWidget {
  /// Groundedness score, 0.0 – 1.0.
  final double percentage;

  /// Number of source documents cited.
  final int sourceCount;

  /// Number of claims supported by sources.
  final int supportedCount;

  /// Total number of claims evaluated.
  final int totalCount;

  /// List of claim sentences that have no supporting source.
  final List<String> unsupportedClaims;

  /// Compact mode — smaller ring, tighter spacing. Good for inline use.
  final bool compact;

  const GroundednessMeter({
    super.key,
    required this.percentage,
    this.sourceCount = 0,
    this.supportedCount = 0,
    this.totalCount = 0,
    this.unsupportedClaims = const [],
    this.compact = false,
  });

  /// Color for the given groundedness percentage.
  /// Green >80%, amber 50-80%, red <50%, gray = no sources.
  static Color barColor(double pct) {
    if (pct > 0.8) return const Color(0xFF10B981); // green
    if (pct >= 0.5) return const Color(0xFFF59E0B); // amber
    if (pct > 0) return const Color(0xFFF43F5E); // red
    return const Color(0xFF9CA3AF); // gray — no sources
  }

  @override
  State<GroundednessMeter> createState() => _GroundednessMeterState();
}

class _GroundednessMeterState extends State<GroundednessMeter> {
  bool _expanded = false;

  String get _pctLabel {
    if (widget.percentage <= 0) return '—';
    return '${(widget.percentage * 100).round()}%';
  }

  String get _claimsLabel {
    if (widget.totalCount == 0) return 'No claims evaluated';
    return '${widget.supportedCount} of ${widget.totalCount} claims supported';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = GroundednessMeter.barColor(widget.percentage);

    // No-sources banner
    if (widget.percentage <= 0 && widget.totalCount == 0) {
      return _buildNoSourcesBanner(theme);
    }

    final ringSize = widget.compact ? 36.0 : 44.0;
    final ringStroke = widget.compact ? 3.0 : 4.0;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: widget.compact ? 10 : 14,
        vertical: widget.compact ? 6 : 10,
      ),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.15)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Row: circular indicator + claims text ──
          Row(
            children: [
              // Circular progress indicator with percentage label
              SizedBox(
                width: ringSize,
                height: ringSize,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    SizedBox(
                      width: ringSize,
                      height: ringSize,
                      child: CircularProgressIndicator(
                        value: widget.percentage.clamp(0.0, 1.0),
                        strokeWidth: ringStroke,
                        backgroundColor: color.withValues(alpha: 0.15),
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                    ),
                    Text(
                      _pctLabel,
                      style: GoogleFonts.inter(
                        fontSize: widget.compact ? 9 : 11,
                        fontWeight: FontWeight.w700,
                        color: color,
                      ),
                    ),
                  ],
                ),
              ),

              const SizedBox(width: 10),

              // Claims text + source count
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _claimsLabel,
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.onSurface,
                      ),
                    ),
                    if (widget.sourceCount > 0) ...[
                      const SizedBox(height: 2),
                      Text(
                        'Based on ${widget.sourceCount} source${widget.sourceCount != 1 ? 's' : ''}',
                        style: GoogleFonts.inter(
                          fontSize: 9,
                          fontWeight: FontWeight.w400,
                          color: theme.colorScheme.secondary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),

          // ── Expandable unsupported claims section ──
          if (widget.unsupportedClaims.isNotEmpty) ...[
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              child: Row(
                children: [
                  Icon(
                    _expanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 14,
                    color: theme.colorScheme.secondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '${widget.unsupportedClaims.length} unsupported claim${widget.unsupportedClaims.length != 1 ? 's' : ''}',
                    style: GoogleFonts.inter(
                      fontSize: 9,
                      fontWeight: FontWeight.w500,
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                ],
              ),
            ),
            if (_expanded) ...[
              const SizedBox(height: 4),
              ...widget.unsupportedClaims.map(
                (claim) => Padding(
                  padding: const EdgeInsets.only(left: 18, bottom: 3),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Icon(
                          Icons.warning_amber_rounded,
                          size: 10,
                          color: const Color(0xFFF43F5E).withValues(alpha: 0.7),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          claim,
                          style: GoogleFonts.inter(
                            fontSize: 9,
                            height: 1.3,
                            color: theme.colorScheme.onSurface
                                .withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ],
      ),
    );
  }

  Widget _buildNoSourcesBanner(ThemeData theme) {
    final bannerColor = theme.colorScheme.secondary;

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: widget.compact ? 10 : 14,
        vertical: widget.compact ? 6 : 10,
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
            size: widget.compact ? 14 : 16,
            color: bannerColor,
          ),
          const SizedBox(width: 8),
          Text(
            'No sources found',
            style: GoogleFonts.inter(
              fontSize: widget.compact ? 11 : 12,
              fontWeight: FontWeight.w500,
              color: bannerColor,
            ),
          ),
        ],
      ),
    );
  }
}
