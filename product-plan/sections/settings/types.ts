// Settings Types

export interface AppSettings {
  privacy: PrivacySettings;
  appearance: AppearanceSettings;
  advanced: AdvancedSettings;
}

export interface PrivacySettings {
  localOnly: boolean;
  telemetryOptIn: boolean;
}

export interface AppearanceSettings {
  theme: 'light-blue' | 'dark-blue' | 'custom';
  customPrimaryColor: string | null;
  darkMode: boolean;
}

export interface AdvancedSettings {
  enabled: boolean;
  localApi: {
    enabled: boolean;
    port: number;
    apiKey: string;
  };
  frontierApis: FrontierApiConfig[];
  performance: {
    contextLength: number;
    batchSize: number;
    prefetchDepth: number;
    threadCount: number;
  };
  approvedFolders: string[];
}

export interface FrontierApiConfig {
  id: string;
  provider: string;
  apiKey: string;
  baseUrl: string;
  enabled: boolean;
}

export interface LicenseInfo {
  name: string;
  version: string;
  license: string;
  url: string;
}

export interface SettingsViewProps {
  settings: AppSettings;
  licenses: LicenseInfo[];
  appVersion: string;
  onUpdatePrivacy: (settings: PrivacySettings) => void;
  onUpdateAppearance: (settings: AppearanceSettings) => void;
  onToggleAdvanced: (enabled: boolean) => void;
  onUpdateAdvanced: (settings: AdvancedSettings) => void;
  onExportDiagnostics: () => void;
  onImportModel: (source: string) => void;
  onAddFolder: (path: string) => void;
  onRevokeFolder: (path: string) => void;
}
