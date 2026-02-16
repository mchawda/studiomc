// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'package:flutter/material.dart';
import 'package:studiomc_app/models/app_models.dart';

class DocumentCard extends StatelessWidget {
  final Document document;
  final bool isGridView;
  final VoidCallback? onChat;
  final VoidCallback? onDelete;

  const DocumentCard({
    super.key,
    required this.document,
    this.isGridView = true,
    this.onChat,
    this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isReady = document.status == DocStatus.ready;
    final isProcessing = document.status == DocStatus.processing;
    final isError = document.status == DocStatus.error;

    if (isGridView) {
      return _buildGridCard(context, theme, isReady, isProcessing, isError);
    } else {
      return _buildListCard(context, theme, isReady, isProcessing, isError);
    }
  }

  Widget _buildGridCard(
    BuildContext context,
    ThemeData theme,
    bool isReady,
    bool isProcessing,
    bool isError,
  ) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        onTap: isReady ? onChat : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _buildTypeIcon(theme),
                  const Spacer(),
                  _buildStatusBadge(theme, isReady, isProcessing, isError),
                  if (onDelete != null) ...[
                    const SizedBox(width: 4),
                    SizedBox(
                      width: 28,
                      height: 28,
                      child: IconButton(
                        icon: Icon(Icons.delete_outline_rounded,
                            size: 16, color: theme.colorScheme.error.withValues(alpha: 0.6)),
                        onPressed: onDelete,
                        padding: EdgeInsets.zero,
                        tooltip: 'Delete',
                        style: IconButton.styleFrom(
                          foregroundColor: theme.colorScheme.error,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 12),
              Text(
                document.filename,
                style: theme.textTheme.titleMedium,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Icon(
                    Icons.description,
                    size: 14,
                    color: theme.colorScheme.secondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatFileSize(document.bytes),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Icon(
                    Icons.calendar_today,
                    size: 14,
                    color: theme.colorScheme.secondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _formatDate(document.createdAt),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.secondary,
                    ),
                  ),
                ],
              ),
              if (isProcessing) ...[
                const SizedBox(height: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Preparing knowledge...',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    LinearProgressIndicator(
                      value: document.processingProgress / 100,
                      backgroundColor: theme.colorScheme.surfaceContainerHighest,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        theme.colorScheme.tertiary,
                      ),
                    ),
                  ],
                ),
              ],
              if (isReady && document.chunkCount > 0) ...[
                const SizedBox(height: 8),
                Text(
                  '${document.chunkCount} chunks',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.secondary,
                  ),
                ),
              ],
              if (isReady && onChat != null) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onChat,
                    icon: const Icon(Icons.chat_bubble_outline, size: 16),
                    label: const Text('Chat with this document'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildListCard(
    BuildContext context,
    ThemeData theme,
    bool isReady,
    bool isProcessing,
    bool isError,
  ) {
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      margin: const EdgeInsets.only(bottom: 4),
      elevation: 0,
      child: InkWell(
        onTap: isReady ? onChat : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              _buildTypeIcon(theme),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      document.filename,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        Text(
                          _formatFileSize(document.bytes),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.secondary,
                            fontSize: 11,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          _formatDate(document.createdAt),
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.secondary,
                            fontSize: 11,
                          ),
                        ),
                        if (isReady && document.chunkCount > 0) ...[
                          const SizedBox(width: 8),
                          Text(
                            '${document.chunkCount} chunks',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.secondary,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (isProcessing) ...[
                      const SizedBox(height: 4),
                      LinearProgressIndicator(
                        value: document.processingProgress / 100,
                        backgroundColor: theme.colorScheme.surfaceContainerHighest,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          theme.colorScheme.tertiary,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              _buildStatusBadge(theme, isReady, isProcessing, isError),
              if (onDelete != null) ...[
                const SizedBox(width: 4),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    icon: Icon(Icons.delete_outline_rounded,
                        size: 16, color: theme.colorScheme.error.withValues(alpha: 0.5)),
                    onPressed: onDelete,
                    padding: EdgeInsets.zero,
                    tooltip: 'Delete',
                  ),
                ),
              ],
              if (isReady && onChat != null) ...[
                const SizedBox(width: 2),
                TextButton.icon(
                  onPressed: onChat,
                  icon: const Icon(Icons.chat_bubble_outline, size: 14),
                  label: const Text('Chat'),
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    textStyle: theme.textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTypeIcon(ThemeData theme) {
    Color iconColor;
    IconData iconData;

    switch (document.docType) {
      case DocType.pdf:
        iconColor = Colors.red;
        iconData = Icons.picture_as_pdf;
        break;
      case DocType.txt:
        iconColor = Colors.grey;
        iconData = Icons.text_snippet;
        break;
      case DocType.md:
        iconColor = Colors.blue;
        iconData = Icons.code;
        break;
      case DocType.docx:
        iconColor = Colors.blue.shade700;
        iconData = Icons.description;
        break;
      case DocType.pptx:
        iconColor = Colors.orange;
        iconData = Icons.slideshow;
        break;
      case DocType.xlsx:
        iconColor = Colors.green.shade700;
        iconData = Icons.table_chart;
        break;
      case DocType.json:
        iconColor = Colors.amber.shade700;
        iconData = Icons.data_object;
        break;
      case DocType.image:
        iconColor = Colors.purple;
        iconData = Icons.image;
        break;
    }

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: iconColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(iconData, color: iconColor, size: 24),
    );
  }

  Widget _buildStatusBadge(
    ThemeData theme,
    bool isReady,
    bool isProcessing,
    bool isError,
  ) {
    String label;
    Color color;

    if (isReady) {
      return const SizedBox.shrink();
    } else if (isProcessing) {
      label = 'Processing';
      color = Colors.amber;
    } else if (isError) {
      label = 'Error';
      color = Colors.red;
    } else {
      label = 'Uploading';
      color = theme.colorScheme.secondary;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: color.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(
          color: color,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  String _formatFileSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    } else {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
  }

  String _formatDate(DateTime date) {
    final now = DateTime.now();
    final difference = now.difference(date);

    if (difference.inDays == 0) {
      return 'Today';
    } else if (difference.inDays == 1) {
      return 'Yesterday';
    } else if (difference.inDays < 7) {
      return '${difference.inDays} days ago';
    } else {
      return '${date.month}/${date.day}/${date.year}';
    }
  }
}
