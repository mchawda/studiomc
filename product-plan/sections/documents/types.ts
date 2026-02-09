// Documents Types

export type DocStatus = 'uploading' | 'processing' | 'ready' | 'error';
export type DocType = 'pdf' | 'txt' | 'md';
export type QualityMode = 'fast' | 'cited' | 'deep';

export interface Document {
  id: string;
  filename: string;
  mime: string;
  bytes: number;
  sha256: string;
  docType: DocType;
  status: DocStatus;
  processingProgress: number;
  chunkCount: number;
  createdAt: string;
}

export interface Collection {
  id: string;
  name: string;
  documentCount: number;
  createdAt: string;
}

export interface DocumentLibraryProps {
  documents: Document[];
  collections: Collection[];
  onUpload: (files: File[]) => void;
  onCreateCollection: (name: string) => void;
  onAddToCollection: (collectionId: string, documentIds: string[]) => void;
  onChatWithDocument: (documentId: string) => void;
  onChatWithCollection: (collectionId: string) => void;
  onDeleteDocument: (documentId: string) => void;
  onDeleteCollection: (collectionId: string) => void;
}

export interface DocumentDetailProps {
  document: Document;
  collections: Collection[];
  onChatWith: () => void;
  onAddToCollection: (collectionId: string) => void;
  onDelete: () => void;
}
