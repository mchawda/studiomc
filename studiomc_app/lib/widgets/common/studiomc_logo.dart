import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Studiomc brand mark — uses the actual app icon asset + optional text.
class StudiomcLogo extends StatelessWidget {
  final double size;
  final bool showText;

  const StudiomcLogo({
    super.key,
    this.size = 36,
    this.showText = true,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(size * 0.22),
          child: Image.asset(
            'assets/images/app_icon.png',
            width: size,
            height: size,
            fit: BoxFit.cover,
          ),
        ),
        if (showText) ...[
          SizedBox(width: size * 0.3),
          Text(
            'Studiomc',
            style: GoogleFonts.spaceGrotesk(
              fontSize: size * 0.45,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface,
            ),
          ),
        ],
      ],
    );
  }
}
