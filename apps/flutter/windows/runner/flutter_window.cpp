#include "flutter_window.h"

#include <dwmapi.h>

#include <memory>
#include <optional>

#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include "flutter/generated_plugin_registrant.h"

namespace {

/// Window attribute that enables dark mode window decorations.
///
/// Redefined so this file builds against SDKs older than 10.0.22000.0.
#ifndef DWMWA_USE_IMMERSIVE_DARK_MODE
#define DWMWA_USE_IMMERSIVE_DARK_MODE 20
#endif

constexpr char kThemeChannel[] = "clash_halo/theme";
constexpr char kWindowChannel[] = "clash_halo/window";

}  // namespace

FlutterWindow::FlutterWindow(const flutter::DartProject& project)
    : project_(project) {}

FlutterWindow::~FlutterWindow() {}

bool FlutterWindow::OnCreate() {
  if (!Win32Window::OnCreate()) {
    return false;
  }

  RECT frame = GetClientArea();

  // The size here must match the window dimensions to avoid unnecessary surface
  // creation / destruction in the startup path.
  flutter_controller_ = std::make_unique<flutter::FlutterViewController>(
      frame.right - frame.left, frame.bottom - frame.top, project_);
  // Ensure that basic setup of the controller was successful.
  if (!flutter_controller_->engine() || !flutter_controller_->view()) {
    return false;
  }
  RegisterPlugins(flutter_controller_->engine());
  SetChildContent(flutter_controller_->view()->GetNativeWindow());

  // Let Dart drive the caption colour. The runner's own UpdateTheme() follows
  // the *system* theme, so a user who picks the dark UI on a light Windows still
  // got a white title bar over a dark window. Held in a function-local static
  // because there is exactly one window and this keeps the header unchanged.
  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      theme_channel;
  theme_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kThemeChannel,
          &flutter::StandardMethodCodec::GetInstance());
  theme_channel->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "setDark") {
          result->NotImplemented();
          return;
        }
        const auto* dark = std::get_if<bool>(call.arguments());
        if (dark == nullptr) {
          result->Error("bad_argument", "setDark expects a bool");
          return;
        }
        BOOL value = *dark ? TRUE : FALSE;
        DwmSetWindowAttribute(GetHandle(), DWMWA_USE_IMMERSIVE_DARK_MODE,
                              &value, sizeof(value));
        // DWM caches the caption until the non-client area is repainted. Setting
        // the attribute alone leaves the title bar in the *previous* theme's
        // colour until something resizes the window — measured by switching
        // 浅色 → 深色 and watching the caption stay white, then go black only
        // after maximise-and-restore.
        //
        // Three calls, because each one covers a different cache:
        //   * SWP_FRAMECHANGED re-evaluates the frame style,
        //   * RedrawWindow asks for the non-client area to be painted now
        //     rather than whenever the next unrelated paint happens,
        //   * SetWindowPos is what actually makes DWM re-read the attribute.
        // RedrawWindow before SetWindowPos would be undone by it, so the order
        // here is not arbitrary.
        SetWindowPos(GetHandle(), nullptr, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE |
                         SWP_FRAMECHANGED);
        RedrawWindow(GetHandle(), nullptr, nullptr,
                     RDW_FRAME | RDW_INVALIDATE | RDW_UPDATENOW);
        result->Success();
      });

  static std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_channel;
  window_channel =
      std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          flutter_controller_->engine()->messenger(), kWindowChannel,
          &flutter::StandardMethodCodec::GetInstance());
  window_channel->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        if (call.method_name() != "close") {
          result->NotImplemented();
          return;
        }
        // Closing the window is the one exit path that already works: the ×
        // button posts WM_CLOSE, `SetQuitOnClose(true)` in main.cpp ends the
        // message loop, and the process leaves with its COM and single-instance
        // state released. Calling exit(0) from Dart would skip all of that.
        //
        // Deferred by one message so the reply reaches Dart before the engine
        // goes away; the caller is not waiting on a process that no longer
        // exists. PostMessage is used rather than DestroyWindow so this runs on
        // the message loop, like the × button does.
        result->Success();
        ::PostMessage(GetHandle(), WM_CLOSE, 0, 0);
      });

  flutter_controller_->engine()->SetNextFrameCallback([&]() {
    this->Show();
  });

  // Flutter can complete the first frame before the "show window" callback is
  // registered. The following call ensures a frame is pending to ensure the
  // window is shown. It is a no-op if the first frame hasn't completed yet.
  flutter_controller_->ForceRedraw();

  return true;
}

void FlutterWindow::OnDestroy() {
  if (flutter_controller_) {
    flutter_controller_ = nullptr;
  }

  Win32Window::OnDestroy();
}

LRESULT
FlutterWindow::MessageHandler(HWND hwnd, UINT const message,
                              WPARAM const wparam,
                              LPARAM const lparam) noexcept {
  // Give Flutter, including plugins, an opportunity to handle window messages.
  if (flutter_controller_) {
    std::optional<LRESULT> result =
        flutter_controller_->HandleTopLevelWindowProc(hwnd, message, wparam,
                                                      lparam);
    if (result) {
      return *result;
    }
  }

  switch (message) {
    case WM_FONTCHANGE:
      flutter_controller_->engine()->ReloadSystemFonts();
      break;
  }

  return Win32Window::MessageHandler(hwnd, message, wparam, lparam);
}
