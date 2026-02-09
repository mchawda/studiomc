// Investigate (LRE) Types

export type ToolType = 'search' | 'grep' | 'open' | 'summarize' | 'table_extract' | 'cite';
export type ReasoningMode = 'fast' | 'cited' | 'investigate';

export interface TraceStep {
  id: string;
  type: ToolType;
  description: string;
  input: string;
  result: string;
  durationMs: number;
  timestamp: string;
}

export interface BudgetStatus {
  toolCallsUsed: number;
  toolCallsMax: number;
  recursionDepthUsed: number;
  recursionDepthMax: number;
  tokensRetrieved: number;
  tokensMax: number;
  wallClockMs: number;
  wallClockMaxMs: number;
  exceeded: boolean;
  exceededReason: string | null;
}

export interface ReasoningRun {
  id: string;
  chatId: string;
  mode: ReasoningMode;
  trace: TraceStep[];
  budget: BudgetStatus;
  citations: Citation[];
  status: 'running' | 'completed' | 'exceeded' | 'no_evidence';
}

export interface Citation {
  documentId: string;
  filename: string;
  chunkIndex: number;
  span: string;
  snippet: string;
}

export interface InvestigatePanelProps {
  reasoningRun: ReasoningRun | null;
  isRunning: boolean;
  onRetryDifferentApproach: () => void;
  onBroadenSearch: () => void;
}
