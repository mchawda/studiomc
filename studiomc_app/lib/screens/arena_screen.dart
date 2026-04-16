// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:studiomc_app/services/settings_service.dart';

/// Model Arena — side-by-side comparison of two models.
///
/// Same prompt sent to both models simultaneously. Users see
/// streaming responses side by side with per-model metrics
/// (TTFT, tok/s) and can vote for their preferred response.
class ArenaScreen extends StatefulWidget {
  const ArenaScreen({super.key});

  @override
  State<ArenaScreen> createState() => _ArenaScreenState();
}

class _ArenaScreenState extends State<ArenaScreen> {
  final _promptController = TextEditingController();
  final _scrollControllerA = ScrollController();
  final _scrollControllerB = ScrollController();

  List<Map<String, dynamic>> _availableModels = [];
  String? _modelA;
  String? _modelB;

  String _responseA = '';
  String _responseB = '';
  bool _streamingA = false;
  bool _streamingB = false;

  double _ttftA = 0;
  double _ttftB = 0;
  double _toksA = 0;
  double _toksB = 0;

  int? _vote; // null = no vote, 0 = A, 1 = B, 2 = tie

  List<Map<String, String>> _history = [];

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  @override
  void dispose() {
    _promptController.dispose();
    _scrollControllerA.dispose();
    _scrollControllerB.dispose();
    super.dispose();
  }

