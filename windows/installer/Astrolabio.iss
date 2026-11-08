; Instalador de Astrolabio para Windows 10/11 (Inno Setup 6).
; Se compila en GitHub Actions (.github/workflows/windows.yml) o en un PC con Inno Setup:
;   iscc /DAppVersion=1.3.0 /DPublishDir=..\publish\win-x64 Astrolabio.iss
#ifndef AppVersion
  #define AppVersion "1.3.0"
#endif
#ifndef PublishDir
  #define PublishDir "..\publish\win-x64"
#endif

[Setup]
AppId={{7C1B4A52-6E1F-4C2B-9F3A-2B9D3B9E5A10}
AppName=Astrolabio
AppVersion={#AppVersion}
AppPublisher=Víctor Casas
AppPublisherURL=https://github.com/vecasas/astrolabio
AppContact=vecasas@gmail.com
AppCopyright=© 2026 Víctor Casas
DefaultDirName={autopf}\Astrolabio
DefaultGroupName=Astrolabio
DisableProgramGroupPage=yes
OutputDir=..\publish
OutputBaseFilename=Astrolabio-{#AppVersion}-Windows-Setup
SetupIconFile=..\Astrolabio.App\Assets\Astrolabio.ico
UninstallDisplayIcon={app}\Astrolabio.exe
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.17763
PrivilegesRequiredOverridesAllowed=dialog

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "fr"; MessagesFile: "compiler:Languages\French.isl"
Name: "de"; MessagesFile: "compiler:Languages\German.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Astrolabio"; Filename: "{app}\Astrolabio.exe"
Name: "{autodesktop}\Astrolabio"; Filename: "{app}\Astrolabio.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Astrolabio.exe"; Description: "{cm:LaunchProgram,Astrolabio}"; Flags: nowait postinstall skipifsilent
