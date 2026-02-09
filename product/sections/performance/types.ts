// Performance Dashboard Types

export type SpeedRating = 'fast' | 'ok' | 'slow' | 'painful';

export interface PerformanceSnapshot {
  speedRating: SpeedRating;
  explanation: string;
  suggestion: string | null;
  ttftMs: number;
  tokPerS: number;
  ramUsedMb: number;
  ramTotalMb: number;
  vramUsedMb: number | null;
  vramTotalMb: number | null;
  diskReadMbps: number;
  diskSaturation: number;
  modelLoadTimeMs: number;
  cacheHitRatio: number | null;
  oomEvents: number;
  autoTuneDecisions: AutoTuneDecision[];
}

export interface AutoTuneDecision {
  setting: string;
  value: string;
  reason: string;
  timestamp: string;
}

export interface PerformanceHistory {
  chatId: string;
  chatTitle: string;
  avgTokPerS: number;
  avgTtftMs: number;
  speedRating: SpeedRating;
  timestamp: string;
}

export interface PerformanceDashboardProps {
  snapshot: PerformanceSnapshot;
  history: PerformanceHistory[];
  showAdvanced: boolean;
  onToggleAdvanced: () => void;
  onExportDiagnostics: () => void;
  onSwitchModel: () => void;
}
