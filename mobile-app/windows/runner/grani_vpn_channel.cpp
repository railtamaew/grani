#include "grani_vpn_channel.h"

#include <flutter/encodable_value.h>
#include <flutter/method_call.h>
#include <flutter/method_channel.h>
#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <sstream>
#include <string>

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
  return ok && written == content.size();
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
  return flutter::EncodableMap{
      {flutter::EncodableValue("connected"), flutter::EncodableValue(g_connected)},
      {flutter::EncodableValue("service_state"),
       flutter::EncodableValue(g_connected ? "connected" : "disconnected")},
      {flutter::EncodableValue("rx_bytes"), flutter::EncodableValue(g_rx_bytes)},
      {flutter::EncodableValue("tx_bytes"), flutter::EncodableValue(g_tx_bytes)},
      {flutter::EncodableValue("runner"),
       flutter::EncodableValue(ResolveAwgQuickPath().has_value()
                                   ? "awg-quick"
                                   : "missing")},
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

  const auto runner = ResolveAwgQuickPath();
  if (!runner) {
    result->Error(
        kMissingRunnerCode,
        "Windows GRANIwg runner is not bundled yet. Provide awg-quick.exe via "
        "GRANI_AWG_QUICK or package bin/amneziawg/windows/awg-quick.exe.");
    return;
  }

  const std::wstring config_path = GetConfigPath();
  if (!WriteUtf8File(config_path, *config)) {
    result->Error("CONFIG_WRITE_FAILED", "Failed to write GRANIwg config");
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
          result->Success(flutter::EncodableValue(IsUserAnAdmin() == TRUE));
          return;
        }
        result->NotImplemented();
      });
}
