import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Clean empty state — just the brand name, nothing else.
class ChatEmptyState extends StatelessWidget {
  final ValueChanged<String> onSuggestionTap;

  const ChatEmptyState({super.key, required this.onSuggestionTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Center(
      child: Text(
        'studiomc',
        style: GoogleFonts.spaceGrotesk(
          fontSize: 42,
          fontWeight: FontWeight.w500,
          color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
          letterSpacing: -1.5,
        ),
      ),
    );
  }
}
