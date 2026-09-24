#ifndef RUNNER_GRANI_VPN_CHANNEL_H_
#define RUNNER_GRANI_VPN_CHANNEL_H_

#include <flutter/binary_messenger.h>
#include <windows.h>

void RegisterGraniVpnChannel(flutter::BinaryMessenger* messenger, HWND window);
bool DispatchGraniVpnResult(UINT message);
void ShutdownGraniVpnChannel();

#endif  // RUNNER_GRANI_VPN_CHANNEL_H_
