; Установщик nox.drive для Windows (Inno Setup 6).
; Собирается скриптом tool/build_windows_installer.ps1, который передаёт версию и пути:
;   ISCC.exe /DAppVersion=1.0.0 /DBuildNumber=1 /DVcRedistDir=<...\Microsoft.VC143.CRT> installer\nox_drive.iss
;
; Что важно:
; - Ставится без прав администратора в профиль пользователя (%LOCALAPPDATA%\Programs\nox.drive).
;   При желании в первом окне можно выбрать установку для всех пользователей.
; - Рядом с программой кладутся библиотеки Visual C++ (msvcp140, vcruntime140, vcruntime140_1):
;   без них на чистом Windows программа не запускается.
; - Перед установкой и удалением останавливается фоновый adb из папки программы, иначе он держит файлы.
; - AppId не менять: по нему Windows понимает, что это обновление той же программы.

#ifndef AppVersion
  #define AppVersion "1.0.0"
#endif
#ifndef BuildNumber
  #define BuildNumber "1"
#endif
#ifndef VcRedistDir
  #error Не передан VcRedistDir (папка Microsoft.VC143.CRT)
#endif

#define AppName "nox.drive"
#define AppExe "carwarehub_noxdrive.exe"
#define ReleaseDir "..\build\windows\x64\runner\Release"

[Setup]
AppId={{2A91AB66-59F2-470D-B402-EA4341765F73}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=nox.drive
VersionInfoVersion={#AppVersion}.{#BuildNumber}
VersionInfoProductName={#AppName}
VersionInfoDescription=Установщик {#AppName}
DefaultDirName={autopf}\{#AppName}
DefaultGroupName={#AppName}
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
UninstallDisplayName={#AppName}
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
CloseApplications=force
RestartApplications=no
OutputDir=Output
OutputBaseFilename=nox.drive-Setup-{#AppVersion}

[Languages]
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[InstallDelete]
; Чистая установка поверх старой версии: старые файлы движка и ресурсов не должны смешиваться с новыми.
Type: filesandordirs; Name: "{app}\data"

[Files]
Source: "{#ReleaseDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "{#VcRedistDir}\msvcp140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRedistDir}\vcruntime140.dll"; DestDir: "{app}"; Flags: ignoreversion
Source: "{#VcRedistDir}\vcruntime140_1.dll"; DestDir: "{app}"; Flags: ignoreversion

[Icons]
Name: "{group}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{group}\{cm:UninstallProgram,{#AppName}}"; Filename: "{uninstallexe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
Type: filesandordirs; Name: "{app}"

[Code]
// Останавливает фоновый adb из папки программы, чтобы он не держал файлы.
procedure StopAdb(const Dir: String);
var
  Code: Integer;
begin
  if FileExists(Dir + '\adb\adb.exe') then
    Exec(Dir + '\adb\adb.exe', 'kill-server', '', SW_HIDE, ewWaitUntilTerminated, Code);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  StopAdb(ExpandConstant('{app}'));
  Result := '';
end;

function InitializeUninstall(): Boolean;
begin
  StopAdb(ExpandConstant('{app}'));
  Result := True;
end;
