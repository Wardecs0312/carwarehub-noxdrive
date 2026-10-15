#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include "flutter_window.h"
#include "utils.h"

#include <cwchar>

// Single instance: a second copy keeps the files locked and breaks updates.
// A repeated launch brings the open window to front. After an in-app update
// (--after-update) the new copy waits for the old one to exit.
static HANDLE AcquireSingleInstance(const wchar_t* command_line) {
  HANDLE mutex = ::CreateMutexW(nullptr, TRUE, L"nox.drive.single-instance");
  if (mutex == nullptr || ::GetLastError() != ERROR_ALREADY_EXISTS) {
    return mutex;
  }
  if (command_line != nullptr &&
      std::wcsstr(command_line, L"--after-update") != nullptr) {
    DWORD r = ::WaitForSingleObject(mutex, 15000);
    if (r == WAIT_OBJECT_0 || r == WAIT_ABANDONED) return mutex;
  }
  HWND existing = ::FindWindowW(L"FLUTTER_RUNNER_WIN32_WINDOW", L"nox.drive");
  if (existing != nullptr) {
    if (::IsIconic(existing)) ::ShowWindow(existing, SW_RESTORE);
    ::SetForegroundWindow(existing);
  }
  ::CloseHandle(mutex);
  return nullptr;
}

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  HANDLE single_instance = AcquireSingleInstance(command_line);
  if (single_instance == nullptr) {
    return EXIT_SUCCESS;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"nox.drive", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
