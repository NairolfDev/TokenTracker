; Built in CI: iscc /DAppVersion=1.0.N installer\agentlights.iss  (run from the repo root)
#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif

[Setup]
AppId={{6D0E3B7A-2F54-4B79-9A55-3C1F6E0B8A21}
AppName=Agent Lights
AppVersion={#AppVersion}
AppPublisher=NairolfDev
DefaultDirName={autopf}\AgentLights
DefaultGroupName=Agent Lights
OutputDir=..\dist
OutputBaseFilename=AgentLights-windows-setup
Compression=lzma2
SolidCompression=yes
ArchitecturesInstallIn64BitMode=x64compatible
PrivilegesRequired=lowest
UninstallDisplayIcon={app}\agentlights.exe

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\Agent Lights"; Filename: "{app}\agentlights.exe"
Name: "{autodesktop}\Agent Lights"; Filename: "{app}\agentlights.exe"

[Run]
Filename: "{app}\agentlights.exe"; Description: "Agent Lights starten"; Flags: nowait postinstall skipifsilent
