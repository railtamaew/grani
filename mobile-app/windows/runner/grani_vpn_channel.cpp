#include "grani_vpn_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <vector>

namespace {

constexpr wchar_t kAppDataDir[] = L"GRANI";
constexpr wchar_t kTunnelName[] = L"grani-awg";
constexpr wchar_t kOfficialServiceName[] = L"AmneziaWGTunnel$grani-awg";
constexpr wchar_t kLegacyServiceName[] = L"grani-awg";
constexpr char kMissingRunnerCode[] = "WINDOWS_AWG_RUNNER_MISSING";
constexpr char kMissingHysteriaCode[] = "WINDOWS_HYSTERIA2_RUNNER_MISSING";

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
bool g_connected = false;
int64_t g_rx_bytes = 0;
int64_t g_tx_bytes = 0;
HANDLE g_hysteria_process = nullptr;
DWORD g_hysteria_process_id = 0;

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

std::string WideToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return "";
  }
  const int size = WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                                       static_cast<int>(value.size()), nullptr,
                                       0, nullptr, nullptr);
  if (size <= 0) {
    return "";
  }
  std::string result(size, '\0');
  WideCharToMultiByte(CP_UTF8, 0, value.c_str(),
                      static_cast<int>(value.size()), result.data(), size,
                      nullptr, nullptr);
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

std::string ReadTailUtf8File(const std::wstring& path, DWORD max_bytes = 4096) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE,
                            nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return "";
  }

  LARGE_INTEGER size{};
  if (!GetFileSizeEx(file, &size)) {
    CloseHandle(file);
    return "";
  }

  const LONGLONG limited =
      size.QuadPart < static_cast<LONGLONG>(max_bytes)
          ? size.QuadPart
          : static_cast<LONGLONG>(max_bytes);
  const DWORD to_read = static_cast<DWORD>(limited);
  const LONG distance_low =
      -static_cast<LONG>(to_read);
  SetFilePointer(file, distance_low, nullptr, FILE_END);

  std::string buffer(to_read, '\0');
  DWORD read = 0;
  const BOOL ok = ReadFile(file, buffer.data(), to_read, &read, nullptr);
  CloseHandle(file);
  if (!ok) {
    return "";
  }
  buffer.resize(read);
  return buffer;
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

std::optional<std::wstring> ResolveAwgQuickPath() {
  if (auto env = GetEnvPath(L"GRANI_AWG_QUICK")) {
    if (FileExists(*env)) {
      return env;
    }
  }

  const std::wstring bundled =
      GetExeDir() + L"\\data\\flutter_assets\\bin\\amneziawg\\windows\\awg-quick.exe";
  if (FileExists(bundled)) {
    return bundled;
  }

  const std::wstring local = GetExeDir() + L"\\awg-quick.exe";
  if (FileExists(local)) {
    return local;
  }

  return std::nullopt;
}

std::optional<std::wstring> ResolveAmneziaWgPath() {
  if (auto env = GetEnvPath(L"GRANI_AMNEZIAWG_EXE")) {
    if (FileExists(*env)) {
      return env;
    }
  }

  const std::wstring bundled = GetExeDir() +
      L"\\data\\flutter_assets\\bin\\amneziawg\\windows\\amneziawg.exe";
  if (FileExists(bundled)) {
    return bundled;
  }

  const std::wstring local = GetExeDir() + L"\\amneziawg.exe";
  if (FileExists(local)) {
    return local;
  }

  return std::nullopt;
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

std::optional<std::wstring> ResolveHysteria2Path() {
  if (auto env = GetEnvPath(L"GRANI_HYSTERIA2_EXE")) {
    if (FileExists(*env)) {
      return env;
    }
  }

  const std::wstring bundled = GetExeDir() +
      L"\\data\\flutter_assets\\bin\\hysteria2\\windows\\hysteria.exe";
  if (FileExists(bundled)) {
    return bundled;
  }

  const std::wstring local = GetExeDir() + L"\\hysteria.exe";
  if (FileExists(local)) {
    return local;
  }

  return std::nullopt;
}

std::wstring GetExePath() {
  wchar_t path[MAX_PATH * 4];
  const DWORD size = GetModuleFileNameW(nullptr, path, ARRAYSIZE(path));
  return std::wstring(path, size);
}

std::wstring QuoteArg(const std::wstring& value) {
  return L"\"" + value + L"\"";
}

std::string WindowsErrorMessage(DWORD error) {
  std::ostringstream message;
  message << "Windows error " << error;
  return message.str();
}

std::wstring GetConfigPath() {
  std::wstring base;
  if (auto local = GetEnvPath(L"LOCALAPPDATA")) {
    base = *local;
  } else if (auto temp = GetEnvPath(L"TEMP")) {
    base = *temp;
  } else {
    base = GetExeDir();
  }

  const std::wstring dir = base + L"\\" + kAppDataDir;
  CreateDirectoryW(dir.c_str(), nullptr);
  return dir + L"\\" + kTunnelName + L".conf";
}

std::wstring GetRunnerLogPath() {
  const std::wstring config_path = GetConfigPath();
  const size_t slash = config_path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return L"windows-runner.log";
  }
  return config_path.substr(0, slash) + L"\\windows-runner.log";
}

