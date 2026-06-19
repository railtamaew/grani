#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <shellapi.h>
#include <windows.h>

#include <cstring>
#include <cstdlib>
#include <optional>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

std::optional<std::wstring> GetEnvPath(const wchar_t* name) {
  wchar_t buffer[MAX_PATH * 4];
  const DWORD written = GetEnvironmentVariableW(name, buffer, ARRAYSIZE(buffer));
  if (written == 0 || written >= ARRAYSIZE(buffer)) {
    return std::nullopt;
  }
  return std::wstring(buffer, written);
}

bool FileExists(const std::wstring& path) {
  const DWORD attrs = GetFileAttributesW(path.c_str());
  return attrs != INVALID_FILE_ATTRIBUTES &&
         (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0;
}

std::wstring GetExeDir() {
  wchar_t path[MAX_PATH * 4];
  const DWORD size = GetModuleFileNameW(nullptr, path, ARRAYSIZE(path));
  std::wstring result(path, size);
  const size_t slash = result.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return L".";
  }
  return result.substr(0, slash);
}

std::wstring GetExePath() {
  wchar_t path[MAX_PATH * 4];
  const DWORD size = GetModuleFileNameW(nullptr, path, ARRAYSIZE(path));
  return std::wstring(path, size);
}

void EnsureDesktopShortcut() {
  PWSTR desktop_path_raw = nullptr;
  if (FAILED(SHGetKnownFolderPath(FOLDERID_Desktop, 0, nullptr,
                                  &desktop_path_raw))) {
    return;
  }

  const std::wstring shortcut_path =
      std::wstring(desktop_path_raw) + L"\\GRANI.lnk";
  CoTaskMemFree(desktop_path_raw);

  if (FileExists(shortcut_path)) {
    return;
  }

  IShellLinkW* shell_link = nullptr;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                              IID_IShellLinkW,
                              reinterpret_cast<void**>(&shell_link)))) {
    return;
  }

  const std::wstring exe_path = GetExePath();
  shell_link->SetPath(exe_path.c_str());
  shell_link->SetWorkingDirectory(GetExeDir().c_str());
  shell_link->SetIconLocation(exe_path.c_str(), 0);
  shell_link->SetDescription(L"GRANI VPN");

  IPersistFile* persist_file = nullptr;
  if (SUCCEEDED(shell_link->QueryInterface(IID_IPersistFile,
                                           reinterpret_cast<void**>(
                                               &persist_file)))) {
    persist_file->Save(shortcut_path.c_str(), TRUE);
    persist_file->Release();
  }
  shell_link->Release();
}

bool IsRunningAsAdmin() {
  SID_IDENTIFIER_AUTHORITY nt_authority = SECURITY_NT_AUTHORITY;
  PSID administrators_group = nullptr;
  const BOOL allocated = AllocateAndInitializeSid(
      &nt_authority, 2, SECURITY_BUILTIN_DOMAIN_RID,
      DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0, &administrators_group);
  if (!allocated) {
    return false;
  }

  BOOL is_member = FALSE;
  const BOOL ok = CheckTokenMembership(nullptr, administrators_group, &is_member);
  FreeSid(administrators_group);
  return ok && is_member == TRUE;
}

bool RelaunchElevatedIfNeeded() {
  if (IsRunningAsAdmin()) {
    return false;
  }

  SHELLEXECUTEINFOW execute_info{};
  execute_info.cbSize = sizeof(execute_info);
  execute_info.fMask = SEE_MASK_NOCLOSEPROCESS;
  execute_info.lpVerb = L"runas";
  execute_info.lpFile = GetExePath().c_str();
  execute_info.lpDirectory = GetExeDir().c_str();
  execute_info.nShow = SW_SHOWNORMAL;

  if (!ShellExecuteExW(&execute_info)) {
    return false;
  }
  if (execute_info.hProcess) {
    CloseHandle(execute_info.hProcess);
  }
  return true;
}

std::optional<std::wstring> ResolveTunnelDllPath() {
  if (auto env = GetEnvPath(L"GRANI_AWG_TUNNEL_DLL")) {
    if (FileExists(*env)) {
      return env;
    }
  }

  const std::wstring bundled =
      GetExeDir() + L"\\data\\flutter_assets\\bin\\amneziawg\\windows\\tunnel.dll";
  if (FileExists(bundled)) {
    return bundled;
  }

  const std::wstring local = GetExeDir() + L"\\tunnel.dll";
  if (FileExists(local)) {
    return local;
  }

  return std::nullopt;
}

