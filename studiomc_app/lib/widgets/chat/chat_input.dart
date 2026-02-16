// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:studiomc_app/services/database_service.dart';
import 'package:studiomc_app/services/bundled_inference_service.dart';
import 'package:studiomc_app/services/inference_service.dart';
import 'package:studiomc_app/services/local_inference_service.dart';
import 'package:studiomc_app/services/mobile_inference_service.dart';
import 'package:studiomc_app/services/training_service.dart';
import 'package:studiomc_app/widgets/chat/memory_toggle.dart';
import 'package:studiomc_app/utils/platform_utils.dart';

/// Perplexity-style floating input bar.
/// Rounded pill, attach + memory + model selector inside, send button on right.
/// Preset chips above the pill. Integrated file attachment with upload.
class ChatInput extends StatefulWidget {
  final ValueChanged<String> onSend;
  final VoidCallback? onAttach;

  /// Called when a file has been uploaded and a document ID is available.
  final ValueChanged<String>? onDocumentUploaded;

  /// Called when images are attached/changed (base64 encoded).
  final ValueChanged<List<String>>? onImagesChanged;

  /// Called when the user switches models.
  final ValueChanged<String>? onModelChanged;

  /// Current model name to display (if known by parent).
  final String? currentModelName;

  /// Whether memory is enabled (parent can provide initial state).
  final bool memoryEnabled;

  /// Called when memory toggle changes.
  final ValueChanged<bool>? onMemoryToggled;

  const ChatInput({
    super.key,
    required this.onSend,
    this.onAttach,
    this.onDocumentUploaded,
    this.onImagesChanged,
    this.onModelChanged,
    this.currentModelName,
    this.memoryEnabled = false,
    this.onMemoryToggled,
  });

  @override
  State<ChatInput> createState() => _ChatInputState();
}

