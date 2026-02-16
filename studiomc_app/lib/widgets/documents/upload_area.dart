// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

import '../../utils/platform_utils.dart';

class UploadArea extends StatefulWidget {
  final VoidCallback? onUpload;

  /// Called when files are dropped onto the area.
  final ValueChanged<List<String>>? onFilesDropped;

  const UploadArea({
    super.key,
    this.onUpload,
    this.onFilesDropped,
  });

  @override
  State<UploadArea> createState() => _UploadAreaState();
}

class _UploadAreaState extends State<UploadArea> {
  bool _isDragging = false;

  static const _allowedExtensions = {
    'pdf', 'txt', 'md', 'docx', 'pptx', 'xlsx', 'json',
    'png', 'jpg', 'jpeg', 'gif', 'webp',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final content = AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      width: double.infinity,
      padding: const EdgeInsets.all(32),
      decoration: BoxDecoration(
        color: _isDragging
            ? theme.colorScheme.primary.withValues(alpha: 0.08)
            : theme.colorScheme.surfaceContainerHighest
                .withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _isDragging
              ? theme.colorScheme.primary
              : theme.colorScheme.outline.withValues(alpha: 0.5),
          width: 2,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            _isDragging
                ? Icons.file_download_rounded
                : Icons.cloud_upload_outlined,
            size: 48,
            color: _isDragging
                ? theme.colorScheme.primary
                : theme.colorScheme.secondary,
          ),
          const SizedBox(height: 16),
          Text(
            isMobile
                ? 'Tap to upload files'
                : _isDragging
                    ? 'Drop files to upload'
                    : 'Drag and drop files here',
            style: theme.textTheme.titleMedium?.copyWith(
              color: _isDragging
                  ? theme.colorScheme.primary
                  : theme.colorScheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'PDF, DOCX, PPTX, XLSX, TXT, MD, JSON, or images',
            style: theme.textTheme.bodyMedium?.copyWith(
              color: theme.colorScheme.secondary,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: widget.onUpload,
            icon: const Icon(Icons.upload_file),
            label: const Text('Upload'),
            style: ElevatedButton.styleFrom(
              padding: const EdgeInsets.symmetric(
                horizontal: 24,
                vertical: 12,
              ),
            ),
          ),
        ],
      ),
    );

    // DropTarget (desktop_drop) only works on desktop. On mobile, just
    // show the upload button — users tap to pick files via file_picker.
    if (isMobile) return content;

    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragging = true),
      onDragExited: (_) => setState(() => _isDragging = false),
      onDragDone: (details) {
        setState(() => _isDragging = false);

        final paths = details.files
            .where((f) {
              final ext = f.path.split('.').last.toLowerCase();
              return _allowedExtensions.contains(ext);
            })
            .map((f) => f.path)
            .toList();

        if (paths.isEmpty) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Only PDF, TXT, and MD files are supported'),
              behavior: SnackBarBehavior.floating,
            ),
          );
          return;
        }

        widget.onFilesDropped?.call(paths);
      },
      child: content,
    );
  }
}