std::wstring GetHysteria2ConfigPath() {
  const std::wstring config_path = GetConfigPath();
  const size_t slash = config_path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return L"hysteria2.yaml";
  }
  return config_path.substr(0, slash) + L"\\hysteria2.yaml";
}

std::wstring GetHysteria2LogPath() {
  const std::wstring config_path = GetConfigPath();
  const size_t slash = config_path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return L"hysteria2.log";
  }
  return config_path.substr(0, slash) + L"\\hysteria2.log";
}

std::wstring GetHysteria2PidPath() {
  const std::wstring config_path = GetConfigPath();
  const size_t slash = config_path.find_last_of(L"\\/");
  if (slash == std::wstring::npos) {
    return L"hysteria2.pid";
  }
  return config_path.substr(0, slash) + L"\\hysteria2.pid";
}

bool WriteUtf8File(const std::wstring& path, const std::string& content) {
  HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                            CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return false;
  }
  DWORD written = 0;
  const BOOL ok = WriteFile(file, content.data(),
                            static_cast<DWORD>(content.size()), &written,
                            nullptr);
  CloseHandle(file);
  return ok && static_cast<size_t>(written) == content.size();
}

void AppendUtf8File(const std::wstring& path, const std::string& content) {
  HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA,
                            FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                            OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (file == INVALID_HANDLE_VALUE) {
    return;
  }
  DWORD written = 0;
  WriteFile(file, content.data(), static_cast<DWORD>(content.size()), &written,
            nullptr);
  CloseHandle(file);
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

int RunHiddenAndWait(const std::wstring& exe, const std::wstring& args) {
  std::wstring command = L"\"" + exe + L"\" " + args;
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW;
  startup.wShowWindow = SW_HIDE;
  PROCESS_INFORMATION process{};

  if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
                      CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
    return static_cast<int>(GetLastError());
  }

  WaitForSingleObject(process.hProcess, 30000);
  DWORD exit_code = 1;
  GetExitCodeProcess(process.hProcess, &exit_code);
  CloseHandle(process.hThread);
  CloseHandle(process.hProcess);
  return static_cast<int>(exit_code);
}

void CloseHysteriaProcessHandle() {
  if (g_hysteria_process != nullptr) {
    CloseHandle(g_hysteria_process);
    g_hysteria_process = nullptr;
  }
  g_hysteria_process_id = 0;
}

bool ProcessImageMatches(HANDLE process, const std::wstring& expected_path) {
  std::wstring image_path(MAX_PATH * 4, L'\0');
  DWORD size = static_cast<DWORD>(image_path.size());
  if (!QueryFullProcessImageNameW(process, 0, image_path.data(), &size)) {
    return false;
  }
  image_path.resize(size);
  return _wcsicmp(image_path.c_str(), expected_path.c_str()) == 0;
}

HANDLE OpenPersistedHysteriaProcess() {
  const auto hysteria = ResolveHysteria2Path();
  if (!hysteria) {
    return nullptr;
  }

  if (g_hysteria_process != nullptr) {
    DWORD exit_code = 0;
    if (GetExitCodeProcess(g_hysteria_process, &exit_code) &&
        exit_code == STILL_ACTIVE &&
        ProcessImageMatches(g_hysteria_process, *hysteria)) {
      return g_hysteria_process;
    }
    CloseHysteriaProcessHandle();
  }

  const std::string raw_pid = ReadTailUtf8File(GetHysteria2PidPath(), 64);
  DWORD pid = 0;
  try {
    pid = static_cast<DWORD>(std::stoul(raw_pid));
  } catch (...) {
    DeleteFileW(GetHysteria2PidPath().c_str());
    return nullptr;
  }
  if (pid == 0) {
    DeleteFileW(GetHysteria2PidPath().c_str());
    return nullptr;
  }

  HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION |
                                   PROCESS_TERMINATE | SYNCHRONIZE,
                               FALSE, pid);
  if (process == nullptr) {
    DeleteFileW(GetHysteria2PidPath().c_str());
    return nullptr;
  }
  DWORD exit_code = 0;
  if (!GetExitCodeProcess(process, &exit_code) || exit_code != STILL_ACTIVE ||
      !ProcessImageMatches(process, *hysteria)) {
    CloseHandle(process);
    DeleteFileW(GetHysteria2PidPath().c_str());
    return nullptr;
  }

  g_hysteria_process = process;
  g_hysteria_process_id = pid;
  return process;
}

