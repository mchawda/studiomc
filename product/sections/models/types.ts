// Models Types

export type SpeedRating = 'fast' | 'ok' | 'slow' | 'painful';
export type ModelSource = 'hf' | 'local' | 'curated';
export type DownloadStatus = 'not_downloaded' | 'downloading' | 'paused' | 'verifying' | 'ready' | 'error';

export interface Model {
  id: string;
  name: string;
  source: ModelSource;
  sourceRef: string;
  paramsBillion: number;
  quant: string;
  diskBytes: number;
  arch: string;
  contextMax: number;
  speedRating: SpeedRating;
  predictedTokPerS: number;
  predictedTtftMs: number;
  sizeLabel: string;
  isActive: boolean;
  isRecommended: boolean;
  lastUsedAt: string | null;
  downloadStatus: DownloadStatus;
  downloadProgress?: number;
}

export interface ModelLibraryProps {
  recommended: Model | null;
  installed: Model[];
  discover: Model[];
  activeModelId: string | null;
  onSelectModel: (modelId: string) => void;
  onDownloadModel: (modelId: string) => void;
  onPauseDownload: (modelId: string) => void;
  onResumeDownload: (modelId: string) => void;
  onDeleteModel: (modelId: string) => void;
  onImportModel: (source: string) => void;
}

export interface GuardrailModalProps {
  model: Model;
  recommendedAlternative: Model;
  onUseRecommended: () => void;
  onRunAnyway: () => void;
  onDismiss: () => void;
}
