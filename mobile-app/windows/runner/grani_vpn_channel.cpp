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
constexpr char kMissingRunnerCode[] = "WINDOWS_AWG_RUNNER_MISSING";

std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> g_channel;
bool g_connected = false;
int64_t g_rx_bytes = 0;
int64_t g_tx_bytes = 0;

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

std::optional<DWORD> QueryTunnelServiceState() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) {
    return std::nullopt;
  }

  SC_HANDLE service =
      OpenServiceW(manager, kTunnelName, SERVICE_QUERY_STATUS);
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

std::optional<std::string> InstallOrUpdateTunnelService(
    const std::wstring& config_path) {
  SC_HANDLE manager =
      OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT | SC_MANAGER_CREATE_SERVICE);
  if (!manager) {
    return WindowsErrorMessage(GetLastError());
  }

  const std::wstring command = BuildServiceCommandLine(config_path);
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
    const auto error = WindowsErrorMessage(GetLastError());
    CloseServiceHandle(service);
    CloseServiceHandle(manager);
    return error;
  }

  const bool running = WaitForServiceState(service, SERVICE_RUNNING, 30000);
  CloseServiceHandle(service);
  CloseServiceHandle(manager);
  if (!running) {
    return "Timed out waiting for GRANI AmneziaWG service to start";
  }
  return std::nullopt;
}

void StopTunnelService() {
  SC_HANDLE manager = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!manager) {
    return;
  }

  SC_HANDLE service =
      OpenServiceW(manager, kTunnelName, SERVICE_STOP | SERVICE_QUERY_STATUS);
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
  const auto service_state = QueryTunnelServiceState();
  const bool service_running =
      service_state.has_value() && *service_state == SERVICE_RUNNING;
  if (service_state.has_value()) {
    g_connected = service_running;
  }
  std::string runner = "missing";
  if (ResolveTunnelDllPath()) {
    runner = "tunnel.dll";
  } else if (ResolveAwgQuickPath()) {
    runner = "awg-quick";
  }

  return flutter::EncodableMap{
      {flutter::EncodableValue("connected"), flutter::EncodableValue(g_connected)},
      {flutter::EncodableValue("service_state"),
       flutter::EncodableValue(service_running || g_connected ? "connected"
                                                              : "disconnected")},
      {flutter::EncodableValue("rx_bytes"), flutter::EncodableValue(g_rx_bytes)},
      {flutter::EncodableValue("tx_bytes"), flutter::EncodableValue(g_tx_bytes)},
      {flutter::EncodableValue("runner"), flutter::EncodableValue(runner)},
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

  const std::wstring config_path = GetConfigPath();
  if (!WriteUtf8File(config_path, *config)) {
    result->Error("CONFIG_WRITE_FAILED", "Failed to write GRANIwg config");
    return;
  }

  const auto tunnel_dll = ResolveTunnelDllPath();
  if (tunnel_dll) {
    StopTunnelService();

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
        "Windows GRANIwg runner is not bundled yet. Provide tunnel.dll via "
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

void HandleDisconnectAmneziaWg(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  StopTunnelService();

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
        if (method == "requestPermission") {
          result->Success(flutter::EncodableValue(IsRunningAsAdmin()));
          return;
        }
        result->NotImplemented();
      });
}
