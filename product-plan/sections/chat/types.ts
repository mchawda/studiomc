// Chat Types

export type ChatMode = 'chat' | 'docs' | 'investigate';
export type MessageRole = 'system' | 'user' | 'assistant' | 'tool';
export type PresetMode = 'default' | 'writing' | 'coding' | 'tutor';
export type SpeedRating = 'fast' | 'ok' | 'slow' | 'painful';

export interface Chat {
  id: string;
  title: string;
  modelId: string;
  mode: PresetMode;
  createdAt: string;
  updatedAt: string;
  isPinned: boolean;
}

export interface Message {
  id: string;
  chatId: string;
  role: MessageRole;
  content: string;
  tokens: number;
  createdAt: string;
  parentMessageId: string | null;
  isStreaming?: boolean;
}

export interface Citation {
  documentId: string;
  filename: string;
  chunkIndex: number;
  snippet: string;
  relevanceScore: number;
}

export interface GroundednessInfo {
  percentGrounded: number;
  sources: Citation[];
  hasNoSource: boolean;
}

export interface InvestigateTraceStep {
  type: 'search' | 'grep' | 'open' | 'summarize' | 'table_extract' | 'cite';
  description: string;
  result: string;
  durationMs: number;
}

export interface ActiveModelInfo {
  modelId: string;
  name: string;
  speedRating: SpeedRating;
  tokPerS: number;
  ttftMs: number;
}

export interface ChatViewProps {
  chat: Chat;
  messages: Message[];
  activeModel: ActiveModelInfo;
  mode: ChatMode;
  groundedness: GroundednessInfo | null;
  investigateTrace: InvestigateTraceStep[];
  isStreaming: boolean;
  onSendMessage: (content: string, attachments?: File[]) => void;
  onRegenerate: (messageId: string) => void;
  onContinue: () => void;
  onEditMessage: (messageId: string, newContent: string) => void;
  onSetMode: (mode: ChatMode) => void;
  onSetPreset: (preset: PresetMode) => void;
  onExport: () => void;
}

export interface ConversationListProps {
  chats: Chat[];
  activeChatId: string | null;
  onSelectChat: (chatId: string) => void;
  onNewChat: () => void;
  onRenameChat: (chatId: string, newTitle: string) => void;
  onPinChat: (chatId: string) => void;
  onDeleteChat: (chatId: string) => void;
}
