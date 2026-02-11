// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:studiomc_app/services/document_service.dart';

/// File attachment button + chip strip for the chat input area.
///
/// Opens a native file picker filtered to PDF, TXT, and MD.
/// Selected files appear as dismissible chips above the input bar.
/// Each picked file is automatically uploaded to the Document service
/// (POST http://127.0.0.1:8102/docs/upload) and the parent is notified
/// with the resulting document ID via [onDocumentUploaded].
class FileAttachButton extends StatefulWidget {
  /// Currently attached files (controlled externally when needed).
  final List<PlatformFile> attachedFiles;

  /// Called whenever the attachment list changes (add or remove).
  final ValueChanged<List<PlatformFile>> onFilesChanged;

  /// Called when a file has been successfully uploaded to the backend.
  /// Provides the document ID returned by the API.
  final ValueChanged<String>? onDocumentUploaded;

  /// Allowed extensions.
  final List<String> allowedExtensions;

  /// Maximum number of simultaneous attachments.
  final int maxFiles;

  const FileAttachButton({
    super.key,
    this.attachedFiles = const [],
    required this.onFilesChanged,
    this.onDocumentUploaded,
    this.allowedExtensions = const ['pdf', 'txt', 'md'],
    this.maxFiles = 5,
  });

  @override
  State<FileAttachButton> createState() => _FileAttachButtonState();
}

/// Upload state for a single attached file.
enum _UploadState { pending, uploading, done, error }

class _UploadEntry {
  final PlatformFile file;
  _UploadState state;
  String? documentId;
  String? errorMessage;

  _UploadEntry({
    required this.file,
    this.state = _UploadState.pending,
    this.documentId,
    this.errorMessage,
  });
}

class _FileAttachButtonState extends State<FileAttachButton> {
  late List<_UploadEntry> _entries;
  bool _picking = false;

  @override
  void initState() {
    super.initState();
    _entries = widget.attachedFiles
        .map((f) => _UploadEntry(file: f, state: _UploadState.done))
        .toList();
  }

  @override
  void didUpdateWidget(covariant FileAttachButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.attachedFiles != oldWidget.attachedFiles) {
      _entries = widget.attachedFiles
          .map((f) => _UploadEntry(file: f, state: _UploadState.done))
          .toList();
    }
  }

  List<PlatformFile> get _files => _entries.map((e) => e.file).toList();

  // ── Pick files ──

  Future<void> _pickFiles() async {
    if (_picking) return;
    setState(() => _picking = true);

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: widget.allowedExtensions,
        allowMultiple: true,
      );

      if (result != null && result.files.isNotEmpty) {
        for (final file in result.files) {
          if (_entries.length >= widget.maxFiles) break;
          // Avoid duplicates by name + size
          final isDuplicate = _entries.any(
            (e) => e.file.name == file.name && e.file.size == file.size,
          );
          if (!isDuplicate) {
            final entry = _UploadEntry(file: file);
            setState(() => _entries.add(entry));
            _uploadFile(entry);
          }
        }
        widget.onFilesChanged(List.unmodifiable(_files));
      }
    } catch (_) {
      // Silently handle — user cancelled or platform error
    } finally {
      setState(() => _picking = false);
    }
  }

  // ── Upload a file to the Document service ──

  Future<void> _uploadFile(_UploadEntry entry) async {
    if (entry.file.path == null) {
      setState(() {
        entry.state = _UploadState.error;
        entry.errorMessage = 'No file path available';
      });
      return;
    }

    setState(() => entry.state = _UploadState.uploading);

    try {
      final doc = await DocumentService().uploadDocument(entry.file.path!);
      if (!mounted) return;

      if (doc != null) {
        setState(() {
          entry.state = _UploadState.done;
          entry.documentId = doc.id;
        });
        widget.onDocumentUploaded?.call(doc.id);
      } else {
        setState(() {
          entry.state = _UploadState.error;
          entry.errorMessage = 'Upload returned null';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        entry.state = _UploadState.error;
        entry.errorMessage = e.toString();
      });
    }
  }

  // ── Retry a failed upload ──

  void _retryUpload(int index) {
    final entry = _entries[index];
    if (entry.state == _UploadState.error) {
      _uploadFile(entry);
    }
  }

  void _removeFile(int index) {
    setState(() => _entries.removeAt(index));
    widget.onFilesChanged(List.unmodifiable(_files));
  }

  void _clearAll() {
    setState(() => _entries.clear());
    widget.onFilesChanged(const []);
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Chip strip ──
        if (_entries.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                for (int i = 0; i < _entries.length; i++)
                  _FileChip(
                    entry: _entries[i],
                    onRemove: () => _removeFile(i),
                    onRetry: () => _retryUpload(i),
                  ),
                if (_entries.length > 1)
                  _ClearAllChip(onTap: _clearAll),
              ],
            ),
          ),

        // ── Attach button ──
        _AttachIconButton(
          onPressed: _entries.length >= widget.maxFiles ? null : _pickFiles,
          isPicking: _picking,
          fileCount: _entries.length,
          maxFiles: widget.maxFiles,
        ),
      ],
    );
  }
}

