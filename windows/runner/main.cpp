#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>
#include <shellapi.h>

#include <string>

#include "flutter_window.h"
#include "utils.h"
#include "zcode_bridge.h"

namespace {

constexpr wchar_t kSingleInstanceMutex[] = L"Local\\zcodehelper.zcodehelper.single";
constexpr wchar_t kCallbackPipe[] = L"\\\\.\\pipe\\zcodehelper-callback";

// 命令行里找 zcode:// 参数（协议回调拉起本应用时）。
std::string ExtractZcodeUrlFromCommandLine() {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv) return std::string();
  std::string found;
  for (int i = 0; i < argc; ++i) {
    if (_wcsnicmp(argv[i], L"zcode://", 8) == 0) {
      int size = WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, nullptr, 0,
                                     nullptr, nullptr);
      std::string out(size - 1, 0);
      WideCharToMultiByte(CP_UTF8, 0, argv[i], -1, out.data(), size,
                          nullptr, nullptr);
      found = out;
      break;
    }
  }
  LocalFree(argv);
  return found;
}

// 第二实例：把消息写给已运行实例的回调管道。
void ForwardToRunningInstance(const std::string& message) {
  HANDLE pipe = CreateFileW(kCallbackPipe, GENERIC_WRITE, 0, nullptr,
                            OPEN_EXISTING, 0, nullptr);
  if (pipe == INVALID_HANDLE_VALUE) return;
  DWORD written = 0;
  WriteFile(pipe, message.c_str(), (DWORD)message.size(), &written, nullptr);
  CloseHandle(pipe);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // 单实例（与 macOS/Electron requestSingleInstanceLock 对齐）：
  // 第二实例激活已有窗口后退出；若因 zcode:// 回调被拉起，则把回调
  // 经命名管道转给已运行实例再退出。
  HANDLE single_instance_mutex =
      ::CreateMutexW(nullptr, TRUE, kSingleInstanceMutex);
  if (!single_instance_mutex || GetLastError() == ERROR_ALREADY_EXISTS) {
    std::string url = ExtractZcodeUrlFromCommandLine();
    ForwardToRunningInstance(url.empty() ? "ACTIVATE" : url);
    if (single_instance_mutex) ::CloseHandle(single_instance_mutex);
    return EXIT_SUCCESS;
  }

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  // 冷启动即带 zcode:// 回调：暂存，引擎就绪后由桥投递给 Dart。
  std::string startup_url = ExtractZcodeUrlFromCommandLine();
  if (!startup_url.empty()) {
    ZcodeBridge::Instance().SetPendingUrl(startup_url);
  }

  FlutterWindow window(project);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"zcode_helper", origin, size)) {
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // 退出兜底：登录流程接管过 zcode:// 协议而未正常恢复（异常路径）时
  // 补一次恢复，避免注册表残留把协议指到本应用。
  ZcodeBridge::Instance().RestoreProtocolIfNeeded();

  ::CoUninitialize();
  ::CloseHandle(single_instance_mutex);
  return EXIT_SUCCESS;
}
