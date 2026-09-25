#include <windows.h>
#include <gdiplus.h>
#include <cassert>
#include <algorithm>
#include <cstdint>
#include <fstream>
#include <iostream>
#include <vector>
#include "../runner/tray_icon.h"

int main() {
  Gdiplus::GdiplusStartupInput startup;
  ULONG_PTR token = 0;
  assert(Gdiplus::GdiplusStartup(&token, &startup, nullptr) == Gdiplus::Ok);
  const int sizes[] = {16, 20, 24, 32, 48};
  constexpr int width = 400, height = 300;
  std::vector<uint32_t> preview(width * height, 0xFFF4F6F8);
  for (int row = 0; row < 3; ++row) {
    for (int column = 0; column < 5; ++column) {
      const int size = sizes[column];
      HICON icon = CreateGraniTrayIcon(size, row == 1, row == 2);
      assert(icon);
      ICONINFO info{};
      assert(GetIconInfo(icon, &info));
      BITMAPINFO bitmap{};
      bitmap.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
      bitmap.bmiHeader.biWidth = size;
      bitmap.bmiHeader.biHeight = -size;
      bitmap.bmiHeader.biPlanes = 1;
      bitmap.bmiHeader.biBitCount = 32;
      bitmap.bmiHeader.biCompression = BI_RGB;
      std::vector<uint32_t> pixels(size * size);
      HDC dc = GetDC(nullptr);
      assert(GetDIBits(dc, info.hbmColor, 0, size, pixels.data(), &bitmap, DIB_RGB_COLORS));
      ReleaseDC(nullptr, dc);
      int visible = 0, accent = 0;
      for (const auto pixel : pixels) {
        const auto alpha = pixel >> 24;
        if (alpha > 128) ++visible;
        const auto red = (pixel >> 16) & 255, green = (pixel >> 8) & 255, blue = pixel & 255;
        if (alpha > 230 && (row == 1 ? green > red + 30 && green > blue + 20
                                   : row == 2 ? red > green + 30 && green > blue + 30
                                              : blue > red && green > red)) ++accent;
      }
      std::cout << "state=" << row << " size=" << size << " visible=" << visible << " accent=" << accent << std::endl;
      // Regression: neither a mostly transparent fragment nor an opaque square.
      assert(visible > size * size / 5);
      assert(visible < size * size * 4 / 5);
      // GDI+ can leave a tiny antialias tail (alpha 8/255 at 16 px).
      // Reject a visible square background while allowing that edge coverage.
      assert((pixels.front() >> 24) <= 16 && (pixels.back() >> 24) <= 16);
      assert((pixels[size - 1] >> 24) <= 16 && (pixels[size * (size - 1)] >> 24) <= 16);
      assert(accent > 0);
      // Composite the actual HICON pixels on light and dark taskbar backgrounds.
      for (int theme = 0; theme < 2; ++theme) {
        const int base = theme == 0 ? 244 : 32;
        for (int y = 0; y < 50; ++y) for (int x = 0; x < 80; ++x) {
          preview[(row * 100 + theme * 50 + y) * width + column * 80 + x] =
              0xFF000000 | (base << 16) | (base << 8) | base;
        }
        for (int y = 0; y < size; ++y) for (int x = 0; x < size; ++x) {
          const auto pixel = pixels[y * size + x];
          const auto alpha = pixel >> 24;
          uint32_t output = 0xFF000000;
          for (int shift = 0; shift < 24; shift += 8) {
            const auto component = (pixel >> shift) & 255;
            // HICON color pixels are already premultiplied by alpha.
            const auto value = std::min(255u, component + base * (255 - alpha) / 255);
            output |= value << shift;
          }
          preview[(row * 100 + theme * 50 + (50 - size) / 2 + y) * width +
                  column * 80 + (80 - size) / 2 + x] = output;
        }
      }
      DeleteObject(info.hbmColor); DeleteObject(info.hbmMask); DestroyIcon(icon);
    }
  }
  BITMAPFILEHEADER file{};
  file.bfType = 0x4D42;
  file.bfOffBits = sizeof(BITMAPFILEHEADER) + sizeof(BITMAPINFOHEADER);
  file.bfSize = file.bfOffBits + static_cast<DWORD>(preview.size() * 4);
  BITMAPINFOHEADER header{};
  header.biSize = sizeof(header); header.biWidth = width; header.biHeight = -height;
  header.biPlanes = 1; header.biBitCount = 32; header.biCompression = BI_RGB;
  CreateDirectoryW(L"build", nullptr); CreateDirectoryW(L"build/qa", nullptr);
  std::ofstream output("build/qa/tray-icons.bmp", std::ios::binary);
  output.write(reinterpret_cast<const char*>(&file), sizeof(file));
  output.write(reinterpret_cast<const char*>(&header), sizeof(header));
  output.write(reinterpret_cast<const char*>(preview.data()), preview.size() * 4);
  assert(output.good());
  Gdiplus::GdiplusShutdown(token);
}
