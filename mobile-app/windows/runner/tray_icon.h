#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_
#include <windows.h>
// Caller owns the returned icon. GDI+ must be initialized by the caller.
HICON CreateGraniTrayIcon(int size, bool connected, bool busy);
#endif