bool IsHysteria2Running() {
  return OpenPersistedHysteriaProcess() != nullptr;
}

std::optional<std::string> StopHysteria2Process() {
  HANDLE process = OpenPersistedHysteriaProcess();
  if (process != nullptr) {
    if (!TerminateProcess(process, 0)) {
      return WindowsErrorMessage(GetLastError());
    }
    if (WaitForSingleObject(process, 10000) != WAIT_OBJECT_0) {
      return "Timed out waiting for Hysteria2 process to stop";
    }
  }

  CloseHysteriaProcessHandle();
  DeleteFileW(GetHysteria2PidPath().c_str());
  DeleteFileW(GetHysteria2ConfigPath().c_str());
  return std::nullopt;
}

std::optional<std::string> StartHysteria2Process(
    const std::wstring& executable, const std::wstring& config_path) {
  SECURITY_ATTRIBUTES security{};
  security.nLength = sizeof(security);
  security.bInheritHandle = TRUE;
  HANDLE log_file = CreateFileW(
      GetHysteria2LogPath().c_str(), FILE_APPEND_DATA,
      FILE_SHARE_READ | FILE_SHARE_WRITE, &security, OPEN_ALWAYS,
      FILE_ATTRIBUTE_NORMAL, nullptr);
  if (log_file == INVALID_HANDLE_VALUE) {
    return WindowsErrorMessage(GetLastError());
  }

  std::wstring command = QuoteArg(executable) + L" client -c " +
                         QuoteArg(config_path);
  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESHOWWINDOW | STARTF_USESTDHANDLES;
  startup.wShowWindow = SW_HIDE;
  startup.hStdOutput = log_file;
  startup.hStdError = log_file;
  startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
  PROCESS_INFORMATION process{};

  const BOOL started = CreateProcessW(
      executable.c_str(), command.data(), nullptr, nullptr, TRUE,
      CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP, nullptr, nullptr, &startup,
      &process);
  CloseHandle(log_file);
  if (!started) {
    return WindowsErrorMessage(GetLastError());
  }
  CloseHandle(process.hThread);

  const DWORD startup_wait = WaitForSingleObject(process.hProcess, 1800);
  if (startup_wait == WAIT_OBJECT_0) {
    DWORD exit_code = 1;
    GetExitCodeProcess(process.hProcess, &exit_code);
    CloseHandle(process.hProcess);
    std::ostringstream message;
    message << "Hysteria2 exited during startup with code " << exit_code
            << "; log_tail="
            << ReadTailUtf8File(GetHysteria2LogPath(), 1600);
    return message.str();
  }
  if (startup_wait == WAIT_FAILED) {
    const DWORD error = GetLastError();
    TerminateProcess(process.hProcess, 1);
    CloseHandle(process.hProcess);
    return WindowsErrorMessage(error);
  }

  g_hysteria_process = process.hProcess;
  g_hysteria_process_id = process.dwProcessId;
  if (!WriteUtf8File(GetHysteria2PidPath(),
                     std::to_string(g_hysteria_process_id))) {
    TerminateProcess(g_hysteria_process, 1);
    WaitForSingleObject(g_hysteria_process, 5000);
    CloseHysteriaProcessHandle();
    return "Failed to persist Hysteria2 process id";
  }
  AppendUtf8File(GetRunnerLogPath(),
                 "hysteria2_started pid=" +
                     std::to_string(g_hysteria_process_id) + "\n");
  return std::nullopt;
}

std::wstring BuildServiceCommandLine(const std::wstring& config_path) {
  return QuoteArg(GetExePath()) + L" /awg-service " + QuoteArg(config_path) +
         L" " + kTunnelName;
}

bool WaitForServiceState(SC_HANDLE service, DWORD desired_state,
                         DWORD timeout_ms) {
  const DWORD start = GetTickCount();
  SERVICE_STATUS_PROCESS status{};
  DWORD bytes_needed = 0;

  while (GetTickCount() - start < timeout_ms) {
    if (!QueryServiceStatusEx(service, SC_STATUS_PROCESS_INFO,
                              reinterpret_cast<LPBYTE>(&status),
                              sizeof(status), &bytes_needed)) {
      return false;
    }
    if (status.dwCurrentState == desired_state) {
      return true;
    }
    Sleep(250);
  }

  return false;
}