// ── File chip with upload state ──

class _FileChip extends StatelessWidget {
  final _UploadEntry entry;
  final VoidCallback onRemove;
  final VoidCallback onRetry;

  const _FileChip({
    required this.entry,
    required this.onRemove,
    required this.onRetry,
  });

  IconData _iconForExtension(String ext) {
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ext = entry.file.extension ?? '';
    final isUploading = entry.state == _UploadState.uploading;
    final isError = entry.state == _UploadState.error;
    final isDone = entry.state == _UploadState.done;

    final chipColor = isError
        ? theme.colorScheme.error
        : isDone
            ? const Color(0xFF10B981)
            : theme.colorScheme.primary;

    return Container(
      constraints: const BoxConstraints(maxWidth: 240),
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      decoration: BoxDecoration(
        color: chipColor.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: chipColor.withValues(alpha: 0.15),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Status icon / spinner
          if (isUploading)
            SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: theme.colorScheme.primary,
              ),
            )
          else
            Icon(
              isError
                  ? Icons.error_outline_rounded
                  : isDone
                      ? Icons.check_circle_outline_rounded
                      : _iconForExtension(ext),
              size: 16,
              color: chipColor,
            ),
          const SizedBox(width: 6),

          // File info
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.file.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                    color: theme.colorScheme.onSurface,
                  ),
                ),
                Text(
                  isUploading
                      ? 'Uploading…'
                      : isError
                          ? 'Failed — tap to retry'
                          : _formatBytes(entry.file.size),
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    color: isError
                        ? theme.colorScheme.error
                        : theme.colorScheme.secondary,
                  ),
                ),
              ],
            ),
          ),

          // Action button: retry or remove
          if (isError)
            SizedBox(
              width: 24,
              height: 24,
              child: IconButton(
                icon: const Icon(Icons.refresh_rounded, size: 14),
                onPressed: onRetry,
                padding: EdgeInsets.zero,
                style: IconButton.styleFrom(
                  foregroundColor: theme.colorScheme.error,
                ),
              ),
            ),
          SizedBox(
            width: 24,
            height: 24,
            child: IconButton(
              icon: const Icon(Icons.close_rounded, size: 14),
              onPressed: onRemove,
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
}

// ── Clear-all chip ──

class _ClearAllChip extends StatelessWidget {
  final VoidCallback onTap;

  const _ClearAllChip({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: theme.colorScheme.error.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(
            color: theme.colorScheme.error.withValues(alpha: 0.15),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.delete_sweep_outlined,
              size: 14,
              color: theme.colorScheme.error,
            ),
            const SizedBox(width: 4),
            Text(
              'Clear all',
              style: GoogleFonts.inter(
                fontSize: 9,
                fontWeight: FontWeight.w500,
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Attach icon button ──

class _AttachIconButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool isPicking;
  final int fileCount;
  final int maxFiles;

  const _AttachIconButton({
    this.onPressed,
    required this.isPicking,
    required this.fileCount,
    required this.maxFiles,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final atLimit = fileCount >= maxFiles;

    return Tooltip(
      message: atLimit
          ? 'Maximum $maxFiles files attached'
          : 'Attach file (PDF, TXT, MD)',
      child: SizedBox(
        width: 36,
        height: 36,
        child: Stack(
          children: [
            IconButton(
              icon: isPicking
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: theme.colorScheme.primary,
                      ),
                    )
                  : Icon(
                      Icons.attach_file_rounded,
                      size: 20,
                      color: atLimit
                          ? theme.colorScheme.secondary.withValues(alpha: 0.4)
                          : theme.colorScheme.secondary,
                    ),
              onPressed: onPressed,
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                foregroundColor: theme.colorScheme.secondary,
              ),
            ),
            // Badge showing count
            if (fileCount > 0)
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
                      '$fileCount',
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
}
