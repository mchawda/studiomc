// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:studiomc_app/utils/platform_utils.dart' as platform;
import 'package:studiomc_app/widgets/chat/code_block_widget.dart';

/// Languages that should render as inline artifacts (with a Preview tab).
///
/// Anything else falls back to the standard [CodeBlockWidget].
const _previewableLangs = {
  'mermaid',
  'html',
  'svg',
  'jsx',
  'tsx',
  'react',
};

/// Returns true when the given language string should be rendered as an
/// inline artifact instead of a plain code block.
bool isPreviewableArtifact(String language) {
  return _previewableLangs.contains(language.toLowerCase().trim());
}

/// Inline artifact block — code on one tab, rendered preview on another.
///
/// Mermaid / SVG / HTML / React are written to a temp HTML file and opened
/// in the user's default browser. We don't embed a webview because:
///   * `webview_flutter` adds ~10MB and three platform plugin trees,
///   * the system browser already handles arbitrary HTML safely, and
///   * the artifact text never leaves disk: the temp file lives in the
///     app's local cache directory until the user clears it.
class ArtifactBlock extends StatefulWidget {
  final String code;
  final String language;

  const ArtifactBlock({
    super.key,
    required this.code,
    required this.language,
  });

  @override
  State<ArtifactBlock> createState() => _ArtifactBlockState();
}

class _ArtifactBlockState extends State<ArtifactBlock> {
  bool _showPreview = false;
  bool _opening = false;
  String? _error;