std::optional<DWORD> QueryServiceState(const wchar_t* service_name) {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) {
    return std::nullopt;
  }

  SC_HANDLE service =
      OpenServiceW(manager, service_name, SERVICE_QUERY_STATUS);
  if (!service) {
    CloseServiceHandle(manager);
    return std::nullopt;
  }

  SERVICE_STATUS_PROCESS status{};
  DWORD bytes_needed = 0;
  const BOOL ok = QueryServiceStatusEx(
      service, SC_STATUS_PROCESS_INFO, reinterpret_cast<LPBYTE>(&status),
      sizeof(status), &bytes_needed);
  CloseServiceHandle(service);
  CloseServiceHandle(manager);

  if (!ok) {
    return std::nullopt;
  }
  return status.dwCurrentState;
}

std::optional<DWORD> QueryTunnelServiceState() {
  return QueryServiceState(kOfficialServiceName);
}

std::optional<DWORD> QueryLegacyTunnelServiceState() {
  return QueryServiceState(kLegacyServiceName);
}

std::string ServiceStateName(std::optional<DWORD> state) {
  if (!state.has_value()) {
    return "missing_or_unreadable";
  }
  switch (*state) {
    case SERVICE_STOPPED:
      return "stopped";
    case SERVICE_START_PENDING:
      return "start_pending";
    case SERVICE_STOP_PENDING:
      return "stop_pending";
    case SERVICE_RUNNING:
      return "running";
    case SERVICE_CONTINUE_PENDING:
      return "continue_pending";
    case SERVICE_PAUSE_PENDING:
      return "pause_pending";
    case SERVICE_PAUSED:
      return "paused";
    default:
      return "unknown_" + std::to_string(*state);
  }
}

std::optional<std::string> InstallOrUpdateTunnelService(
    const std::wstring& config_path) {
  SC_HANDLE manager =
      OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE);
  if (!manager) {
    return WindowsErrorMessage(GetLastError());
  }

  const std::wstring command = BuildServiceCommandLine(config_path);
  const std::wstring exe_path = GetExePath();
  const auto tunnel_dll = ResolveTunnelDllPath();
  std::ostringstream log;
  log << "install_or_update_service"
      << " exe_path=" << WideToUtf8(exe_path)
      << " exe_exists=" << (FileExists(exe_path) ? "true" : "false")
      << " command=" << WideToUtf8(command)
      << " tunnel_dll_path="
      << (tunnel_dll ? WideToUtf8(*tunnel_dll) : "")
      << " tunnel_dll_exists=" << (tunnel_dll.has_value() ? "true" : "false")
      << "\n";
  AppendUtf8File(GetRunnerLogPath(), log.str());

  constexpr wchar_t kDependencies[] = L"Nsi\0TcpIp\0\0";
  SC_HANDLE service = CreateServiceW(
      manager, kTunnelName, L"GRANI AmneziaWG Tunnel",
      SERVICE_START | SERVICE_STOP | SERVICE_QUERY_STATUS | SERVICE_CHANGE_CONFIG,
      SERVICE_WIN32_OWN_PROCESS, SERVICE_DEMAND_START, SERVICE_ERROR_NORMAL,
      command.c_str(), nullptr, nullptr, kDependencies, nullptr, nullptr);

  if (!service && GetLastError() == ERROR_SERVICE_EXISTS) {
    service = OpenServiceW(manager, kTunnelName,
                           SERVICE_START | SERVICE_STOP | SERVICE_QUERY_STATUS |
                               SERVICE_CHANGE_CONFIG);
    if (service) {
      if (!ChangeServiceConfigW(service, SERVICE_NO_CHANGE, SERVICE_DEMAND_START,
                                SERVICE_ERROR_NORMAL, command.c_str(), nullptr,
                                nullptr, kDependencies, nullptr, nullptr,
                                L"GRANI AmneziaWG Tunnel")) {
        const auto error = WindowsErrorMessage(GetLastError());
        CloseServiceHandle(service);
        CloseServiceHandle(manager);
        return error;
      }
    }
  }

  if (!service) {
    const auto error = WindowsErrorMessage(GetLastError());
    CloseServiceHandle(manager);
    return error;
  }

  SERVICE_SID_INFO sid_info{};
  sid_info.dwServiceSidType = SERVICE_SID_TYPE_UNRESTRICTED;
  ChangeServiceConfig2W(service, SERVICE_CONFIG_SERVICE_SID_INFO, &sid_info);

  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  return std::nullopt;
}

