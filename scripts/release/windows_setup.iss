; ──────────────────────────────────────────────────────────────────────────
; Studiomc — Inno Setup installer for Windows
;
; Prerequisites:
;   - Flutter Windows release build at studiomc_app\build\windows\x64\runner\Release\
;   - Services bundle at services\dist\studiomc_services\
;
; Build the installer:
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" scripts\release\windows_setup.iss
; ──────────────────────────────────────────────────────────────────────────

#define MyAppName "Studiomc"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Studiomc"
#define MyAppURL "https://studiomc.app"
#define MyAppExeName "studiomc_app.exe"

[Setup]
AppId={{A1B2C3D4-E5F6-7890-ABCD-EF1234567890}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
DefaultDirName={autopf}\{#MyAppName}
DefaultGroupName={#MyAppName}
DisableProgramGroupPage=yes
; License shown during install
; LicenseFile=..\..\LICENSE
OutputDir=..\..\dist
OutputBaseFilename=Studiomc-{#MyAppVersion}-Windows-Setup
SetupIconFile=..\..\studiomc_app\windows\runner\resources\app_icon.ico
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
; Minimum Windows version (Windows 10 1809+)
MinVersion=10.0.17763

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
; Flutter app files
Source: "..\..\studiomc_app\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

; Python services bundle
Source: "..\..\services\dist\studiomc_services\*"; DestDir: "{app}\studiomc_services"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{group}\{cm:UninstallProgram,{#MyAppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "{cm:LaunchProgram,{#StringChange(MyAppName, '&', '&&')}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; Clean up logs and cache on uninstall
Type: filesandordirs; Name: "{localappdata}\studiomc"
