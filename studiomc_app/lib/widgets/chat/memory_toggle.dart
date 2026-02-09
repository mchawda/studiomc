import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Compact toggle for local conversation memory.
///
/// When **on**, the app keeps a rolling summary of the conversation context.
/// A subtle indicator pulse shows when memory is active.
///
/// Sits in the chat input area alongside the attach button and model selector.
/// Persists the memory preference via [SharedPreferences].
class MemoryToggle extends StatefulWidget {
  /// Whether memory is currently enabled.
  final bool isEnabled;

  /// Called when the user toggles memory on or off.
  final ValueChanged<bool> onToggle;

  /// Optional: number of tokens currently held in memory (shown as context).
  final int? memoryTokens;

  /// SharedPreferences key used to persist the toggle.
  static const String prefKey = 'studiomc_memory_enabled';

  const MemoryToggle({
    super.key,
    required this.isEnabled,
    required this.onToggle,
    this.memoryTokens,
  });

  /// Read the persisted memory preference. Returns `true` by default.
  static Future<bool> loadPreference() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(prefKey) ?? true;
  }

  /// Save the memory preference.
  static Future<void> savePreference(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(prefKey, enabled);
  }

  @override
  State<MemoryToggle> createState() => _MemoryToggleState();
}

class _MemoryToggleState extends State<MemoryToggle>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      duration: const Duration(milliseconds: 2000),
      vsync: this,
    );
    _pulseAnimation = Tween<double>(begin: 0.4, end: 1.0).animate(
      CurvedAnimation(parent: _pulseController, curve: Curves.easeInOut),
    );

    if (widget.isEnabled) {
      _pulseController.repeat(reverse: true);
    }
  }

  @override
  void didUpdateWidget(covariant MemoryToggle oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isEnabled && !_pulseController.isAnimating) {
      _pulseController.repeat(reverse: true);
    } else if (!widget.isEnabled && _pulseController.isAnimating) {
      _pulseController.stop();
      _pulseController.reset();
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  void _handleToggle() {
    final newValue = !widget.isEnabled;
    // Persist to SharedPreferences
    MemoryToggle.savePreference(newValue);
    widget.onToggle(newValue);
  }

  String get _tooltip {
    if (!widget.isEnabled) {
      return 'Memory off — enable to keep conversation context';
    }
    if (widget.memoryTokens != null) {
      return 'Memory on — ${widget.memoryTokens} tokens in context';
    }
    return 'Memory on — conversation context is being tracked';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isOn = widget.isEnabled;

    return Tooltip(
      message: _tooltip,
      child: GestureDetector(
        onTap: _handleToggle,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: isOn
                ? theme.colorScheme.primary.withValues(alpha: 0.08)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: isOn
                  ? theme.colorScheme.primary.withValues(alpha: 0.2)
                  : theme.dividerColor,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Animated dot indicator
              _MemoryDot(
                isActive: isOn,
                pulseAnimation: _pulseAnimation,
                activeColor: theme.colorScheme.primary,
                inactiveColor: theme.colorScheme.secondary,
              ),
              const SizedBox(width: 5),

              // Label
              Text(
                'Memory',
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: isOn ? FontWeight.w500 : FontWeight.w400,
                  color: isOn
                      ? theme.colorScheme.primary
                      : theme.colorScheme.secondary,
                ),
              ),

              const SizedBox(width: 3),

              // On/Off indicator text
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: Text(
                  isOn ? 'on' : 'off',
                  key: ValueKey(isOn),
                  style: GoogleFonts.inter(
                    fontSize: 8,
                    fontWeight: FontWeight.w500,
                    color: isOn
                        ? theme.colorScheme.primary.withValues(alpha: 0.7)
                        : theme.colorScheme.secondary.withValues(alpha: 0.5),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Animated memory dot ──

class _MemoryDot extends StatelessWidget {
  final bool isActive;
  final Animation<double> pulseAnimation;
  final Color activeColor;
  final Color inactiveColor;

  const _MemoryDot({
    required this.isActive,
    required this.pulseAnimation,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  Widget build(BuildContext context) {
    if (!isActive) {
      return Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: inactiveColor.withValues(alpha: 0.3),
        ),
      );
    }

    return AnimatedBuilder(
      animation: pulseAnimation,
      builder: (context, child) {
        return Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: activeColor.withValues(alpha: pulseAnimation.value),
            boxShadow: [
              BoxShadow(
                color: activeColor.withValues(
                  alpha: pulseAnimation.value * 0.4,
                ),
                blurRadius: 6,
                spreadRadius: 1,
              ),
            ],
          ),
        );
      },
    );
  }
}
