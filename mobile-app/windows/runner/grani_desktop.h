#ifndef RUNNER_GRANI_DESKTOP_H_
#define RUNNER_GRANI_DESKTOP_H_
#include <flutter/binary_messenger.h>
#include <windows.h>
#include <optional>

void RegisterGraniDesktop(flutter::BinaryMessenger* messenger, HWND window);
std::optional<LRESULT> HandleGraniDesktopMessage(HWND window, UINT message,
                                                WPARAM wparam, LPARAM lparam);
void ShutdownGraniDesktop();
#endif
