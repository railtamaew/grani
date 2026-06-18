#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <shellapi.h>
#include <windows.h>

#include <cstdlib>
#include <limits>
#include <optional>
#include <string>
#include <vector>

#include "flutter_window.h"
#include "utils.h"

namespace {

std::wstring Utf8ToWide(const std::string& value) {
  if (value.empty()) {
    return L"";
  }
  const int size = MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                                       static_cast<int>(value.size()), nullptr,
                                       0);
  if (size <= 0) {
    return L"";
  }
  std::wstring result(size, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), result.data(), size);
  return result;
}

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

std::optional<std::string> ReadUtf8File(const std::wstring& path) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL,
                            nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return std::nullopt;
  }

  LARGE_INTEGER file_size{};
  if (!GetFileSizeEx(file, &file_size) || file_size.QuadPart < 0 ||
      file_size.QuadPart >
          static_cast<LONGLONG>(std::numeric_limits<DWORD>::max())) {
    CloseHandle(file);
    return std::nullopt;
  }

  std::string content(static_cast<size_t>(file_size.QuadPart), '\0');
  DWORD bytes_read = 0;
  const BOOL ok =
      content.empty() ||
      ::ReadFile(file, content.data(), static_cast<DWORD>(content.size()),
                 &bytes_read, nullptr);
  CloseHandle(file);

  if (!ok || static_cast<size_t>(bytes_read) != content.size()) {
    return std::nullopt;
  }
  return content;
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

  const auto config = ReadUtf8File(config_path);
  const auto dll_path = ResolveTunnelDllPath();
  if (!config || !dll_path) {
    return EXIT_FAILURE;
  }

  HMODULE dll = LoadLibraryW(dll_path->c_str());
  if (!dll) {
    return EXIT_FAILURE;
  }

  using WireGuardTunnelServiceFn = unsigned char (*)(wchar_t*, wchar_t*);
  auto service_fn = reinterpret_cast<WireGuardTunnelServiceFn>(
      GetProcAddress(dll, "WireGuardTunnelService"));
  if (!service_fn) {
    FreeLibrary(dll);
    return EXIT_FAILURE;
  }

  std::wstring config_wide = Utf8ToWide(*config);
  const unsigned char ok = service_fn(config_wide.data(), tunnel_name.data());
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

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"mobile_app", origin, size)) {
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