  String get _lang => widget.language.toLowerCase().trim();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final border = theme.dividerColor;

    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: border),
        borderRadius: BorderRadius.circular(10),
        color: isDark ? const Color(0xFF0D1117) : const Color(0xFFF6F8FA),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(context, theme),
          Padding(
            padding: const EdgeInsets.all(12),
            child: _showPreview
                ? _buildPreviewPanel(theme)
                : _buildSource(),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, ThemeData theme) {
    final fg = theme.colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: theme.dividerColor)),
      ),
      child: Row(
        children: [
          _LangChip(label: _lang.isEmpty ? 'artifact' : _lang),
          const SizedBox(width: 8),
          Text(
            'artifact',
            style: GoogleFonts.inter(
              fontSize: 11,
              color: fg.withValues(alpha: 0.55),
              fontWeight: FontWeight.w500,
            ),
          ),
          const Spacer(),
          _Tab(
            label: 'Source',
            active: !_showPreview,
            onTap: () => setState(() => _showPreview = false),
          ),
          _Tab(
            label: 'Preview',
            active: _showPreview,
            onTap: () => setState(() => _showPreview = true),
          ),
          const SizedBox(width: 6),
          _IconBtn(
            icon: Icons.copy_rounded,
            tooltip: 'Copy source',
            onTap: () {
              Clipboard.setData(ClipboardData(text: widget.code));
              ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                const SnackBar(
                  content: Text('Copied'),
                  duration: Duration(seconds: 1),
                ),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _buildSource() {
    return CodeBlockWidget(code: widget.code, language: widget.language);
  }

  Widget _buildPreviewPanel(ThemeData theme) {
    if (platform.isMobile) {
      return _previewPlaceholder(
        theme,
        icon: Icons.open_in_new_rounded,
        title: 'Preview not available on mobile',
        subtitle: 'Copy the source and open it in a desktop browser.',
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _previewPlaceholder(
          theme,
          icon: Icons.preview_rounded,
          title: 'Open ${_humanLang()} preview',
          subtitle: _previewSubtitle(),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            FilledButton.icon(
              onPressed: _opening ? null : _openInBrowser,
              icon: _opening
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.open_in_browser_rounded, size: 16),
              label: Text(_opening ? 'Opening…' : 'Open in browser'),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _saveToDisk,
              icon: const Icon(Icons.save_alt_rounded, size: 16),
              label: const Text('Save .html'),
            ),
          ],
        ),
        if (_error != null) ...[
          const SizedBox(height: 8),
          Text(
            _error!,
            style: GoogleFonts.inter(
              fontSize: 11,
              color: theme.colorScheme.error,
            ),
          ),
        ],
      ],
    );
  }

  Widget _previewPlaceholder(
    ThemeData theme, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    final fg = theme.colorScheme.onSurface;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Row(
        children: [
          Icon(icon, size: 22, color: fg.withValues(alpha: 0.7)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 11,
                    color: fg.withValues(alpha: 0.65),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _humanLang() => switch (_lang) {
        'mermaid' => 'Mermaid diagram',
        'html' => 'HTML',
        'svg' => 'SVG',
        'jsx' || 'tsx' || 'react' => 'React',
        _ => 'artifact',
      };

  String _previewSubtitle() => switch (_lang) {
        'mermaid' =>
          'Renders the diagram via the Mermaid runtime in a sandboxed page.',
        'html' || 'svg' =>
          'Opens the markup in a sandboxed page in your default browser.',
        'jsx' || 'tsx' || 'react' =>
          'Compiles JSX with Babel-standalone and renders into the page.',
        _ => 'Opens a rendered preview in your default browser.',
      };

  Future<void> _openInBrowser() async {
    setState(() {
      _opening = true;
      _error = null;
    });
    try {
      final file = await _writeArtifact();
      await _launchFile(file.path);
    } catch (e) {
      _error = 'Could not open preview: $e';
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  Future<void> _saveToDisk() async {
    try {
      final file = await _writeArtifact();
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('Saved to ${file.path}')),
      );
    } catch (e) {
      setState(() => _error = 'Save failed: $e');
    }
  }

  Future<File> _writeArtifact() async {
    final cacheRoot = await getTemporaryDirectory();
    final dir = Directory(p.join(cacheRoot.path, 'studiomc_artifacts'));
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final file = File(p.join(dir.path, 'artifact_$stamp.html'));
    await file.writeAsString(_buildHtml());
    return file;
  }

  /// Builds a self-contained HTML wrapper for the artifact. We keep the
  /// runtime dependencies (mermaid / babel / react) loaded from a CDN
  /// because (a) they're large and (b) they only run when the user
  /// explicitly opens a preview in their own browser. The artifact source
  /// text never leaves the local machine.
  String _buildHtml() {
    final body = widget.code;
    return switch (_lang) {
      'mermaid' => _mermaidHtml(body),
      'svg' => _wrapBare(body),
      'html' => body.contains('<html') ? body : _wrapBare(body),
      'jsx' || 'tsx' || 'react' => _reactHtml(body),
      _ => _wrapBare(body),
    };
  }

  String _wrapBare(String inner) => '''
<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Studiomc artifact</title>
<style>body{font:14px system-ui;margin:24px;color:#0d1117;background:#fff}</style>
</head><body>$inner</body></html>
''';

  String _mermaidHtml(String src) => '''
<!doctype html>
<html><head>
<meta charset="utf-8">
<title>Mermaid · Studiomc</title>
<style>body{font:14px system-ui;margin:24px}</style>
</head><body>
<pre class="mermaid">${_escape(src)}</pre>
<script type="module">
  import mermaid from "https://cdn.jsdelivr.net/npm/mermaid@11/dist/mermaid.esm.min.mjs";
  mermaid.initialize({ startOnLoad: true });
</script>
</body></html>
''';

  String _reactHtml(String src) => '''
<!doctype html>
<html><head>
<meta charset="utf-8">
<title>React · Studiomc</title>
<style>body{font:14px system-ui;margin:24px}#root{min-height:100px}</style>
<script crossorigin src="https://unpkg.com/react@18/umd/react.development.js"></script>
<script crossorigin src="https://unpkg.com/react-dom@18/umd/react-dom.development.js"></script>
<script src="https://unpkg.com/@babel/standalone/babel.min.js"></script>
</head><body>
<div id="root"></div>
<script type="text/babel" data-presets="react,typescript">
${src.contains("ReactDOM.createRoot") ? src : "$src\nconst __root = ReactDOM.createRoot(document.getElementById('root'));\n__root.render(typeof App !== 'undefined' ? <App /> : <pre>Define an `App` component to render.</pre>);"}
</script>
</body></html>
''';

  static String _escape(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;');

  /// Cross-platform "open this file in default app".
  Future<void> _launchFile(String path) async {
    final ProcessResult result;
    if (Platform.isMacOS) {
      result = await Process.run('open', [path]);
    } else if (Platform.isWindows) {
      result = await Process.run('cmd', ['/c', 'start', '', path]);
    } else if (Platform.isLinux) {
      result = await Process.run('xdg-open', [path]);
    } else {
      throw UnsupportedError('Preview not available on this platform.');
    }
    if (result.exitCode != 0) {
      throw Exception(result.stderr.toString().trim());
    }
  }
}

class _LangChip extends StatelessWidget {
  final String label;
  const _LangChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: GoogleFonts.jetBrainsMono(
          fontSize: 10,
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Tab extends StatelessWidget {
  final String label;
  final bool active;
  final VoidCallback onTap;
  const _Tab({required this.label, required this.active, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = theme.colorScheme.onSurface;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        child: Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 11,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? fg : fg.withValues(alpha: 0.55),
          ),
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  const _IconBtn({required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 14, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
        ),
      ),
    );
  }
}