class _ChatInputState extends State<ChatInput> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  bool _hasText = false;

  // ── File attachment state ──
  final List<_AttachedFile> _attachedFiles = [];
  bool _picking = false;
  static const _maxFiles = 5;
  static const _allowedExtensions = [
    'pdf', 'txt', 'md', 'docx', 'pptx', 'xlsx', 'json',
  ];

  // ── Image attachment state ──
  final List<_AttachedImage> _attachedImages = [];
  static const _maxImages = 4;

  // ── Model selector state ──
  List<Map<String, dynamic>> _models = [];
  String? _selectedModelId;
  String? _selectedModelName;
  bool _modelsLoading = false;

  // ── Active adapter indicator ──
  String? _activeAdapterName;

  @override
  void initState() {
    super.initState();
    _controller.addListener(() {
      final hasText = _controller.text.trim().isNotEmpty;
      if (hasText != _hasText) setState(() => _hasText = hasText);
    });
    // Enter = send, Shift+Enter = newline
    _focusNode.onKeyEvent = _handleKeyEvent;
    _selectedModelName = widget.currentModelName;
    _loadModels();
    _checkActiveAdapter();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent &&
        event.logicalKey == LogicalKeyboardKey.enter &&
        !HardwareKeyboard.instance.isShiftPressed) {
      _handleSend();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  void didUpdateWidget(covariant ChatInput oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.currentModelName != oldWidget.currentModelName &&
        widget.currentModelName != null) {
      _selectedModelName = widget.currentModelName;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── Load available models ──

  Future<void> _loadModels() async {
    setState(() => _modelsLoading = true);
    try {
      // ── Mobile: list downloaded on-device models ──
      if (isMobile) {
        final mobileInference = context.read<MobileInferenceService>();
        if (mounted) {
          setState(() {
            _models = mobileInference.downloadedModels
                .map((m) => <String, dynamic>{
                      'id': m.filename,
                      'name': mobileInference.humanName(m.filename),
                    })
                .toList();
            _modelsLoading = false;
            if (_models.isNotEmpty) {
              if (mobileInference.activeModel != null) {
                _selectedModelId = mobileInference.activeModel;
                _selectedModelName =
                    mobileInference.humanName(mobileInference.activeModel!);
              } else {
                _selectedModelId = _models.first['id'] as String?;
                _selectedModelName = _models.first['name'] as String?;
              }
            } else {
              _selectedModelName = 'No model';
            }
          });
        }
        return;
      }

      // ── Desktop paths ──
      final bundledInference = context.read<BundledInferenceService>();
      final localInference = context.read<LocalInferenceService>();

      // 1) Bundled engine models (GGUF files on disk)
      if (bundledInference.localModels.isNotEmpty) {
        if (mounted) {
          setState(() {
            _models = bundledInference.localModels
                .map((path) => <String, dynamic>{
                      'id': path,
                      'name': bundledInference.humanName(path),
                    })
                .toList();
            _modelsLoading = false;
            if (_selectedModelId == null && _models.isNotEmpty) {
              _selectedModelId = _models.first['id'] as String?;
              _selectedModelName = _models.first['name'] as String?;
            }
            if (widget.currentModelName != null &&
                widget.currentModelName!.isNotEmpty) {
              _selectedModelName = widget.currentModelName;
            }
          });
        }
        return;
      }

      // 2) Ollama models (optional)
      if (localInference.available && localInference.models.isNotEmpty) {
        if (mounted) {
          setState(() {
            _models = localInference.models
                .map((m) => <String, dynamic>{
                      'id': m.name,
                      'name': localInference.humanName(m.name),
                    })
                .toList();
            _modelsLoading = false;
            if (_selectedModelId == null && _models.isNotEmpty) {
              _selectedModelId = _models.first['id'] as String?;
              _selectedModelName = _models.first['name'] as String?;
            }
            if (widget.currentModelName != null &&
                widget.currentModelName!.isNotEmpty) {
              _selectedModelName = widget.currentModelName;
            }
          });
        }
        return;
      }

      // 3) Backend inference service fallback
      final models = await InferenceService().getModels();
      if (mounted) {
        setState(() {
          _models = models;
          _modelsLoading = false;
          if (_selectedModelId == null && models.isNotEmpty) {
            _selectedModelId = models.first['id'] as String?;
            _selectedModelName =
                models.first['name'] as String? ?? _selectedModelId;
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() => _modelsLoading = false);
      }
    }
  }

  // ── Check for active personalized adapter ──

  Future<void> _checkActiveAdapter() async {
    try {
      final training = TrainingService();
      final adapters = await training.getAdapters();

      if (!mounted) return;

      // Find the first active adapter
      String? adapterName;
      for (final a in adapters) {
        final isActive = a['is_active'] == true || a['is_active'] == 1;
        if (isActive) {
          adapterName = a['name'] as String?;
          break;
        }
      }

      if (mounted && adapterName != _activeAdapterName) {
        setState(() => _activeAdapterName = adapterName);
      }
    } catch (_) {
      // Training service unavailable — no adapter indicator
    }
  }

  /// Turn GGUF filename into a friendly name.
  String _humanName(String filename) {
    var name = filename
        .replaceAll('.gguf', '')
        .replaceAll('.bin', '')
        .replaceAll(RegExp(r'-q\d.*', caseSensitive: false), '')
        .replaceAll(RegExp(r'[-_]instruct', caseSensitive: false), '')
        .replaceAll(RegExp(r'[-_]chat', caseSensitive: false), '')
        .replaceAll('-', ' ')
        .replaceAll('_', ' ')
        .trim();
    name = name.split(' ').map((w) {
      if (w.isEmpty) return w;
      if (RegExp(r'^\d').hasMatch(w)) return w;
      return '${w[0].toUpperCase()}${w.substring(1)}';
    }).join(' ');
    return name.isEmpty ? filename : name;
  }

  // ── Send ──

  void _handleSend() {
    final text = _controller.text.trim();
    if (text.isEmpty && _attachedImages.isEmpty) return;
    widget.onSend(text.isNotEmpty ? text : 'What is in this image?');
    _controller.clear();
    // Clear images after send
    if (_attachedImages.isNotEmpty) {
      setState(() => _attachedImages.clear());
      widget.onImagesChanged?.call([]);
    }
    _focusNode.requestFocus();
  }

  // ── File picking + upload ──

  Future<void> _pickFiles() async {
    if (_picking) return;
    setState(() => _picking = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: _allowedExtensions,
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        for (final file in result.files) {
          if (_attachedFiles.length >= _maxFiles) break;
          final isDuplicate = _attachedFiles.any(
            (f) => f.file.name == file.name && f.file.size == file.size,
          );
          if (!isDuplicate) {
            final entry = _AttachedFile(file: file);
            setState(() => _attachedFiles.add(entry));
            _uploadFile(entry);
          }
        }
      }
    } catch (_) {
      // User cancelled or platform error
    } finally {
      setState(() => _picking = false);
    }
  }

  Future<void> _uploadFile(_AttachedFile entry) async {
    if (entry.file.path == null) {
      setState(() => entry.state = _FileUploadState.error);
      return;
    }

    setState(() => entry.state = _FileUploadState.uploading);

    try {
      final db = context.read<DatabaseService>();
      final file = File(entry.file.path!);
      final content = await file.readAsString();

      final docId = 'doc-${DateTime.now().millisecondsSinceEpoch}';
      final ext = entry.file.extension?.toLowerCase() ?? 'txt';
      final mime = ext == 'pdf'
          ? 'application/pdf'
          : ext == 'md'
              ? 'text/markdown'
              : 'text/plain';

      // Persist document metadata to SQLite
      await db.insertDocument({
        'id': docId,
        'filename': entry.file.name,
        'mime': mime,
        'bytes': entry.file.size,
        'sha256': '',
        'created_at': DateTime.now().toIso8601String(),
      });

      // Persist document text content
      await db.saveDocumentContent(docId, content);

      if (!mounted) return;

      setState(() {
        entry.state = _FileUploadState.done;
        entry.documentId = docId;
      });
      widget.onDocumentUploaded?.call(docId);
    } catch (_) {
      if (mounted) setState(() => entry.state = _FileUploadState.error);
    }
  }

  void _removeFile(int index) {
    setState(() => _attachedFiles.removeAt(index));
  }

  // ── Image picking ──

  /// Max dimension for API images (keeps payload reasonable for LLMs).
  static const _apiMaxDimension = 1536;

  /// Max dimension for thumbnail previews.
  static const _thumbMaxDimension = 150;

  Future<void> _pickImages() async {
    if (_picking) return;
    setState(() => _picking = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        for (final file in result.files) {
          if (_attachedImages.length >= _maxImages) break;
          if (file.path == null) continue;

          final isDuplicate = _attachedImages.any(
            (img) => img.file.name == file.name && img.file.size == file.size,
          );
          if (isDuplicate) continue;

          final bytes = await File(file.path!).readAsBytes();
          final ext = file.extension?.toLowerCase() ?? 'png';

          // Resize for API payload (max 1536px) to avoid OOM / huge payloads
          final apiBytes = await _resizeImage(bytes, _apiMaxDimension);
          final base64 = base64Encode(apiBytes);

          // Generate small thumbnail for display (max 150px)
          final thumbBytes = await _resizeImage(bytes, _thumbMaxDimension);

          setState(() {
            _attachedImages.add(_AttachedImage(
              file: file,
              base64Data: base64,
              mimeType: _mimeForImageExt(ext),
              thumbnail: thumbBytes,
            ));
          });
        }
        _notifyImagesChanged();
      }
    } catch (_) {
      // User cancelled or platform error
    } finally {
      setState(() => _picking = false);
    }
  }

  /// Resize an image to fit within [maxDimension] pixels on the longest side.
  /// Returns PNG-encoded bytes. If decoding fails, returns the original bytes.
  static Future<Uint8List> _resizeImage(
    Uint8List bytes,
    int maxDimension,
  ) async {
    try {
      final codec = await ui.instantiateImageCodec(
        bytes,
        targetWidth: maxDimension,
      );
      final frame = await codec.getNextFrame();
      final image = frame.image;
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData != null) return byteData.buffer.asUint8List();
    } catch (_) {
      // Decoding failed — return original bytes as fallback
    }
    return bytes;
  }

  void _removeImage(int index) {
    setState(() => _attachedImages.removeAt(index));
    _notifyImagesChanged();
  }

  void _notifyImagesChanged() {
    final dataUrls = _attachedImages
        .map((img) => 'data:${img.mimeType};base64,${img.base64Data}')
        .toList();
    widget.onImagesChanged?.call(dataUrls);
  }

  String _mimeForImageExt(String ext) {
    switch (ext) {
      case 'jpg':
      case 'jpeg':
        return 'image/jpeg';
      case 'png':
        return 'image/png';
      case 'gif':
        return 'image/gif';
      case 'webp':
        return 'image/webp';
      default:
        return 'image/png';
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Main input container — pill shape
          Container(
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: theme.dividerColor),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── Attached image thumbnails ──
                if (_attachedImages.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: SizedBox(
                      height: 72,
                      child: ListView.separated(
                        scrollDirection: Axis.horizontal,
                        itemCount: _attachedImages.length,
                        separatorBuilder: (_, __) => const SizedBox(width: 8),
                        itemBuilder: (_, i) => _buildImageThumb(theme, i),
                      ),
                    ),
                  ),

                // ── Attached file chips ──
                if (_attachedFiles.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                    child: Wrap(
                      spacing: 8,
                      runSpacing: 6,
                      children: [
                        for (int i = 0; i < _attachedFiles.length; i++)
                          _buildFileChip(theme, i),
                      ],
                    ),
                  ),

                // Text field
                TextField(
                  controller: _controller,
                  focusNode: _focusNode,
                  maxLines: 5,
                  minLines: 1,
                  textInputAction: TextInputAction.newline,
                  onSubmitted: (_) => _handleSend(),
                  style: GoogleFonts.inter(fontSize: 9, height: 1.4),
                  decoration: InputDecoration(
                    hintText:
                        'Ask anything. Type @ for sources and / for shortcuts.',
                    hintStyle: GoogleFonts.inter(
                      fontSize: 9,
                      color: theme.colorScheme.secondary,
                      fontWeight: FontWeight.w400,
                    ),
                    border: InputBorder.none,
                    enabledBorder: InputBorder.none,
                    focusedBorder: InputBorder.none,
                    contentPadding:
                        const EdgeInsets.fromLTRB(20, 16, 20, 4),
                    filled: false,
                  ),
                ),

                // Bottom row: attach, memory, spacer, model, send
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                  child: Row(
                    children: [
                      // Attach button
                      _buildAttachButton(theme),

                      const SizedBox(width: 4),

                      // Memory toggle
                      MemoryToggle(
                        isEnabled: widget.memoryEnabled,
                        onToggle: (value) {
                          widget.onMemoryToggled?.call(value);
                        },
                      ),

                      const Spacer(),

                      // Personalized model indicator
                      if (_activeAdapterName != null)
                        _buildPersonalizedIndicator(theme),

                      // Model selector
                      _buildModelSelector(theme),

                      const SizedBox(width: 4),

                      // Send — teal/primary circle like Perplexity
                      SizedBox(
                        width: 36,
                        height: 36,
                        child: IconButton.filled(
                          onPressed: (_hasText || _attachedImages.isNotEmpty)
                              ? _handleSend
                              : null,
                          icon: const Icon(
                            Icons.arrow_upward_rounded,
                            size: 18,
                          ),
                          style: IconButton.styleFrom(
                            backgroundColor:
                                (_hasText || _attachedImages.isNotEmpty)
                                    ? theme.colorScheme.primary
                                    : theme.colorScheme.secondary
                                        .withValues(alpha: 0.2),
                            foregroundColor: Colors.white,
                            disabledBackgroundColor: theme
                                .colorScheme.secondary
                                .withValues(alpha: 0.15),
                            disabledForegroundColor:
                                theme.colorScheme.secondary,
                            padding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Attach button ──

  Widget _buildAttachButton(ThemeData theme) {
    final totalAttachments = _attachedFiles.length + _attachedImages.length;

    return Tooltip(
      message: 'Attach image or file',
      child: SizedBox(
        width: 36,
        height: 36,
        child: Stack(
          children: [
            PopupMenuButton<String>(
              icon: _picking
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    )
                  : Icon(
                      Icons.add,
                      size: 20,
                      color: theme.colorScheme.secondary,
                    ),
              padding: EdgeInsets.zero,
              iconSize: 20,
              offset: const Offset(0, -100),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'image',
                  enabled: _attachedImages.length < _maxImages,
                  child: Row(
                    children: [
                      Icon(Icons.image_outlined, size: 18,
                        color: theme.colorScheme.onSurface),
                      const SizedBox(width: 8),
                      Text('Image',
                        style: GoogleFonts.inter(fontSize: 12)),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'file',
                  enabled: _attachedFiles.length < _maxFiles,
                  child: Row(
                    children: [
                      Icon(Icons.attach_file_rounded, size: 18,
                        color: theme.colorScheme.onSurface),
                      const SizedBox(width: 8),
                      Text('File',
                        style: GoogleFonts.inter(fontSize: 12)),
                    ],
                  ),
                ),
              ],
              onSelected: (value) {
                if (value == 'image') _pickImages();
                if (value == 'file') _pickFiles();
              },
            ),
            if (totalAttachments > 0)
              Positioned(
                right: 2,
                top: 2,
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: Text(
                      '$totalAttachments',
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onPrimary,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  // ── Personalized model indicator ──

  static const _kAdapterPurple = Color(0xFF8B5CF6);

  Widget _buildPersonalizedIndicator(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Tooltip(
        message: 'Using your personalized model',
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: _kAdapterPurple.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _kAdapterPurple.withValues(alpha: 0.2),
              width: 0.5,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome_rounded,
                  size: 10, color: _kAdapterPurple),
              const SizedBox(width: 3),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 80),
                child: Text(
                  _activeAdapterName ?? 'Personalized',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 8,
                    fontWeight: FontWeight.w500,
                    color: _kAdapterPurple,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Model selector dropdown ──

  Widget _buildModelSelector(ThemeData theme) {
    return PopupMenuButton<String>(
      onSelected: (modelId) {
        final model = _models.firstWhere(
          (m) => m['id'] == modelId,
          orElse: () => <String, dynamic>{},
        );
        setState(() {
          _selectedModelId = modelId;
          _selectedModelName =
              model['name'] as String? ?? modelId;
        });
        // Switch model on the active engine
        try {
          final bundledInference = context.read<BundledInferenceService>();
          if (bundledInference.available) {
            bundledInference.switchModel(modelId);
          } else {
            final localInference = context.read<LocalInferenceService>();
            localInference.selectModel(modelId);
          }
        } catch (_) {}
        widget.onModelChanged?.call(modelId);
      },
      tooltip: 'Select model',
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
      ),
      color: theme.scaffoldBackgroundColor,
      elevation: 4,
      position: PopupMenuPosition.over,
      enabled: _models.isNotEmpty || _selectedModelName != null,
      itemBuilder: (context) => _models.map((model) {
        final id = model['id'] as String? ?? '';
        final name = model['name'] as String? ?? id;
        final isActive = id == _selectedModelId;

        return PopupMenuItem<String>(
          value: id,
          height: 42,
          child: Row(
            children: [
              Icon(
                Icons.smart_toy_outlined,
                size: 16,
                color: isActive
                    ? theme.colorScheme.primary
                    : theme.colorScheme.secondary,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  name,
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    fontWeight:
                        isActive ? FontWeight.w500 : FontWeight.w400,
                    color: isActive
                        ? theme.colorScheme.primary
                        : theme.colorScheme.onSurface,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isActive)
                Icon(
                  Icons.check_rounded,
                  size: 16,
                  color: theme.colorScheme.primary,
                ),
            ],
          ),
        );
      }).toList(),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: theme.dividerColor),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_modelsLoading)
              SizedBox(
                width: 10,
                height: 10,
                child: CircularProgressIndicator(
                  strokeWidth: 1.5,
                  color: theme.colorScheme.secondary,
                ),
              ),
            if (_modelsLoading) const SizedBox(width: 4),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 100),
              child: Text(
                _selectedModelName ?? 'No model',
                style: GoogleFonts.inter(
                  fontSize: 9,
                  fontWeight: FontWeight.w400,
                  color: theme.colorScheme.onSurface,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(
              Icons.keyboard_arrow_down,
              size: 14,
              color: theme.colorScheme.secondary,
            ),
          ],
        ),
      ),
    );
  }

  // ── File chip (inline) ──

  Widget _buildFileChip(ThemeData theme, int index) {
    final entry = _attachedFiles[index];
    final isUploading = entry.state == _FileUploadState.uploading;
    final isError = entry.state == _FileUploadState.error;
    final isDone = entry.state == _FileUploadState.done;

    final chipColor = isError
        ? theme.colorScheme.error
        : isDone
            ? const Color(0xFF10B981)
            : theme.colorScheme.primary;

    return Container(
      constraints: const BoxConstraints(maxWidth: 200),
      padding: const EdgeInsets.fromLTRB(8, 4, 4, 4),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: chipColor.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isUploading)
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: chipColor,
              ),
            )
          else
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : isDone
                      ? Icons.check_circle_outline_rounded
                      : _iconForExt(entry.file.extension ?? ''),
              size: 14,
              color: chipColor,
            ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              entry.file.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: GoogleFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.onSurface,
              ),
            ),
          ),
          SizedBox(
            width: 22,
            height: 22,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, size: 12),
              onPressed: () => _removeFile(index),
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                foregroundColor: theme.colorScheme.secondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Image thumbnail ──

  Widget _buildImageThumb(ThemeData theme, int index) {
    final img = _attachedImages[index];

    return Stack(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.memory(
            img.thumbnail,
            width: 72,
            height: 72,
            fit: BoxFit.cover,
          ),
        ),
        Positioned(
          right: 2,
          top: 2,
          child: GestureDetector(
            onTap: () => _removeImage(index),
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                color: Colors.black54,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.close, size: 12, color: Colors.white),
            ),
          ),
        ),
      ],
    );
  }

  IconData _iconForExt(String ext) {
    switch (ext.toLowerCase()) {
      case 'pdf':
        return Icons.picture_as_pdf_rounded;
      case 'md':
        return Icons.code_rounded;
      case 'txt':
        return Icons.text_snippet_outlined;
      default:
        return Icons.insert_drive_file_outlined;
    }
  }
}

// ── Internal file state ──

enum _FileUploadState { pending, uploading, done, error }

class _AttachedFile {
  final PlatformFile file;
  _FileUploadState state;
  String? documentId;

  _AttachedFile({
    required this.file,
    this.state = _FileUploadState.pending,
    this.documentId,
  });
}

class _AttachedImage {
  final PlatformFile file;
  final String base64Data;
  final String mimeType;
  final Uint8List thumbnail;

  _AttachedImage({
    required this.file,
    required this.base64Data,
    required this.mimeType,
    required this.thumbnail,
  });
}
