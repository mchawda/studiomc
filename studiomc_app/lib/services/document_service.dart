// SPDX-License-Identifier: LicenseRef-NIA-Proprietary
// Copyright 2024-2026 NIA Pte Ltd. All rights reserved.

import 'dart:async';

import 'package:studiomc_app/models/app_models.dart';
import 'package:studiomc_app/services/api_client.dart';

/// A single text chunk extracted from a document.
class DocChunk {
  final String id;
  final String documentId;
  final int chunkIndex;
  final String text;
  final int tokenCount;
  final double? relevanceScore;

  const DocChunk({
    required this.id,
    required this.documentId,
    required this.chunkIndex,
    required this.text,
    required this.tokenCount,
    this.relevanceScore,
  });

  factory DocChunk.fromJson(Map<String, dynamic> json) {
    return DocChunk(
      id: json['id'] as String? ?? '',
      documentId: json['document_id'] as String? ?? '',
      chunkIndex: json['chunk_index'] as int? ?? 0,
      text: json['text'] as String? ?? '',
      tokenCount: json['token_count'] as int? ?? 0,
      relevanceScore: (json['relevance_score'] as num?)?.toDouble(),
    );
  }
}

/// Communicates with the Document service (port 8102).
///
/// Handles document upload, listing, deletion, chunk retrieval,
/// collection CRUD, and collection-level semantic queries.
class DocumentService {
  static DocumentService? _instance;
  final ApiClient _api;

  DocumentService._(this._api);

  factory DocumentService() {
    _instance ??= DocumentService._(
      ApiClient(
        baseUrl: ServiceUrls.documents,
        // Uploads can be large — use extended timeout.
        downloadTimeout: const Duration(seconds: 180),
      ),
    );
    return _instance!;
  }

  // ── Documents ─────────────────────────────────────────────────────

  /// Upload a document from the local filesystem at [filePath].
  /// Returns the created [Document], or `null` on failure.
  Future<Document?> uploadDocument(String filePath) async {
    try {
      final data = await _api.uploadFile('/docs/upload', filePath, 'file');
      return _parseDocument(data);
    } catch (e) {
      logService('document', 'Upload failed', error: e);
      return null;
    }
  }

  /// List all uploaded documents.
  Future<List<Document>> listDocuments() async {
    try {
      final items = await _api.getList('/docs');
      return items
          .map((e) => _parseDocument(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      logService('document', 'Failed to list documents', error: e);
      return [];
    }
  }

  /// Delete a document by its ID.
  Future<bool> deleteDocument(String docId) async {
    try {
      await _api.delete('/docs/$docId');
      return true;
    } catch (e) {
      logService('document', 'Failed to delete doc $docId', error: e);
      return false;
    }
  }

  /// Get all text chunks for a document.
  Future<List<DocChunk>> getChunks(String docId) async {
    try {
      final items = await _api.getList('/docs/$docId/chunks');
      return items
          .map((e) => DocChunk.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      logService('document', 'Failed to get chunks for $docId', error: e);
      return [];
    }
  }

  // ── Collections ───────────────────────────────────────────────────

  /// Create a new collection with the given [name].
  /// Returns the created [Collection], or `null` on failure.
  Future<Collection?> createCollection(String name) async {
    try {
      final data =
          await _api.post('/collections', body: {'name': name});
      return _parseCollection(data);
    } catch (e) {
      logService('document', 'Failed to create collection', error: e);
      return null;
    }
  }

  /// List all collections.
  Future<List<Collection>> listCollections() async {
    try {
      final items = await _api.getList('/collections');
      return items
          .map((e) => _parseCollection(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      logService('document', 'Failed to list collections', error: e);
      return [];
    }
  }

  /// Add a document to a collection.
  Future<bool> addDocToCollection(String collectionId, String docId) async {
    try {
      await _api.post('/collections/$collectionId/docs',
          body: {'document_id': docId});
      return true;
    } catch (e) {
      logService('document', 'Failed to add doc to collection', error: e);
      return false;
    }
  }

  /// Run a semantic query against a collection.
  /// Returns matching [DocChunk]s ranked by relevance.
  Future<List<DocChunk>> queryCollection(
    String collectionId,
    String query,
  ) async {
    try {
      final data = await _api.post(
        '/collections/$collectionId/query',
        body: {'query': query},
      );
      final results = data['results'] as List<dynamic>? ?? [];
      return results
          .map((e) => DocChunk.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (e) {
      logService('document', 'Collection query failed', error: e);
      return [];
    }
  }

  // ── Search ──────────────────────────────────────────────────────────

  /// Search across all document content via the backend.
  /// Returns a list of matching document chunks with snippets.
  Future<List<Map<String, dynamic>>> searchDocuments(String query,
      {int limit = 50}) async {
    try {
      final encoded = Uri.encodeQueryComponent(query);
      final data = await _api.get(
        '/documents/search?q=$encoded&limit=$limit',
      );
      final results = data['results'] as List<dynamic>? ?? [];
      return results.cast<Map<String, dynamic>>();
    } catch (e) {
      logService('document', 'Document search failed', error: e);
      return [];
    }
  }

  // ── Parsing helpers ───────────────────────────────────────────────

  Document _parseDocument(Map<String, dynamic> json) {
    return Document(
      id: json['id'] as String? ?? '',
      filename: json['filename'] as String? ?? '',
      mime: json['mime'] as String? ?? 'application/octet-stream',
      bytes: json['bytes'] as int? ?? 0,
      sha256: json['sha256'] as String?,
      docType: _parseDocType(json['doc_type'] as String?),
      status: _parseDocStatus(json['status'] as String?),
      processingProgress:
          (json['processing_progress'] as num? ?? 0).toDouble(),
      chunkCount: json['chunk_count'] as int? ?? 0,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  Collection _parseCollection(Map<String, dynamic> json) {
    return Collection(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      documentCount: json['document_count'] as int? ?? 0,
      createdAt: DateTime.tryParse(json['created_at'] as String? ?? '') ??
          DateTime.now(),
    );
  }

  /// Trigger text extraction for an uploaded document.
  Future<bool> extractDocument(String docId) async {
    try {
      await _api.post('/docs/extract/$docId');
      return true;
    } catch (e) {
      logService('documents', 'Extract failed for $docId', error: e);
      return false;
    }
  }

  /// Trigger CLaRa ingestion for a list of document IDs.
  Future<bool> claraIngest(List<String> docIds) async {
    try {
      // Call CLaRa service directly
      final claraApi = ApiClient(baseUrl: ServiceUrls.clara);
      await claraApi.post('/clara/ingest', body: {
        'collection_id': 'default',
        'document_ids': docIds,
      });
      return true;
    } catch (e) {
      logService('documents', 'CLaRa ingest failed', error: e);
      return false;
    }
  }

  DocType _parseDocType(String? s) {
    switch (s) {
      case 'pdf':
        return DocType.pdf;
      case 'txt':
        return DocType.txt;
      case 'md':
        return DocType.md;
      case 'docx':
        return DocType.docx;
      case 'pptx':
        return DocType.pptx;
      case 'xlsx':
        return DocType.xlsx;
      case 'json':
        return DocType.json;
      case 'image':
      case 'png':
      case 'jpg':
      case 'jpeg':
        return DocType.image;
      default:
        return DocType.txt;
    }
  }

  DocStatus _parseDocStatus(String? s) {
    switch (s) {
      case 'uploading':
        return DocStatus.uploading;
      case 'processing':
        return DocStatus.processing;
      case 'ready':
        return DocStatus.ready;
      case 'error':
        return DocStatus.error;
      default:
        return DocStatus.uploading;
    }
  }
}
