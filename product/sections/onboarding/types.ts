// Onboarding Types

export type OnboardingStep = 'welcome' | 'scan' | 'recommend' | 'download' | 'firstChat';

export interface HardwareScanResult {
  gpu: {
    name: string;
    vramMb: number;
    detected: boolean;
  } | null;
  ramMb: number;
  disk: {
    type: 'nvme' | 'sata' | 'unknown';
    readMbps: number;
  };
  cpuName: string;
  cpuCores: number;
  hwFingerprint: string;
}

export interface ModelRecommendation {
  modelId: string;
  name: string;
  sizeLabel: string;        // e.g. "compressed model, 4.2 GB"
  paramsBillion: number;
  diskBytes: number;
  predictedTokPerS: number;
  predictedTtftMs: number;
  speedRating: 'fast' | 'ok' | 'slow' | 'painful';
  explanation: string;       // plain-English, e.g. "This model will feel responsive."
  isRecommended: boolean;
}

export interface DownloadProgress {
  modelId: string;
  bytesDownloaded: number;
  bytesTotal: number;
  percentComplete: number;
  etaSeconds: number;
  status: 'downloading' | 'paused' | 'verifying' | 'complete' | 'error';
  errorMessage?: string;
}

export interface OnboardingProps {
  currentStep: OnboardingStep;
  scanResult: HardwareScanResult | null;
  recommendations: ModelRecommendation[];
  downloadProgress: DownloadProgress | null;
  onGetStarted: () => void;
  onHaveModel: () => void;
  onSelectModel: (modelId: string) => void;
  onStartDownload: (modelId: string) => void;
  onPauseDownload: () => void;
  onResumeDownload: () => void;
  onComplete: () => void;
}