std::optional<int> RunAmneziaWgServiceIfRequested() {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv) {
    return std::nullopt;
  }

  const bool service_mode =
      argc >= 4 && std::wstring(argv[1]) == L"/awg-service";
  if (!service_mode) {
    LocalFree(argv);
    return std::nullopt;
  }

  const std::wstring config_path = argv[2];
  std::wstring tunnel_name = argv[3];
  LocalFree(argv);

  SetCurrentDirectoryW(GetExeDir().c_str());
  const auto dll_path = ResolveTunnelDllPath();
  if (!FileExists(config_path) || !dll_path) {
    // Keep service-mode diagnostics next to the generated config. Windows SCM
    // only reports the numeric exit code, which is not enough for field tests.
    const std::wstring log_path =
        config_path.substr(0, config_path.find_last_of(L"\\/")) +
        L"\\windows-runner.log";
    HANDLE log = CreateFileW(log_path.c_str(), FILE_APPEND_DATA,
                             FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
                             FILE_ATTRIBUTE_NORMAL, nullptr);
    if (log != INVALID_HANDLE_VALUE) {
      const char* message =
          !FileExists(config_path)
              ? "awg-service: config file does not exist\n"
              : "awg-service: failed to resolve tunnel.dll\n";
      DWORD written = 0;
      WriteFile(log, message, static_cast<DWORD>(strlen(message)), &written,
                nullptr);
      CloseHandle(log);
    }
    return EXIT_FAILURE;
  }

  HMODULE dll = LoadLibraryW(dll_path->c_str());
  if (!dll) {
    const std::wstring log_path =
        config_path.substr(0, config_path.find_last_of(L"\\/")) +
        L"\\windows-runner.log";
    HANDLE log = CreateFileW(log_path.c_str(), FILE_APPEND_DATA,
                             FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
                             FILE_ATTRIBUTE_NORMAL, nullptr);
    if (log != INVALID_HANDLE_VALUE) {
      std::string message = "awg-service: LoadLibrary tunnel.dll failed error=" +
                            std::to_string(GetLastError()) + "\n";
      DWORD written = 0;
      WriteFile(log, message.data(), static_cast<DWORD>(message.size()),
                &written, nullptr);
      CloseHandle(log);
    }
    return EXIT_FAILURE;
  }

  using WireGuardTunnelServiceFn = unsigned char (*)(wchar_t*, wchar_t*);
  auto service_fn = reinterpret_cast<WireGuardTunnelServiceFn>(
      GetProcAddress(dll, "WireGuardTunnelService"));
  if (!service_fn) {
    const std::wstring log_path =
        config_path.substr(0, config_path.find_last_of(L"\\/")) +
        L"\\windows-runner.log";
    HANDLE log = CreateFileW(log_path.c_str(), FILE_APPEND_DATA,
                             FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
                             FILE_ATTRIBUTE_NORMAL, nullptr);
    if (log != INVALID_HANDLE_VALUE) {
      std::string message =
          "awg-service: WireGuardTunnelService export missing error=" +
          std::to_string(GetLastError()) + "\n";
      DWORD written = 0;
      WriteFile(log, message.data(), static_cast<DWORD>(message.size()),
                &written, nullptr);
      CloseHandle(log);
    }
    FreeLibrary(dll);
    return EXIT_FAILURE;
  }

  const unsigned char ok =
      service_fn(const_cast<wchar_t*>(config_path.c_str()),
                 tunnel_name.data());
  {
    const std::wstring log_path =
        config_path.substr(0, config_path.find_last_of(L"\\/")) +
        L"\\windows-runner.log";
    HANDLE log = CreateFileW(log_path.c_str(), FILE_APPEND_DATA,
                             FILE_SHARE_READ, nullptr, OPEN_ALWAYS,
                             FILE_ATTRIBUTE_NORMAL, nullptr);
    if (log != INVALID_HANDLE_VALUE) {
      std::string message = std::string("awg-service: tunnel returned ") +
                            (ok ? "success" : "failure") +
                            " last_error=" + std::to_string(GetLastError()) +
                            "\n";
      DWORD written = 0;
      WriteFile(log, message.data(), static_cast<DWORD>(message.size()),
                &written, nullptr);
      CloseHandle(log);
    }
  }
  FreeLibrary(dll);
  return ok ? EXIT_SUCCESS : EXIT_FAILURE;
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  if (const auto service_result = RunAmneziaWgServiceIfRequested()) {
    return *service_result;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
  if (RelaunchElevatedIfNeeded()) {
    ::CoUninitialize();
    return EXIT_SUCCESS;
  }
  EnsureDesktopShortcut();

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(432, 760);
  if (!window.Create(L"GRANI", origin, size)) {
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