std::optional<std::string> StartTunnelService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) {
    return WindowsErrorMessage(GetLastError());
  }

  SC_HANDLE service =
      OpenServiceW(manager, kTunnelName, SERVICE_START | SERVICE_QUERY_STATUS);
  if (!service) {
    const auto error = WindowsErrorMessage(GetLastError());
    CloseServiceHandle(manager);
    return error;
  }

  if (!StartServiceW(service, 0, nullptr) &&
      GetLastError() != ERROR_SERVICE_ALREADY_RUNNING) {
    const DWORD last_error = GetLastError();
    const auto error = WindowsErrorMessage(last_error);
    std::ostringstream log;
    log << "start_service_failed"
        << " error=" << last_error
        << " message=" << error
        << " service_state="
        << ServiceStateName(QueryLegacyTunnelServiceState())
        << "\n";
    AppendUtf8File(GetRunnerLogPath(), log.str());
    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    return error;
  }

  const bool running = WaitForServiceState(service, SERVICE_RUNNING, 6000);
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  if (!running) {
    std::ostringstream message;
    message << "Timed out waiting 6s for GRANI AmneziaWG service to start; "
            << "service_state="
            << ServiceStateName(QueryLegacyTunnelServiceState())
            << "; runner_log_tail=" << ReadTailUtf8File(GetRunnerLogPath(), 1200);
    AppendUtf8File(GetRunnerLogPath(), "start_service_timeout " + message.str() + "\n");
    return message.str();
  }
  AppendUtf8File(GetRunnerLogPath(), "start_service_running\n");
  return std::nullopt;
}

void StopLegacyTunnelService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) {
    return;
  }

  SC_HANDLE service = OpenServiceW(
      manager, kLegacyServiceName, SERVICE_STOP | SERVICE_QUERY_STATUS);
  if (!service) {
    CloseServiceHandle(manager);
    return;
  }

  SERVICE_STATUS status{};
  if (ControlService(service, SERVICE_CONTROL_STOP, &status) ||
      GetLastError() == ERROR_SERVICE_NOT_ACTIVE) {
    WaitForServiceState(service, SERVICE_STOPPED, 15000);
  }

  CloseServiceHandle(service);
  CloseServiceHandle(manager);
}

std::optional<std::string> UninstallOfficialTunnel(
    const std::wstring& amneziawg_path) {
  if (!QueryTunnelServiceState().has_value()) {
    return std::nullopt;
  }

  const int exit_code = RunHiddenAndWait(
      amneziawg_path, L"/uninstalltunnelservice " + QuoteArg(kTunnelName));
  if (exit_code != 0) {
    std::ostringstream message;
    message << "Official AmneziaWG tunnel uninstall failed with exit code "
            << exit_code;
    AppendUtf8File(GetRunnerLogPath(), "official_uninstall_failed " +
                                           message.str() + "\n");
    return message.str();
  }

  const DWORD started = GetTickCount();
  while (GetTickCount() - started < 15000) {
    if (!QueryTunnelServiceState().has_value()) {
      AppendUtf8File(GetRunnerLogPath(), "official_tunnel_uninstalled\n");
      return std::nullopt;
    }
    Sleep(250);
  }
  return "Timed out waiting for the official AmneziaWG tunnel service to be removed";
}

std::optional<std::string> InstallOfficialTunnel(
    const std::wstring& amneziawg_path,
    const std::wstring& config_path) {
  if (const auto error = UninstallOfficialTunnel(amneziawg_path)) {
    return error;
  }

  StopLegacyTunnelService();
  AppendUtf8File(
      GetRunnerLogPath(),
      "official_install exe=" + WideToUtf8(amneziawg_path) +
          " config=" + WideToUtf8(config_path) + "\n");
  const int exit_code = RunHiddenAndWait(
      amneziawg_path, L"/installtunnelservice " + QuoteArg(config_path));
  if (exit_code != 0) {
    std::ostringstream message;
    message << "Official AmneziaWG tunnel install failed with exit code "
            << exit_code;
    AppendUtf8File(GetRunnerLogPath(), "official_install_failed " +
                                           message.str() + "\n");
    return message.str();
  }

  const DWORD started = GetTickCount();
  while (GetTickCount() - started < 15000) {
    const auto state = QueryTunnelServiceState();
    if (state.has_value() && *state == SERVICE_RUNNING) {
      AppendUtf8File(GetRunnerLogPath(), "official_tunnel_running\n");
      return std::nullopt;
    }
    if (state.has_value() && *state == SERVICE_STOPPED) {
      break;
    }
    Sleep(250);
  }

  std::ostringstream message;
  message << "Official AmneziaWG tunnel did not reach running state; state="
          << ServiceStateName(QueryTunnelServiceState());
  AppendUtf8File(GetRunnerLogPath(), "official_start_failed " + message.str() +
                                         "\n");
  return message.str();
}

