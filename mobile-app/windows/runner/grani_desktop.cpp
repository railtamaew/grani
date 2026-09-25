#include "grani_desktop.h"
#include "resource.h"
#include "tray_icon.h"
#include <gdiplus.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>
#include <memory>
#include <string>

namespace {
using Value = flutter::EncodableValue;
constexpr UINT kTrayMessage = WM_APP + 8;
constexpr UINT kShow = 2101, kToggle = 2102, kQuit = 2103, kWebsite = 2104;
// Stable identity allows Windows to remember the user's visibility preference.
const GUID kTrayGuid = {0x6433219a, 0xb147, 0x471d,
                       {0x91, 0x6f, 0x46, 0x72, 0x61, 0x6e, 0x69, 0x44}};
std::unique_ptr<flutter::MethodChannel<Value>> channel;
HWND app_window = nullptr;
UINT taskbar_created = 0;
bool tray_available = false, quitting = false, close_hint_shown = false;
bool can_toggle = false, connected = false, busy = false, russian = true;
std::wstring status = L"GRANI", location;
HICON tray_icon = nullptr;
ULONG_PTR gdiplus_token = 0;

std::wstring Wide(const std::string& value) {
  if (value.empty()) return {};
  const int n = MultiByteToWideChar(CP_UTF8, 0, value.data(),
                                   static_cast<int>(value.size()), nullptr, 0);
  std::wstring out(n, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, value.data(), static_cast<int>(value.size()),
                      out.data(), n);
  return out;
}

NOTIFYICONDATAW TrayData() {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = app_window;
  data.uID = 1;
  data.guidItem = kTrayGuid;
  data.uFlags = NIF_GUID;
  return data;
}

HICON MakeStatusIcon() {
  const UINT dpi = app_window ? GetDpiForWindow(app_window) : GetDpiForSystem();
  const int size = GetSystemMetricsForDpi(SM_CXSMICON, dpi);
  return CreateGraniTrayIcon(size, connected, busy);
}

void UpdateTray(bool add = false) {
  HICON next = MakeStatusIcon();
  if (!next) return;  // Keep the existing, valid icon on allocation failure.
  HICON previous = tray_icon;
  tray_icon = next;
  auto data = TrayData();
  data.uFlags |= NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP;
  data.uCallbackMessage = kTrayMessage;
  data.hIcon = tray_icon;
  const auto tip = L"GRANI — " + status +
      (location.empty() ? L"" : L"\n" + location);
  wcsncpy_s(data.szTip, tip.c_str(), _TRUNCATE);
  tray_available = Shell_NotifyIconW(add ? NIM_ADD : NIM_MODIFY, &data) != FALSE;
  if (previous) DestroyIcon(previous);
  if (!tray_available && !add) {
    UpdateTray(true);
    return;
  }
  if (tray_available && add) {
    data.uVersion = NOTIFYICON_VERSION_4;
    Shell_NotifyIconW(NIM_SETVERSION, &data);
  }
}

void ShowApp() {
  ShowWindow(app_window, IsIconic(app_window) ? SW_RESTORE : SW_SHOW);
  SetForegroundWindow(app_window);
}

void RequestAction(const char* action) {
  if (channel) channel->InvokeMethod(action, nullptr);
}

void ShowMenu() {
  HMENU menu = CreatePopupMenu();
  AppendMenuW(menu, MF_STRING | MF_DISABLED, 0, status.c_str());
  if (!location.empty()) AppendMenuW(menu, MF_STRING | MF_DISABLED, 0, location.c_str());
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kShow, russian ? L"Открыть GRANI" : L"Open GRANI");
  const wchar_t* toggle_label = busy
      ? (russian ? L"Подождите…" : L"Please wait…")
      : connected ? (russian ? L"Отключить VPN" : L"Disconnect VPN")
                  : (russian ? L"Подключить VPN" : L"Connect VPN");
  AppendMenuW(menu, MF_STRING | ((!can_toggle || busy) ? MF_DISABLED : 0),
              kToggle, toggle_label);
  AppendMenuW(menu, MF_STRING, kWebsite,
      russian ? L"Посетить сайт GRANI" : L"Visit GRANI website");
  AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
  AppendMenuW(menu, MF_STRING, kQuit,
      russian ? L"Отключить VPN и выйти" : L"Disconnect VPN and quit");
  POINT cursor{}; GetCursorPos(&cursor);
  SetForegroundWindow(app_window);
  const auto command = TrackPopupMenu(menu,
      TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON,
      cursor.x, cursor.y, 0, app_window, nullptr);
  DestroyMenu(menu);
  PostMessageW(app_window, WM_NULL, 0, 0);
  auto data = TrayData(); Shell_NotifyIconW(NIM_SETFOCUS, &data);
  if (command == kShow) ShowApp();
  if (command == kWebsite) RequestAction("website");
  if (command == kToggle && can_toggle && !busy) RequestAction("toggle");
  if (command == kQuit && !quitting) RequestAction("quit");
}