  Future<void> _loadModels() async {
    try {
      final resp = await http
          .get(Uri.parse('http://127.0.0.1:8100/v1/models'))
          .timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body);
        final data = body['data'] as List? ?? body as List? ?? [];
        if (mounted) {
          setState(() {
            _availableModels = List<Map<String, dynamic>>.from(data);
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _sendPrompt() async {
    final prompt = _promptController.text.trim();
    if (prompt.isEmpty || _modelA == null || _modelB == null) return;
    if (_modelA == _modelB) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pick two different models to compare')),
      );
      return;
    }

    setState(() {
      _responseA = '';
      _responseB = '';
      _streamingA = true;
      _streamingB = true;
      _ttftA = 0;
      _ttftB = 0;
      _toksA = 0;
      _toksB = 0;
      _vote = null;
    });

    _history.add({'role': 'user', 'content': prompt});
    _promptController.clear();

    _streamModel(_modelA!, isA: true);
    _streamModel(_modelB!, isA: false);
  }

  Future<void> _streamModel(String modelId, {required bool isA}) async {
    final messages = _history
        .map((m) => {'role': m['role'], 'content': m['content']})
        .toList();

    final t0 = DateTime.now();
    bool firstToken = true;

    try {
      final request = http.Request(
        'POST',
        Uri.parse('http://127.0.0.1:8100/v1/chat/completions'),
      );
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode({
        'model': modelId,
        'messages': messages,
        'stream': true,
      });

      final streamedResp = await http.Client().send(request);

      await for (final chunk in streamedResp.stream.transform(utf8.decoder)) {
        for (final line in chunk.split('\n')) {
          if (!line.startsWith('data: ')) continue;
          final data = line.substring(6).trim();
          if (data == '[DONE]') break;

          try {
            final json = jsonDecode(data);
            final delta = json['choices']?[0]?['delta']?['content'] ?? '';
            if (delta.isNotEmpty) {
              if (firstToken) {
                final ttft =
                    DateTime.now().difference(t0).inMilliseconds.toDouble();
                if (mounted) {
                  setState(() {
                    if (isA) {
                      _ttftA = ttft;
                    } else {
                      _ttftB = ttft;
                    }
                  });
                }
                firstToken = false;
              }
              if (mounted) {
                setState(() {
                  if (isA) {
                    _responseA += delta;
                  } else {
                    _responseB += delta;
                  }
                });
              }
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          if (isA) {
            _responseA += '\n[Error: $e]';
          } else {
            _responseB += '\n[Error: $e]';
          }
        });
      }
    }

    if (mounted) {
      final elapsed = DateTime.now().difference(t0).inMilliseconds;
      final response = isA ? _responseA : _responseB;
      final tokens = response.split(' ').length;
      final toks = elapsed > 0 ? tokens / (elapsed / 1000.0) : 0.0;

      setState(() {
        if (isA) {
          _streamingA = false;
          _toksA = toks;
        } else {
          _streamingB = false;
          _toksB = toks;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final width = MediaQuery.of(context).size.width;

    return Scaffold(
      body: Column(
        children: [
          // Header
          Container(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                Icon(Icons.compare_arrows_rounded,
                    color: theme.colorScheme.primary),
                const SizedBox(width: 12),
                Text(
                  'Model Arena',
                  style: GoogleFonts.spaceGrotesk(
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  'Compare models side by side',
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
          ),

          // Model selectors
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            child: Row(
              children: [
                Expanded(child: _buildModelSelector(theme, isA: true)),
                const SizedBox(width: 16),
                Text('vs', style: GoogleFonts.inter(
                  fontSize: 16, fontWeight: FontWeight.w600,
                  color: theme.colorScheme.secondary,
                )),
                const SizedBox(width: 16),
                Expanded(child: _buildModelSelector(theme, isA: false)),
              ],
            ),
          ),

          // Responses side by side
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: _buildResponsePane(theme, isA: true)),
                  const SizedBox(width: 16),
                  Expanded(child: _buildResponsePane(theme, isA: false)),
                ],
              ),
            ),
          ),

          // Voting bar
          if (_responseA.isNotEmpty &&
              _responseB.isNotEmpty &&
              !_streamingA &&
              !_streamingB)
            _buildVotingBar(theme),

          // Input bar
          Container(
            padding: const EdgeInsets.fromLTRB(24, 12, 24, 20),
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: theme.dividerColor)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _promptController,
                    decoration: InputDecoration(
                      hintText: 'Type a prompt to send to both models...',
                      hintStyle: GoogleFonts.inter(
                        fontSize: 14,
                        color: theme.colorScheme.secondary,
                      ),
                      filled: true,
                      fillColor: theme.colorScheme.surfaceContainerHighest,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 14,
                      ),
                    ),
                    style: GoogleFonts.inter(fontSize: 14),
                    onSubmitted: (_) => _sendPrompt(),
                  ),
                ),
                const SizedBox(width: 12),
                FilledButton.icon(
                  onPressed: (_streamingA || _streamingB) ? null : _sendPrompt,
                  icon: (_streamingA || _streamingB)
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.colorScheme.onPrimary,
                          ),
                        )
                      : const Icon(Icons.send_rounded, size: 18),
                  label: const Text('Send'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModelSelector(ThemeData theme, {required bool isA}) {
    final selected = isA ? _modelA : _modelB;
    final label = isA ? 'Model A' : 'Model B';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: selected != null
              ? theme.colorScheme.primary.withValues(alpha: 0.3)
              : theme.dividerColor,
        ),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: selected,
          isExpanded: true,
          hint: Text(label, style: GoogleFonts.inter(
            fontSize: 13, color: theme.colorScheme.secondary,
          )),
          style: GoogleFonts.inter(
            fontSize: 13, color: theme.colorScheme.onSurface,
          ),
          dropdownColor: theme.scaffoldBackgroundColor,
          borderRadius: BorderRadius.circular(12),
          items: _availableModels.map((m) {
            final id = m['id'] as String? ?? '';
            final name = m['name'] as String? ?? id;
            final backend = m['backend'] as String? ?? '';
            return DropdownMenuItem(
              value: id,
              child: Row(
                children: [
                  Expanded(
                    child: Text(name, overflow: TextOverflow.ellipsis),
                  ),
                  if (backend.isNotEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        backend,
                        style: GoogleFonts.inter(
                          fontSize: 10,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                ],
              ),
            );
          }).toList(),
          onChanged: (v) => setState(() {
            if (isA) {
              _modelA = v;
            } else {
              _modelB = v;
            }
          }),
        ),
      ),
    );
  }

  Widget _buildResponsePane(ThemeData theme, {required bool isA}) {
    final response = isA ? _responseA : _responseB;
    final streaming = isA ? _streamingA : _streamingB;
    final model = isA ? _modelA : _modelB;
    final ttft = isA ? _ttftA : _ttftB;
    final toks = isA ? _toksA : _toksB;
    final sc = isA ? _scrollControllerA : _scrollControllerB;
    final label = isA ? 'A' : 'B';

    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Model label + metrics
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              border: Border(bottom: BorderSide(color: theme.dividerColor)),
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(16)),
            ),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: isA
                        ? theme.colorScheme.primary
                        : theme.colorScheme.tertiary,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Center(
                    child: Text(
                      label,
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    model ?? 'Select model',
                    style: GoogleFonts.inter(
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (ttft > 0)
                  _metricBadge(theme, 'TTFT', '${ttft.toStringAsFixed(0)}ms'),
                if (toks > 0) ...[
                  const SizedBox(width: 6),
                  _metricBadge(
                      theme, 'tok/s', toks.toStringAsFixed(1)),
                ],
                if (streaming)
                  Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Response body
          Expanded(
            child: response.isEmpty && !streaming
                ? Center(
                    child: Text(
                      model == null
                          ? 'Select a model above'
                          : 'Waiting for prompt...',
                      style: GoogleFonts.inter(
                        fontSize: 13,
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                  )
                : SingleChildScrollView(
                    controller: sc,
                    padding: const EdgeInsets.all(16),
                    child: SelectableText(
                      response,
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        height: 1.6,
                      ),
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _metricBadge(ThemeData theme, String label, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label: $value',
        style: GoogleFonts.jetBrainsMono(
          fontSize: 10,
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  Widget _buildVotingBar(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            'Which response is better?',
            style: GoogleFonts.inter(
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 16),
          _voteButton(theme, 'A is better', 0),
          const SizedBox(width: 8),
          _voteButton(theme, 'Tie', 2),
          const SizedBox(width: 8),
          _voteButton(theme, 'B is better', 1),
        ],
      ),
    );
  }

  Widget _voteButton(ThemeData theme, String label, int value) {
    final selected = _vote == value;
    return OutlinedButton(
      onPressed: () => setState(() => _vote = value),
      style: OutlinedButton.styleFrom(
        backgroundColor: selected
            ? theme.colorScheme.primary.withValues(alpha: 0.1)
            : null,
        side: BorderSide(
          color: selected
              ? theme.colorScheme.primary
              : theme.dividerColor,
        ),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
      child: Text(
        label,
        style: GoogleFonts.inter(
          fontSize: 12,
          fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
          color: selected
              ? theme.colorScheme.primary
              : theme.colorScheme.onSurface,
        ),
      ),
    );
  }
}
