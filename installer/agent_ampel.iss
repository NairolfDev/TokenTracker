; Built in CI: iscc /DAppVersion=1.0.N installer\agent_ampel.iss  (run from the repo root)
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{6D0E3B7A-2F54-4B79-9A55-3C1F6E0B8A21}
AppName=AI Agent Ampel
AppVersion={#AppVersion}
AppPublisher=NairolfDev
DefaultDirName={autopf}\AgentAmpel
DefaultGroupName=AI Agent Ampel
OutputDir=..\dist
OutputBaseFilename=AgentAmpel-windows-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\agent_ampel.exe

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\AI Agent Ampel"; Filename: "{app}\agent_ampel.exe"
Name: "{autodesktop}\AI Agent Ampel"; Filename: "{app}\agent_ampel.exe"

[Run]
Filename: "{app}\agent_ampel.exe"; Description: "AI Agent Ampel starten"; Flags: nowait postinstall skipifsilent