std::optional<std::string> GetStringArg(const flutter::EncodableValue* args,
                                        const char* key) {
  if (!args || !std::holds_alternative<flutter::EncodableMap>(*args)) {
    return std::nullopt;
  }
  const auto& map = std::get<flutter::EncodableMap>(*args);
  const auto it = map.find(flutter::EncodableValue(key));
  if (it == map.end() || !std::holds_alternative<std::string>(it->second)) {
    return std::nullopt;
  }
  return std::get<std::string>(it->second);
}

flutter::EncodableMap StatusMap() {
  const bool hysteria_running = IsHysteria2Running();
  const auto amneziawg = ResolveAmneziaWgPath();
  const auto service_state = amneziawg ? QueryTunnelServiceState()
                                       : QueryLegacyTunnelServiceState();
  const bool service_running =
      service_state.has_value() && *service_state == SERVICE_RUNNING;
  if (hysteria_running || amneziawg || service_state.has_value()) {
    g_connected = hysteria_running || service_running;
  }
  std::string runner = "missing";
  std::string runtime_protocol;
  if (hysteria_running) {
    runner = "official_hysteria2_process";
    runtime_protocol = "hysteria2";
  } else if (amneziawg) {
    runner = "official_amneziawg_service";
    runtime_protocol = service_running ? "graniwg" : "";
  } else if (ResolveTunnelDllPath()) {
    runner = "tunnel.dll";
    runtime_protocol = service_running ? "graniwg" : "";
  } else if (ResolveAwgQuickPath()) {
    runner = "awg-quick";
    runtime_protocol = g_connected ? "graniwg" : "";
  }

  return flutter::EncodableMap{
      {flutter::EncodableValue("connected"), flutter::EncodableValue(g_connected)},
      {flutter::EncodableValue("service_state"),
       flutter::EncodableValue(service_running || g_connected ? "connected"
                                                              : "disconnected")},
      {flutter::EncodableValue("rx_bytes"), flutter::EncodableValue(g_rx_bytes)},
      {flutter::EncodableValue("tx_bytes"), flutter::EncodableValue(g_tx_bytes)},
      {flutter::EncodableValue("runner"), flutter::EncodableValue(runner)},
      {flutter::EncodableValue("runtime_protocol"),
       flutter::EncodableValue(runtime_protocol)},
      {flutter::EncodableValue("hysteria2_pid"),
       flutter::EncodableValue(static_cast<int64_t>(g_hysteria_process_id))},
  };
}

flutter::EncodableMap DesktopDiagnosticsMap() {
  const std::wstring config_path = GetConfigPath();
  const std::wstring log_path = GetRunnerLogPath();
  const auto service_state = QueryTunnelServiceState();
  const auto legacy_service_state = QueryLegacyTunnelServiceState();
  const auto amneziawg = ResolveAmneziaWgPath();
  const auto hysteria = ResolveHysteria2Path();
  const bool hysteria_running = IsHysteria2Running();
  const auto tunnel_dll = ResolveTunnelDllPath();
  const auto awg_quick = ResolveAwgQuickPath();

  return flutter::EncodableMap{
      {flutter::EncodableValue("platform"), flutter::EncodableValue("windows")},
      {flutter::EncodableValue("is_admin"), flutter::EncodableValue(IsRunningAsAdmin())},
      {flutter::EncodableValue("exe_path"), flutter::EncodableValue(WideToUtf8(GetExePath()))},
      {flutter::EncodableValue("exe_exists"), flutter::EncodableValue(FileExists(GetExePath()))},
      {flutter::EncodableValue("exe_dir"), flutter::EncodableValue(WideToUtf8(GetExeDir()))},
      {flutter::EncodableValue("runtime_mode"),
       flutter::EncodableValue(hysteria_running
                                  ? "official_hysteria2_process"
                                  : amneziawg ? "official_amneziawg_service"
                                              : "legacy_fallback")},
      {flutter::EncodableValue("amneziawg_path"),
       flutter::EncodableValue(amneziawg ? WideToUtf8(*amneziawg) : "")},
      {flutter::EncodableValue("amneziawg_exists"),
       flutter::EncodableValue(amneziawg.has_value())},
      {flutter::EncodableValue("hysteria2_path"),
       flutter::EncodableValue(hysteria ? WideToUtf8(*hysteria) : "")},
      {flutter::EncodableValue("hysteria2_exists"),
       flutter::EncodableValue(hysteria.has_value())},
      {flutter::EncodableValue("hysteria2_running"),
       flutter::EncodableValue(hysteria_running)},
      {flutter::EncodableValue("hysteria2_pid"),
       flutter::EncodableValue(static_cast<int64_t>(g_hysteria_process_id))},
      {flutter::EncodableValue("hysteria2_config_path"),
       flutter::EncodableValue(WideToUtf8(GetHysteria2ConfigPath()))},
      {flutter::EncodableValue("hysteria2_log_path"),
       flutter::EncodableValue(WideToUtf8(GetHysteria2LogPath()))},
      {flutter::EncodableValue("hysteria2_log_tail"),
       flutter::EncodableValue(ReadTailUtf8File(GetHysteria2LogPath()))},
      {flutter::EncodableValue("official_service_name"),
       flutter::EncodableValue(WideToUtf8(kOfficialServiceName))},
      {flutter::EncodableValue("service_command"),
       flutter::EncodableValue(
           amneziawg ? WideToUtf8(QuoteArg(*amneziawg) +
                                  L" /installtunnelservice " +
                                  QuoteArg(config_path))
                     : WideToUtf8(BuildServiceCommandLine(config_path)))},
      {flutter::EncodableValue("config_path"), flutter::EncodableValue(WideToUtf8(config_path))},
      {flutter::EncodableValue("config_exists"), flutter::EncodableValue(FileExists(config_path))},
      {flutter::EncodableValue("runner_log_path"), flutter::EncodableValue(WideToUtf8(log_path))},
      {flutter::EncodableValue("runner_log_exists"), flutter::EncodableValue(FileExists(log_path))},
      {flutter::EncodableValue("runner_log_tail"),
       flutter::EncodableValue(ReadTailUtf8File(log_path))},
      {flutter::EncodableValue("tunnel_dll_path"),
       flutter::EncodableValue(tunnel_dll ? WideToUtf8(*tunnel_dll) : "")},
      {flutter::EncodableValue("tunnel_dll_exists"), flutter::EncodableValue(tunnel_dll.has_value())},
      {flutter::EncodableValue("awg_quick_path"),
       flutter::EncodableValue(awg_quick ? WideToUtf8(*awg_quick) : "")},
      {flutter::EncodableValue("awg_quick_exists"), flutter::EncodableValue(awg_quick.has_value())},
      {flutter::EncodableValue("service_state"),
       flutter::EncodableValue(ServiceStateName(service_state))},
      {flutter::EncodableValue("service_state_code"),
       flutter::EncodableValue(static_cast<int>(service_state.value_or(0)))},
      {flutter::EncodableValue("legacy_service_state"),
       flutter::EncodableValue(ServiceStateName(legacy_service_state))},
  };
}

