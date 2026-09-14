// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';

/// Design tokens — the *only* source of truth for spacing, radius, motion
/// and elevation in the Studiomc UI. Use these constants instead of
/// hand-tuned literals so the entire surface area can be re-tuned from
/// one file.
///
/// Inspired by LibreChat's restraint (one font, two weights, four radii).
class Spacing {
  Spacing._();

  /// 4-pt grid. Most things should compose from these six values.
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 24;
  static const double x2l = 32;
  static const double x3l = 48;
  static const double x4l = 64;

  /// Inset shorthands — pre-built EdgeInsets for the common cases.
  static const EdgeInsets allSm = EdgeInsets.all(sm);
  static const EdgeInsets allMd = EdgeInsets.all(md);
  static const EdgeInsets allLg = EdgeInsets.all(lg);
  static const EdgeInsets allXl = EdgeInsets.all(xl);

  static const EdgeInsets pageGutter =
      EdgeInsets.symmetric(horizontal: xl, vertical: md);
}

/// Corner radii — kept to four values. Cards/inputs use [md], pills use
/// [pill]. Don't introduce new values without updating the design system.
class Radii {
  Radii._();

  static const double sm = 6;
  static const double md = 10;
  static const double lg = 14;
  static const double pill = 9999;

  static const BorderRadius brSm = BorderRadius.all(Radius.circular(sm));
  static const BorderRadius brMd = BorderRadius.all(Radius.circular(md));
  static const BorderRadius brLg = BorderRadius.all(Radius.circular(lg));
  static const BorderRadius brPill = BorderRadius.all(Radius.circular(pill));
}

/// Motion — three durations, two curves. That's enough for every
/// transition in the app. Snappy by default; never bouncy.
class Motion {
  Motion._();

  static const Duration fast = Duration(milliseconds: 120);
  static const Duration base = Duration(milliseconds: 200);
  static const Duration slow = Duration(milliseconds: 320);

  static const Curve standard = Curves.easeOutCubic;
  static const Curve entrance = Curves.easeOutQuart;
}

/// Semantic brand colors. Used for accents that should *not* be derived
/// from the Material theme (status chips, charts, etc.). Always pair
/// foreground/background through one of the helper methods so contrast
/// is preserved across light and dark modes.
class BrandColors {
  BrandColors._();

  /// Privacy / "local-first" — the core brand promise. Cool blue.
  static const Color privacy = Color(0xFF3B82F6);

  /// Training / "your model" — earthy violet, distinct from privacy.
  static const Color training = Color(0xFF8B5CF6);

  /// Tools / MCP — warm amber, signals interactivity.
  static const Color tools = Color(0xFFF59E0B);

  /// Memory / context — calm teal, signals "remembered".
  static const Color memory = Color(0xFF14B8A6);

  /// Caution / quota — soft coral, never bright red.
  static const Color caution = Color(0xFFF97316);

  /// Returns a tinted background suitable for badges / chips on top of
  /// the current theme surface.
  static Color tint(Color base, BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return base.withValues(alpha: isDark ? 0.18 : 0.10);
  }
}

/// Predefined elevation rings — soft shadows that read on both light and
/// dark backgrounds. Use these instead of `Material(elevation: ...)`.
class Shadows {
  Shadows._();

  static const List<BoxShadow> resting = [
    BoxShadow(
      color: Color(0x14000000),
      blurRadius: 8,
      offset: Offset(0, 1),
    ),
  ];

  static const List<BoxShadow> raised = [
    BoxShadow(
      color: Color(0x1F000000),
      blurRadius: 16,
      offset: Offset(0, 4),
    ),
  ];

  static const List<BoxShadow> overlay = [
    BoxShadow(
      color: Color(0x33000000),
      blurRadius: 32,
      offset: Offset(0, 12),
    ),
  ];
}
