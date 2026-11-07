#include "single_instance.h"

#include <flutter_windows.h>

#include <cstdint>
#include <string>
#include <vector>

namespace halo {
namespace {

// The window class the runner registers in win32_window.cpp. Duplicated here
// because that constant lives in an anonymous namespace; both are the Flutter
// runner default and neither is user-visible.
constexpr wchar_t kWindowClassName[] = L"FLUTTER_RUNNER_WIN32_WINDOW";

// Held for the life of the process and never closed on purpose: Windows
// releases it when the last handle goes away, including after a crash.
HANDLE g_ui_mutex = nullptr;

std::wstring Utf8ToWide(const std::string& text) {
  if (text.empty()) return std::wstring();
  int size = ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                                   static_cast<int>(text.size()), nullptr, 0);
  std::wstring wide(static_cast<size_t>(size), L'\0');
  ::MultiByteToWideChar(CP_UTF8, 0, text.c_str(),
                        static_cast<int>(text.size()), wide.data(), size);
  return wide;
}

// The directory the UI reads its database from. It must match resolveDataDir()
// in apps/flutter/lib/main.dart and resolveDir() in the host, otherwise two
// windows could show the same data through different locks.
std::wstring ResolveDataDir() {
  wchar_t buffer[MAX_PATH * 2];
  DWORD len = ::GetEnvironmentVariableW(L"HALO_DATA_DIR", buffer,
                                        static_cast<DWORD>(std::size(buffer)));
  if (len > 0 && len < std::size(buffer)) {
    return std::wstring(buffer, len);
  }

  std::wstring exe_dir;
  len = ::GetModuleFileNameW(nullptr, buffer, static_cast<DWORD>(std::size(buffer)));
  if (len > 0) {
    exe_dir.assign(buffer, len);
    size_t slash = exe_dir.find_last_of(L"\\/");
    if (slash != std::wstring::npos) exe_dir.resize(slash);
  }

  if (!exe_dir.empty()) {
    std::wstring flag = exe_dir + L"\\portable.flag";
    if (::GetFileAttributesW(flag.c_str()) != INVALID_FILE_ATTRIBUTES) {
      return exe_dir + L"\\user-data";
    }
  }

  len = ::GetEnvironmentVariableW(L"LOCALAPPDATA", buffer,
                                  static_cast<DWORD>(std::size(buffer)));
  if (len > 0 && len < std::size(buffer)) {
    return std::wstring(buffer, len) + L"\\clash-halo";
  }
  return L"clash-halo";
}

// A stable, filesystem-safe key for |path|.
//
// Deliberately the same shape as the host's pipe suffix so a diagnostic that
// shows one is recognisable in the other: backslashes to slashes, lower case,
// then FNV-1a 64 rendered as unpadded hex.
std::wstring DataDirKey(const std::wstring& path) {
  std::string utf8;
  int size = ::WideCharToMultiByte(CP_UTF8, 0, path.c_str(),
                                   static_cast<int>(path.size()), nullptr, 0,
                                   nullptr, nullptr);
  if (size > 0) {
    utf8.resize(static_cast<size_t>(size));
    ::WideCharToMultiByte(CP_UTF8, 0, path.c_str(),
                          static_cast<int>(path.size()), utf8.data(), size,
                          nullptr, nullptr);
  }

  std::string normalised;
  normalised.reserve(utf8.size());
  for (char c : utf8) {
    if (c == '\\') c = '/';
    if (c >= 'A' && c <= 'Z') c = static_cast<char>(c - 'A' + 'a');
    // Collapse repeated separators so "C:\a\\b" and "C:\a\b" agree.
    if (c == '/' && !normalised.empty() && normalised.back() == '/') continue;
    normalised.push_back(c);
  }
  while (!normalised.empty() && normalised.back() == '/') normalised.pop_back();

  uint64_t hash = 14695981039346656037ull;
  for (unsigned char c : normalised) {
    hash ^= static_cast<uint64_t>(c);
    hash *= 1099511628211ull;
  }

  static const wchar_t kDigits[] = L"0123456789abcdef";
  std::wstring hex;
  if (hash == 0) {
    hex = L"0";
  } else {
    wchar_t reversed[17];
    int n = 0;
    while (hash != 0) {
      reversed[n++] = kDigits[hash & 0xF];
      hash >>= 4;
    }
    for (int i = n - 1; i >= 0; --i) hex.push_back(reversed[i]);
  }
  return hex;
}

const std::wstring& KeyForThisInstall() {
  static const std::wstring key = DataDirKey(ResolveDataDir());
  return key;
}

// The window property that marks "this is the Clash Halo window for <key>".
// A property survives cross-process reads, so the second launch can find the
// first window without a shared memory block or an extra IPC endpoint.
std::wstring WindowPropertyName() {
  return L"ClashHaloUi." + KeyForThisInstall();
}

struct FindState {
  const wchar_t* property = nullptr;
  HWND found = nullptr;
};

BOOL CALLBACK FindWindowByProperty(HWND window, LPARAM param) {
  auto* state = reinterpret_cast<FindState*>(param);
  if (!::IsWindowVisible(window)) return TRUE;
  if (::GetPropW(window, state->property) == nullptr) return TRUE;
  state->found = window;
  return FALSE;
}

}  // namespace

bool AcquireUiSingleInstance() {
  const std::wstring name = L"Local\\ClashHaloUi." + KeyForThisInstall();
  g_ui_mutex = ::CreateMutexW(nullptr, TRUE, name.c_str());
  if (g_ui_mutex == nullptr) {
    // Failing to create the lock must not make the app unusable; the worst case
    // is the old behaviour of one window per launch.
    return true;
  }
  if (::GetLastError() == ERROR_ALREADY_EXISTS) {
    ::CloseHandle(g_ui_mutex);
    g_ui_mutex = nullptr;
    return false;
  }
  return true;
}

void MarkUiWindow(HWND window) {
  if (window == nullptr) return;
  const std::wstring property = WindowPropertyName();
  ::SetPropW(window, property.c_str(), reinterpret_cast<HANDLE>(1));
}

bool ActivateExistingWindow(int timeout_ms) {
  const std::wstring property = WindowPropertyName();
  const ULONGLONG deadline = ::GetTickCount64() + static_cast<ULONGLONG>(timeout_ms);

  while (true) {
    FindState state{property.c_str(), nullptr};
    ::EnumWindows(&FindWindowByProperty, reinterpret_cast<LPARAM>(&state));
    if (state.found != nullptr) {
      if (::IsIconic(state.found)) {
        ::ShowWindow(state.found, SW_RESTORE);
      }
      // SetForegroundWindow is refused when the calling process does not own
      // the foreground window. The launch came from Explorer or the tray, so
      // Windows usually permits it; flashing the taskbar button is the fallback
      // that still tells the user where the window is.
      if (!::SetForegroundWindow(state.found)) {
        FLASHWINFO info{};
        info.cbSize = sizeof(info);
        info.hwnd = state.found;
        info.dwFlags = FLASHW_TRAY | FLASHW_TIMERNOFG;
        info.uCount = 3;
        ::FlashWindowEx(&info);
      }
      return true;
    }
    if (::GetTickCount64() >= deadline) return false;
    ::Sleep(50);
  }
}

}  // namespace halo
