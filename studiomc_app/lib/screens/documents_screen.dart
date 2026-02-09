import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/services/api_client.dart';
import 'package:studiomc_app/services/database_service.dart';
import 'package:studiomc_app/services/document_service.dart';
import 'package:studiomc_app/widgets/documents/document_card.dart';
import 'package:studiomc_app/widgets/documents/collection_card.dart';
import 'package:studiomc_app/widgets/documents/upload_area.dart';
import 'package:go_router/go_router.dart';

class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({super.key});

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  bool _isGridView = true;
  bool _isLoading = true;
  String? _error;

  List<Document> _documents = [];
  List<Collection> _collections = [];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  Future<void> _loadData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    final db = context.read<DatabaseService>();
    final api = context.read<ApiClient>();

    try {
      if (api.isAvailable) {
        // Load from backend document service
        final docService = DocumentService();
        final results = await Future.wait([
          docService.listDocuments(),
          docService.listCollections(),
        ]);

        setState(() {
          _documents = results[0] as List<Document>;
          _collections = results[1] as List<Collection>;
          _isLoading = false;
        });
      } else {
        // Fall back to local DB
        await _loadFromDb(db);
        _error =
            'Backend not available. Showing locally cached documents.';
      }
    } catch (e) {
      // On backend error, try falling back to local DB
      try {
        await _loadFromDb(db);
        _error = 'Backend error. Showing locally cached documents.';
      } catch (dbError) {
        setState(() {
          _isLoading = false;
          _error = dbError.toString();
        });
      }
    }
  }

  Future<void> _loadFromDb(DatabaseService db) async {
    final docRows = await db.getDocuments();
    final colRows = await db.getCollections();

    setState(() {
      _documents = docRows
          .map((r) => Document(
                id: r['id'] as String,
                filename: r['filename'] as String? ?? '',
                mime: r['mime'] as String? ?? '',
                bytes: r['bytes'] as int? ?? 0,
                docType: _parseDocType(r['mime'] as String? ?? ''),
                status: DocStatus.ready,
                createdAt:
                    DateTime.tryParse(r['created_at'] as String? ?? '') ??
                        DateTime.now(),
              ))
          .toList();

      _collections = colRows
          .map((r) => Collection(
                id: r['id'] as String,
                name: r['name'] as String,
                createdAt:
                    DateTime.tryParse(r['created_at'] as String? ?? '') ??
                        DateTime.now(),
              ))
          .toList();

      _isLoading = false;
    });
  }

  DocType _parseDocType(String mime) {
    if (mime.contains('pdf')) return DocType.pdf;
    if (mime.contains('markdown')) return DocType.md;
    return DocType.txt;
  }

  Future<void> _handleUpload() async {
    final api = context.read<ApiClient>();
    final db = context.read<DatabaseService>();

    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['pdf', 'txt', 'md'],
        allowMultiple: true,
      );

      if (result == null || result.files.isEmpty) return;

      for (final file in result.files) {
        if (file.path == null) continue;

        final docId = 'doc-${DateTime.now().millisecondsSinceEpoch}';
        final mime = _getMimeType(file.extension ?? '');

        // Save to local DB immediately
        await db.insertDocument({
          'id': docId,
          'filename': file.name,
          'mime': mime,
          'bytes': file.size,
          'created_at': DateTime.now().toIso8601String(),
        });

        setState(() {
          _documents.insert(
            0,
            Document(
              id: docId,
              filename: file.name,
              mime: mime,
              bytes: file.size,
              docType: _getDocType(file.extension ?? ''),
              status: DocStatus.processing,
              processingProgress: 0,
              createdAt: DateTime.now(),
            ),
          );
        });

        // Upload to backend if available
        if (api.isAvailable) {
          try {
            final docService = DocumentService();
            final uploadedDoc =
                await docService.uploadDocument(file.path!);

            if (uploadedDoc != null) {
              // Trigger extraction
              await docService.extractDocument(uploadedDoc.id);
              // Trigger CLaRa ingestion
              await docService.claraIngest([uploadedDoc.id]);

              // Update local state with the backend doc
              if (mounted) {
                setState(() {
                  final idx = _documents.indexWhere((d) => d.id == docId);
                  if (idx != -1) {
                    _documents[idx] = uploadedDoc;
                  }
                });
              }
            }
          } catch (e) {
            if (mounted) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(
                    'Processing failed for ${file.name}: $e',
                    style: GoogleFonts.inter(fontSize: 9),
                  ),
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          }
        }
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${result.files.length} file${result.files.length > 1 ? 's' : ''} uploaded',
              style: GoogleFonts.inter(fontSize: 9),
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Upload failed: $e')),
        );
      }
    }
  }

  Future<void> _handleDeleteDocument(Document document) async {
    final theme = Theme.of(context);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text(
          'Delete document?',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 9,
            fontWeight: FontWeight.w500,
          ),
        ),
        content: Text(
          'This will permanently remove "${document.filename}" and all its chunks.',
          style: GoogleFonts.inter(
            fontSize: 9,
            color: theme.colorScheme.secondary,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: theme.colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      final api = context.read<ApiClient>();
      final db = context.read<DatabaseService>();

      if (api.isAvailable) {
        await DocumentService().deleteDocument(document.id);
      }
      await db.deleteDocument(document.id);

      setState(() {
        _documents.removeWhere((d) => d.id == document.id);
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              '${document.filename} deleted',
              style: GoogleFonts.inter(fontSize: 9),
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Delete failed: $e')),
        );
      }
    }
  }

  Future<void> _handleCreateCollection() async {
    final theme = Theme.of(context);
    final controller = TextEditingController();

    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
        ),
        title: Text(
          'New collection',
          style: GoogleFonts.spaceGrotesk(
            fontSize: 9,
            fontWeight: FontWeight.w500,
          ),
        ),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: GoogleFonts.inter(fontSize: 9),
          decoration: InputDecoration(
            hintText: 'Collection name',
            hintStyle: GoogleFonts.inter(
              fontSize: 9,
              color: theme.colorScheme.secondary,
            ),
            filled: true,
            fillColor: theme.colorScheme.surfaceContainerHighest,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: theme.dividerColor),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(color: theme.dividerColor),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: theme.colorScheme.primary,
                width: 1.5,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final v = controller.text.trim();
              Navigator.of(ctx).pop(v.isEmpty ? null : v);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );

    controller.dispose();

    if (name == null || name.isEmpty) return;

    try {
      final api = context.read<ApiClient>();

      if (api.isAvailable) {
        final collection = await DocumentService().createCollection(name);
        if (collection != null && mounted) {
          setState(() => _collections.insert(0, collection));
        }
      } else {
        // Save locally
        final db = context.read<DatabaseService>();
        final id = 'col-${DateTime.now().millisecondsSinceEpoch}';
        await db.insertCollection({
          'id': id,
          'name': name,
          'created_at': DateTime.now().toIso8601String(),
        });
        setState(() {
          _collections.insert(
            0,
            Collection(
              id: id,
              name: name,
              createdAt: DateTime.now(),
            ),
          );
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Collection "$name" created',
              style: GoogleFonts.inter(fontSize: 9),
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to create collection: $e')),
        );
      }
    }
  }

  String _getMimeType(String ext) {
    switch (ext.toLowerCase()) {
      case 'pdf':
        return 'application/pdf';
      case 'md':
        return 'text/markdown';
      case 'txt':
        return 'text/plain';
      default:
        return 'application/octet-stream';
    }
  }

  DocType _getDocType(String ext) {
    switch (ext.toLowerCase()) {
      case 'pdf':
        return DocType.pdf;
      case 'md':
        return DocType.md;
      default:
        return DocType.txt;
    }
  }

  void _handleDocumentChat(Document document) {
    // Navigate to chat in Docs mode with this document
    context.go('/chat');
  }

  void _handleCollectionChat(Collection collection) {
    context.go('/chat');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasDocuments = _documents.isNotEmpty;
    final hasCollections = _collections.isNotEmpty;
    final screenWidth = MediaQuery.of(context).size.width;
    final gridCrossAxisCount = screenWidth > 900 ? 4 : screenWidth > 600 ? 3 : 2;

    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: _loadData,
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Documents',
                          style: GoogleFonts.spaceGrotesk(
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurface,
                          )),
                      const SizedBox(height: 4),
                      Text('Upload and chat with your documents',
                          style: GoogleFonts.inter(
                            fontSize: 9,
                            color: theme.colorScheme.secondary,
                          )),
                    ],
                  ),
                ),
                // Refresh
                IconButton(
                  onPressed: _loadData,
                  icon: const Icon(Icons.refresh_rounded, size: 20),
                  tooltip: 'Refresh',
                  style: IconButton.styleFrom(
                    foregroundColor: theme.colorScheme.secondary,
                  ),
                ),
                if (hasDocuments) ...[
                  const SizedBox(width: 4),
                  IconButton(
                    icon: Icon(
                        _isGridView ? Icons.view_list : Icons.grid_view,
                        size: 20),
                    onPressed: () =>
                        setState(() => _isGridView = !_isGridView),
                    tooltip: _isGridView ? 'List view' : 'Grid view',
                    style: IconButton.styleFrom(
                      foregroundColor: theme.colorScheme.secondary,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 24),

            // Error banner
            if (_error != null) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.error.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: theme.colorScheme.error.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        size: 16, color: theme.colorScheme.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(_error!,
                          style: GoogleFonts.inter(
                            fontSize: 9,
                            color: theme.colorScheme.error,
                          )),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Upload area
            UploadArea(onUpload: _handleUpload),
            const SizedBox(height: 24),

            // Collections section
            if (hasCollections || true) ...[
              Row(
                children: [
                  Text('Collections',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                      )),
                  if (hasCollections) ...[
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color:
                            theme.colorScheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        '${_collections.length}',
                        style: GoogleFonts.inter(
                          fontSize: 9,
                          fontWeight: FontWeight.w500,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  TextButton.icon(
                    onPressed: _handleCreateCollection,
                    icon: const Icon(Icons.add, size: 16),
                    label: Text(
                      'New collection',
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.primary,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              if (hasCollections)
                SizedBox(
                  height: 180,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    itemCount: _collections.length,
                    itemBuilder: (context, index) {
                      return SizedBox(
                        width: 240,
                        child: Padding(
                          padding: EdgeInsets.only(
                              right:
                                  index < _collections.length - 1 ? 12 : 0),
                          child: CollectionCard(
                            collection: _collections[index],
                            onChat: () =>
                                _handleCollectionChat(_collections[index]),
                          ),
                        ),
                      );
                    },
                  ),
                )
              else
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 20),
                  child: Center(
                    child: Text(
                      'No collections yet. Create one to organize your documents.',
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        color: theme.colorScheme.secondary,
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
            ],

            // Documents section
            if (hasDocuments) ...[
              Row(
                children: [
                  Text('All Documents',
                      style: GoogleFonts.spaceGrotesk(
                        fontSize: 9,
                        fontWeight: FontWeight.w600,
                      )),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.primary.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${_documents.length}',
                      style: GoogleFonts.inter(
                        fontSize: 9,
                        fontWeight: FontWeight.w500,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
            ],

            // Document list/grid
            Expanded(
              child: hasDocuments
                  ? _isGridView
                      ? GridView.builder(
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: gridCrossAxisCount,
                            crossAxisSpacing: 12,
                            mainAxisSpacing: 12,
                            childAspectRatio: 0.8,
                          ),
                          itemCount: _documents.length,
                          itemBuilder: (context, index) {
                            final doc = _documents[index];
                            return _DocumentCardWithActions(
                              document: doc,
                              isGridView: true,
                              onChat: doc.status == DocStatus.ready
                                  ? () => _handleDocumentChat(doc)
                                  : null,
                              onDelete: () => _handleDeleteDocument(doc),
                            );
                          },
                        )
                      : ListView.builder(
                          itemCount: _documents.length,
                          itemBuilder: (context, index) {
                            final doc = _documents[index];
                            return _DocumentCardWithActions(
                              document: doc,
                              isGridView: false,
                              onChat: doc.status == DocStatus.ready
                                  ? () => _handleDocumentChat(doc)
                                  : null,
                              onDelete: () => _handleDeleteDocument(doc),
                            );
                          },
                        )
                  : _buildEmptyState(theme),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.upload_file_outlined,
              size: 56,
              color: theme.colorScheme.secondary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text('Upload your first document',
              style: GoogleFonts.spaceGrotesk(
                fontSize: 9,
                fontWeight: FontWeight.w600,
                color: theme.colorScheme.secondary,
              )),
          const SizedBox(height: 8),
          Text('Drag and drop PDF, TXT, or MD files',
              style: GoogleFonts.inter(
                fontSize: 9,
                color: theme.colorScheme.secondary.withValues(alpha: 0.6),
              )),
        ],
      ),
    );
  }
}

/// Wrapper around DocumentCard that adds a delete action via long-press menu.
class _DocumentCardWithActions extends StatelessWidget {
  final Document document;
  final bool isGridView;
  final VoidCallback? onChat;
  final VoidCallback onDelete;

  const _DocumentCardWithActions({
    required this.document,
    required this.isGridView,
    this.onChat,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return GestureDetector(
      onSecondaryTapUp: (details) {
        _showContextMenu(context, details.globalPosition);
      },
      onLongPress: () {
        _showContextMenu(context, Offset.zero);
      },
      child: DocumentCard(
        document: document,
        isGridView: isGridView,
        onChat: onChat,
      ),
    );
  }

  void _showContextMenu(BuildContext context, Offset position) {
    final theme = Theme.of(context);
    final RenderBox? overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    if (overlay == null) return;

    showMenu<String>(
      context: context,
      position: position == Offset.zero
          ? const RelativeRect.fromLTRB(100, 200, 100, 200)
          : RelativeRect.fromRect(
              position & const Size(1, 1),
              Offset.zero & overlay.size,
            ),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      color: theme.scaffoldBackgroundColor,
      elevation: 4,
      items: [
        if (onChat != null)
          PopupMenuItem(
            value: 'chat',
            height: 40,
            child: Row(
              children: [
                Icon(Icons.chat_outlined,
                    size: 16, color: theme.colorScheme.secondary),
                const SizedBox(width: 10),
                Text('Chat with this document',
                    style: GoogleFonts.inter(fontSize: 9)),
              ],
            ),
          ),
        PopupMenuItem(
          value: 'delete',
          height: 40,
          child: Row(
            children: [
              Icon(Icons.delete_outline_rounded,
                  size: 16, color: theme.colorScheme.error),
              const SizedBox(width: 10),
              Text('Delete',
                  style: GoogleFonts.inter(
                    fontSize: 9,
                    color: theme.colorScheme.error,
                  )),
            ],
          ),
        ),
      ],
    ).then((value) {
      if (value == 'chat') {
        onChat?.call();
      } else if (value == 'delete') {
        onDelete();
      }
    });
  }
}