std::string ReadString(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(Value(key));
  if (it == map.end()) return {};
  const auto* text = std::get_if<std::string>(&it->second);
  return text ? *text : "";
}
bool ReadBool(const flutter::EncodableMap& map, const char* key) {
  const auto it = map.find(Value(key));
  if (it == map.end()) return false;
  const auto* value = std::get_if<bool>(&it->second);
  return value && *value;
}
}

void RegisterGraniDesktop(flutter::BinaryMessenger* messenger, HWND window) {
  app_window = window;
  Gdiplus::GdiplusStartupInput graphics_startup;
  Gdiplus::GdiplusStartup(&gdiplus_token, &graphics_startup, nullptr);
  russian = PRIMARYLANGID(GetUserDefaultUILanguage()) == LANG_RUSSIAN;
  status = russian ? L"Запуск…" : L"Starting…";
  taskbar_created = RegisterWindowMessageW(L"TaskbarCreated");
  // Explorer is not elevated. Permit only its fixed, argument-free restart
  // notification so the icon returns after Explorer/taskbar restarts.
  ChangeWindowMessageFilterEx(window, taskbar_created, MSGFLT_ALLOW, nullptr);
  UpdateTray(true);
  channel = std::make_unique<flutter::MethodChannel<Value>>(
      messenger, "com.granivpn.desktop/controls",
      &flutter::StandardMethodCodec::GetInstance());
  channel->SetMethodCallHandler([](const auto& call, auto result) {
    if (call.method_name() == "updateState") {
      const auto* map = call.arguments()
          ? std::get_if<flutter::EncodableMap>(call.arguments()) : nullptr;
      if (!map) { result->Error("INVALID_STATE", "State must be a map"); return; }
      status = Wide(ReadString(*map, "status"));
      location = Wide(ReadString(*map, "location"));
      connected = ReadBool(*map, "connected");
      busy = ReadBool(*map, "busy");
      can_toggle = ReadBool(*map, "canToggle");
      russian = ReadString(*map, "locale") == "ru";
      UpdateTray();
      result->Success();
    } else if (call.method_name() == "finishQuit") {
      quitting = true;
      result->Success();
      PostMessageW(app_window, WM_CLOSE, 0, 0);
    } else {
      result->NotImplemented();
    }
  });
}

std::optional<LRESULT> HandleGraniDesktopMessage(HWND, UINT message,
                                                WPARAM, LPARAM lparam) {
  if (!app_window) return std::nullopt;
  if (taskbar_created && message == taskbar_created) {
    UpdateTray(true);
    return 0;
  }
  if (message == WM_DPICHANGED || message == WM_SETTINGCHANGE) {
    UpdateTray();
    // The window and Flutter must also receive the DPI/settings change.
  }
  if (message == kTrayMessage) {
    const auto event = LOWORD(lparam);
    if (event == NIN_SELECT || event == NIN_KEYSELECT || event == WM_LBUTTONDBLCLK)
      ShowApp();
    else if (event == WM_CONTEXTMENU || event == WM_RBUTTONUP) ShowMenu();
    return 0;
  }
  if (message == WM_CLOSE && !quitting) {
    if (!tray_available) {
      // Never hide the only way back into the application.
      ShowApp();
      RequestAction("quit");
      return 0;
    }
    ShowWindow(app_window, SW_HIDE);
    if (!close_hint_shown) {
      auto data = TrayData(); data.uFlags |= NIF_INFO;
      wcscpy_s(data.szInfoTitle, L"GRANI");
      wcscpy_s(data.szInfo, russian
          ? L"GRANI работает в трее. Нажмите значок рядом с часами, чтобы управлять VPN."
          : L"GRANI is running in the system tray. Use its icon next to the clock to control VPN.");
      data.dwInfoFlags = NIIF_INFO;
      Shell_NotifyIconW(NIM_MODIFY, &data);
      close_hint_shown = true;
    }
    return 0;
  }
  return std::nullopt;
}

void ShutdownGraniDesktop() {
  if (app_window) {
    auto data = TrayData(); Shell_NotifyIconW(NIM_DELETE, &data);
  }
  if (tray_icon) { DestroyIcon(tray_icon); tray_icon = nullptr; }
  channel.reset(); app_window = nullptr;
  if (gdiplus_token) { Gdiplus::GdiplusShutdown(gdiplus_token); gdiplus_token = 0; }
}