void HandleConnectAmneziaWg(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto config = GetStringArg(call.arguments(), "config");
  if (!config || config->empty()) {
    result->Error("INVALID_CONFIG", "GRANIwg config is empty");
    return;
  }
  if (!IsRunningAsAdmin()) {
    result->Error("WINDOWS_ADMIN_REQUIRED",
                  "Run GRANI as administrator to start the Windows VPN service");
    return;
  }

  if (const auto error = StopHysteria2Process()) {
    result->Error("WINDOWS_HYSTERIA2_STOP_FAILED", *error);
    return;
  }

  const std::wstring config_path = GetConfigPath();
  if (!WriteUtf8File(config_path, *config)) {
    result->Error("CONFIG_WRITE_FAILED", "Failed to write GRANIwg config");
    return;
  }

  const auto amneziawg = ResolveAmneziaWgPath();
  if (amneziawg) {
    if (const auto error = InstallOfficialTunnel(*amneziawg, config_path)) {
      result->Error("WINDOWS_AWG_SERVICE_INSTALL_FAILED", *error);
      return;
    }

    g_connected = true;
    result->Success(flutter::EncodableValue(true));
    return;
  }

  const auto tunnel_dll = ResolveTunnelDllPath();
  if (tunnel_dll) {
    StopLegacyTunnelService();

    if (const auto error = InstallOrUpdateTunnelService(config_path)) {
      result->Error("WINDOWS_AWG_SERVICE_INSTALL_FAILED", *error);
      return;
    }
    if (const auto error = StartTunnelService()) {
      result->Error("WINDOWS_AWG_START_FAILED", *error);
      return;
    }

    g_connected = true;
    result->Success(flutter::EncodableValue(true));
    return;
  }

  const auto runner = ResolveAwgQuickPath();
  if (!runner) {
    result->Error(
        kMissingRunnerCode,
        "Windows GRANIwg runner is not bundled yet. Package the official "
        "amneziawg.exe runtime or provide tunnel.dll via "
        "GRANI_AWG_TUNNEL_DLL or package bin/amneziawg/windows/tunnel.dll. "
        "For legacy testing, GRANI_AWG_QUICK or awg-quick.exe is also accepted.");
    return;
  }

  const int exit_code = RunHiddenAndWait(*runner, L"up \"" + config_path + L"\"");
  if (exit_code != 0) {
    std::ostringstream message;
    message << "Windows GRANIwg runner failed with exit code " << exit_code;
    result->Error("WINDOWS_AWG_START_FAILED", message.str());
    return;
  }

  g_connected = true;
  result->Success(flutter::EncodableValue(true));
}

void HandleConnectHysteria2(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto config = GetStringArg(call.arguments(), "config");
  if (!config || config->empty()) {
    result->Error("INVALID_CONFIG", "Hysteria2 config is empty");
    return;
  }
  if (!IsRunningAsAdmin()) {
    result->Error(
        "WINDOWS_ADMIN_REQUIRED",
        "Run GRANI as administrator to start the Windows Hysteria2 TUN");
    return;
  }

  const auto hysteria = ResolveHysteria2Path();
  if (!hysteria) {
    result->Error(
        kMissingHysteriaCode,
        "Official Hysteria2 Windows runtime is not bundled. Package "
        "hysteria.exe next to mobile_app.exe or set GRANI_HYSTERIA2_EXE.");
    return;
  }

  if (const auto error = StopHysteria2Process()) {
    result->Error("WINDOWS_HYSTERIA2_STOP_FAILED", *error);
    return;
  }
  const auto amneziawg = ResolveAmneziaWgPath();
  if (amneziawg) {
    if (const auto error = UninstallOfficialTunnel(*amneziawg)) {
      result->Error("WINDOWS_AWG_STOP_FAILED", *error);
      return;
    }
  }
  StopLegacyTunnelService();

  const std::wstring config_path = GetHysteria2ConfigPath();
  if (!WriteUtf8File(config_path, *config)) {
    result->Error("CONFIG_WRITE_FAILED", "Failed to write Hysteria2 config");
    return;
  }
  if (const auto error = StartHysteria2Process(*hysteria, config_path)) {
    DeleteFileW(config_path.c_str());
    result->Error("WINDOWS_HYSTERIA2_START_FAILED", *error);
    return;
  }

  g_connected = true;
  g_rx_bytes = 0;
  g_tx_bytes = 0;
  result->Success(flutter::EncodableValue(true));
}

void HandleDisconnectAmneziaWg(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  if (const auto error = StopHysteria2Process()) {
    result->Error("WINDOWS_HYSTERIA2_STOP_FAILED", *error);
    return;
  }
  const auto amneziawg = ResolveAmneziaWgPath();
  if (amneziawg) {
    if (const auto error = UninstallOfficialTunnel(*amneziawg)) {
      result->Error("WINDOWS_AWG_STOP_FAILED", *error);
      return;
    }
  }
  StopLegacyTunnelService();

  const auto runner = ResolveAwgQuickPath();
  if (runner) {
    const std::wstring config_path = GetConfigPath();
    RunHiddenAndWait(*runner, L"down \"" + config_path + L"\"");
  }
  g_connected = false;
  g_rx_bytes = 0;
  g_tx_bytes = 0;
  result->Success(flutter::EncodableValue(true));
}

}  // namespace

void RegisterGraniVpnChannel(flutter::BinaryMessenger* messenger) {
  g_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "com.granivpn.mobile/vpn",
          &flutter::StandardMethodCodec::GetInstance());

  g_channel->SetMethodCallHandler(
      [](const flutter::MethodCall<flutter::EncodableValue>& call,
         std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
             result) {
        const std::string& method = call.method_name();
        if (method == "connectAmneziaWg") {
          HandleConnectAmneziaWg(call, std::move(result));
          return;
        }
        if (method == "connectHysteria2") {
          HandleConnectHysteria2(call, std::move(result));
          return;
        }
        if (method == "disconnectAmneziaWg" || method == "disconnect") {
          HandleDisconnectAmneziaWg(std::move(result));
          return;
        }
        if (method == "getAmneziaWgStatus" || method == "getStatus") {
          result->Success(flutter::EncodableValue(StatusMap()));
          return;
        }
        if (method == "getTrafficStats") {
          result->Success(flutter::EncodableValue(flutter::EncodableMap{
              {flutter::EncodableValue("rx_bytes"),
               flutter::EncodableValue(g_rx_bytes)},
              {flutter::EncodableValue("tx_bytes"),
               flutter::EncodableValue(g_tx_bytes)},
          }));
          return;
        }
        if (method == "getDesktopVpnDiagnostics") {
          result->Success(flutter::EncodableValue(DesktopDiagnosticsMap()));
          return;
        }
        if (method == "getRuntimeDiagnostics") {
          result->Success(flutter::EncodableValue(StatusMap()));
          return;
        }
        if (method == "requestPermission") {
          result->Success(flutter::EncodableValue(IsRunningAsAdmin()));
          return;
        }
        result->NotImplemented();
      });
}
