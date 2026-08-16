#include "zcode_bridge.h"

#include <flutter/encodable_value.h>
#include <flutter/method_result.h>
#include <flutter/standard_method_codec.h>

#include <windows.h>
#include <lmcons.h>
#include <shellapi.h>
#include <shlobj.h>
#include <tlhelp32.h>
#include <wchar.h>

#include <thread>
#include <vector>

namespace {

constexpr char kChannelName[] = "zcode.helper/bridge";
constexpr wchar_t kPipeName[] = L"\\\\.\\pipe\\zcodehelper-callback";
constexpr wchar_t kProtocolKey[] = L"Software\\Classes\\zcode";
constexpr wchar_t kProtocolCommandKey[] =
    L"Software\\Classes\\zcode\\shell\\open\\command";
constexpr wchar_t kMainWindowTitle[] = L"zcode_helper";
constexpr UINT kwmCallbackDeliver = WM_APP + 0x5A;

std::string WideToUtf8(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  int size = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(),
                                 nullptr, 0, nullptr, nullptr);
  std::string out(size, 0);
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), (int)wide.size(), out.data(),
                      size, nullptr, nullptr);
  return out;
}

std::wstring Utf8ToWide(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int size = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(),
                                 nullptr, 0);
  std::wstring out(size, 0);
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), out.data(),
                      size);
  return out;
}

bool IEqualsW(const wchar_t* a, const wchar_t* b) {
  return _wcsicmp(a, b) == 0;
}

std::wstring GetOwnExePath() {
  wchar_t path[MAX_PATH] = {0};
  GetModuleFileNameW(nullptr, path, MAX_PATH);
  return path;
}

// ZCode.exe 安装候选（与 Electron 版 paths.js ZCODE_EXE_CANDIDATES 对齐）。
std::wstring FindZcodeExePath() {
  wchar_t program_files[MAX_PATH] = {0};
  wchar_t program_files_x86[MAX_PATH] = {0};
  wchar_t local_appdata[MAX_PATH] = {0};
  SHGetFolderPathW(nullptr, CSIDL_PROGRAM_FILES, nullptr, 0, program_files);
  SHGetFolderPathW(nullptr, CSIDL_PROGRAM_FILESX86, nullptr, 0,
                   program_files_x86);
  SHGetFolderPathW(nullptr, CSIDL_LOCAL_APPDATA, nullptr, 0, local_appdata);

  std::vector<std::wstring> candidates = {
      std::wstring(program_files) + L"\\ZCode\\ZCode.exe",
      std::wstring(program_files_x86) + L"\\ZCode\\ZCode.exe",
      std::wstring(local_appdata) + L"\\Programs\\ZCode\\ZCode.exe",
      L"D:\\Program Files\\ZCode\\ZCode.exe",
  };
  for (const auto& candidate : candidates) {
    if (GetFileAttributesW(candidate.c_str()) != INVALID_FILE_ATTRIBUTES) {
      return candidate;
    }
  }
  return std::wstring();
}

HWND FindMainWindow() {
  return FindWindowW(nullptr, kMainWindowTitle);
}

// 可见顶层窗口（属主 pid + 标题），用于识别多开实例主窗口。
struct ZcodeWindowTitle {
  DWORD pid;
  std::wstring title;
};

// EnumWindows 回调：只收集标题以 "ZCode [" 开头的可见顶层窗口
// （多开实例主窗口标题固定为 "ZCode [实例名]"，与 macOS 版一致；
// 普通主客户端窗口标题不带该前缀，不参与收集）。
BOOL CALLBACK CollectZcodeInstanceWindows(HWND hwnd, LPARAM lparam) {
  if (!IsWindowVisible(hwnd)) return TRUE;
  wchar_t title[256] = {0};
  if (GetWindowTextW(hwnd, title, 256) <= 0) return TRUE;
  if (wcsncmp(title, L"ZCode [", 7) != 0) return TRUE;
  DWORD pid = 0;
  GetWindowThreadProcessId(hwnd, &pid);
  if (pid == 0) return TRUE;
  reinterpret_cast<std::vector<ZcodeWindowTitle>*>(lparam)->push_back(
      ZcodeWindowTitle{pid, std::wstring(title)});
  return TRUE;
}

// 隐藏消息窗口：把管道线程收到的回调 marshal 到主线程再投递给 Dart。
// 窗口必须在主线程创建（Ensure 于 Register 调用），管道线程只 PostMessage。
struct BridgeMsgWindow {
  HWND hwnd = nullptr;
  static LRESULT CALLBACK WndProc(HWND hwnd, UINT msg, WPARAM wparam,
                                  LPARAM lparam) {
    if (msg == kwmCallbackDeliver) {
      auto* payload = reinterpret_cast<std::string*>(lparam);
      if (payload) {
        if (*payload == "\x01" "ACTIVATE") {
          ZcodeBridge::Instance().ActivateMainWindow();
        } else {
          ZcodeBridge::Instance().DeliverCallbackUrl(*payload);
        }
        delete payload;
      }
      return 0;
    }
    return DefWindowProcW(hwnd, msg, wparam, lparam);
  }

  void Ensure() {
    if (hwnd) return;
    WNDCLASSW wc = {0};
    wc.lpfnWndProc = WndProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.lpszClassName = L"ZcodeBridgeMsgWindow";
    RegisterClassW(&wc);
    // HWND_MESSAGE：仅消息窗口，不显示。
    hwnd = CreateWindowW(wc.lpszClassName, L"", 0, 0, 0, 0, 0, HWND_MESSAGE,
                         nullptr, wc.hInstance, nullptr);
  }

  void Post(const std::string& payload) {
    if (!hwnd) return;
    auto* heap_payload = new std::string(payload);
    if (!PostMessageW(hwnd, kwmCallbackDeliver, 0,
                      reinterpret_cast<LPARAM>(heap_payload))) {
      delete heap_payload;
    }
  }
};

BridgeMsgWindow& MsgWindow() {
  static BridgeMsgWindow window;
  return window;
}

}  // namespace

// 把 zcode:// 协议派发到本应用（HKCU，无需管理员）。
// 覆盖前先保存旧的 shell\open\command（可能是 ZCode 安装器或用户
// 自定义的处理器），RestoreZcodeProtocol 据此原样写回，避免接管
// 残留顶掉用户原有配置。
bool ZcodeBridge::ClaimZcodeProtocol() {
  // 记录旧值：值不存在或为空都记为“原本无处理器”，恢复时走删除分支。
  had_protocol_command_ = false;
  saved_protocol_command_.clear();
  HKEY existing = nullptr;
  if (RegOpenKeyExW(HKEY_CURRENT_USER, kProtocolCommandKey, 0, KEY_QUERY_VALUE,
                    &existing) == ERROR_SUCCESS) {
    wchar_t buffer[MAX_PATH * 2] = {0};
    DWORD size = sizeof(buffer);
    DWORD type = 0;
    if (RegQueryValueExW(existing, nullptr, nullptr, &type, (BYTE*)buffer,
                         &size) == ERROR_SUCCESS &&
        type == REG_SZ && size > sizeof(wchar_t)) {
      saved_protocol_command_ = std::wstring(buffer, size / sizeof(wchar_t) - 1);
      had_protocol_command_ = true;
    }
    RegCloseKey(existing);
  }

  HKEY key = nullptr;
  if (RegCreateKeyExW(HKEY_CURRENT_USER, kProtocolKey, 0, nullptr,
                      REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr, &key,
                      nullptr) != ERROR_SUCCESS) {
    return false;
  }
  const wchar_t* empty = L"";
  RegSetValueExW(key, nullptr, 0, REG_SZ, (const BYTE*)empty,
                 sizeof(wchar_t));
  RegSetValueExW(key, L"URL Protocol", 0, REG_SZ, (const BYTE*)empty,
                 sizeof(wchar_t));

  HKEY cmd_key = nullptr;
  bool ok = false;
  if (RegCreateKeyExW(key, L"shell\\open\\command", 0, nullptr,
                      REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr,
                      &cmd_key, nullptr) == ERROR_SUCCESS) {
    // "\"C:\...\zcode_helper.exe\" \"%1\""
    std::wstring cmd = L"\"" + GetOwnExePath() + L"\" \"%1\"";
    RegSetValueExW(cmd_key, nullptr, 0, REG_SZ, (const BYTE*)cmd.c_str(),
                   (DWORD)((cmd.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(cmd_key);
    ok = true;
  }
  RegCloseKey(key);
  return ok;
}

// 撤销接管：接管前有旧 shell\open\command 则原样写回（恢复 ZCode
// 官方或用户自定义的处理器）；仅当原本不存在时才删除 HKCU 覆盖项，
// 此时 ZCode 在 HKLM 注册过协议则自动继续生效。
void ZcodeBridge::RestoreZcodeProtocol() {
  if (had_protocol_command_) {
    HKEY cmd_key = nullptr;
    if (RegCreateKeyExW(HKEY_CURRENT_USER, kProtocolCommandKey, 0, nullptr,
                        REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, nullptr,
                        &cmd_key, nullptr) == ERROR_SUCCESS) {
      const std::wstring& cmd = saved_protocol_command_;
      RegSetValueExW(cmd_key, nullptr, 0, REG_SZ, (const BYTE*)cmd.c_str(),
                     (DWORD)((cmd.size() + 1) * sizeof(wchar_t)));
      RegCloseKey(cmd_key);
    }
  } else {
    RegDeleteTreeW(HKEY_CURRENT_USER, kProtocolKey);
  }
  had_protocol_command_ = false;
  saved_protocol_command_.clear();
}

void ZcodeBridge::RestoreProtocolIfNeeded() {
  if (claimed_protocol_) {
    RestoreZcodeProtocol();
    claimed_protocol_ = false;
  }
}

ZcodeBridge& ZcodeBridge::Instance() {
  static ZcodeBridge bridge;
  return bridge;
}

void ZcodeBridge::Register(flutter::FlutterEngine* engine) {
  // 主线程创建消息窗口（管道线程随后只 PostMessage）。
  MsgWindow().Ensure();

  channel_ = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      engine->messenger(), kChannelName,
      // Flutter 3.47:StandardMethodCodec 已非模板类,GetInstance() 无模板参数
      &flutter::StandardMethodCodec::GetInstance());

  channel_->SetMethodCallHandler(
      [this](const flutter::MethodCall<flutter::EncodableValue>& call,
             std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>
                 result) {
        HandleMethodCall(call, std::move(result));
      });

  // 冷启动即带回调（浏览器拉起本应用时）：引擎就绪后立即投递。
  if (!pending_url_.empty()) {
    std::string url = pending_url_;
    pending_url_.clear();
    DeliverCallbackUrl(url);
  }
}

void ZcodeBridge::DeliverCallbackUrl(const std::string& url) {
  if (!channel_ || url.empty()) return;
  flutter::EncodableMap args;
  args[flutter::EncodableValue("url")] = flutter::EncodableValue(url);
  channel_->InvokeMethod("onOAuthCallback",
                         std::make_unique<flutter::EncodableValue>(args));
}

void ZcodeBridge::SetPendingUrl(const std::string& url) {
  pending_url_ = url;
}

void ZcodeBridge::ActivateMainWindow() {
  HWND hwnd = FindMainWindow();
  if (hwnd) {
    ShowWindow(hwnd, SW_RESTORE);
    SetForegroundWindow(hwnd);
  }
}

void ZcodeBridge::StartPipeListener() {
  std::thread([] {
    for (;;) {
      HANDLE pipe = CreateNamedPipeW(
          kPipeName, PIPE_ACCESS_INBOUND,
          PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 4096, 4096, 0,
          nullptr);
      if (pipe == INVALID_HANDLE_VALUE) {
        Sleep(500);
        continue;
      }
      if (!ConnectNamedPipe(pipe, nullptr) && GetLastError() != ERROR_PIPE_CONNECTED) {
        CloseHandle(pipe);
        continue;
      }
      std::string message;
      char buffer[1024];
      DWORD read = 0;
      while (ReadFile(pipe, buffer, sizeof(buffer), &read, nullptr) && read > 0) {
        message.append(buffer, buffer + read);
      }
      CloseHandle(pipe);

      if (message.rfind("zcode://", 0) == 0) {
        // 回调 → 主线程投递给 Dart。
        MsgWindow().Post(message);
      } else if (message == "ACTIVATE") {
        MsgWindow().Post("\x01" "ACTIVATE");  // 借道主线程激活窗口
      }
    }
  }).detach();
}

void ZcodeBridge::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = call.method_name();

  if (method == "listRunningZcode") {
    // 主进程 = 可执行名 ZCode.exe。上报 name 用多开实例主窗口标题
    // （"ZCode [实例名]"，Dart 侧按名称认领实例，与 macOS 语义对齐）；
    // 主客户端等取不到实例标题的进程保持 "ZCode"。
    std::vector<ZcodeWindowTitle> instance_windows;
    EnumWindows(CollectZcodeInstanceWindows,
                reinterpret_cast<LPARAM>(&instance_windows));
    flutter::EncodableList processes;
    HANDLE snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
    if (snapshot != INVALID_HANDLE_VALUE) {
      PROCESSENTRY32W entry;
      entry.dwSize = sizeof(entry);
      if (Process32FirstW(snapshot, &entry)) {
        do {
          if (IEqualsW(entry.szExeFile, L"ZCode.exe")) {
            std::wstring instance_title;
            for (const auto& window : instance_windows) {
              if (window.pid == entry.th32ProcessID) {
                instance_title = window.title;
                break;
              }
            }
            flutter::EncodableMap item;
            item[flutter::EncodableValue("pid")] =
                flutter::EncodableValue((int32_t)entry.th32ProcessID);
            item[flutter::EncodableValue("name")] = flutter::EncodableValue(
                instance_title.empty() ? std::string("ZCode")
                                       : WideToUtf8(instance_title));
            processes.push_back(flutter::EncodableValue(item));
          }
        } while (Process32NextW(snapshot, &entry));
      }
      CloseHandle(snapshot);
    }
    result->Success(flutter::EncodableValue(processes));
    return;
  }

  if (method == "terminatePids") {
    std::vector<int> pids;
    const auto* map = std::get_if<flutter::EncodableMap>(call.arguments());
    if (map) {
      auto it = map->find(flutter::EncodableValue("pids"));
      if (it != map->end()) {
        if (auto* list = std::get_if<flutter::EncodableList>(&it->second)) {
          for (const auto& value : *list) {
            if (auto pid = std::get_if<int32_t>(&value)) {
              pids.push_back(*pid);
            }
          }
        }
      }
    }
    flutter::EncodableMap terminated;
    for (int pid : pids) {
      HANDLE process = OpenProcess(PROCESS_TERMINATE | SYNCHRONIZE, FALSE,
                                   (DWORD)pid);
      bool ok = false;
      if (process) {
        ok = TerminateProcess(process, 0) != FALSE;
        if (ok) {
          WaitForSingleObject(process, 3000);
        }
        CloseHandle(process);
      }
      terminated[flutter::EncodableValue(std::to_string(pid))] =
          flutter::EncodableValue(ok);
    }
    result->Success(flutter::EncodableValue(terminated));
    return;
  }

  if (method == "launchZCode") {
    std::wstring exe;
    if (const auto* map = std::get_if<flutter::EncodableMap>(call.arguments())) {
      auto it = map->find(flutter::EncodableValue("path"));
      if (it != map->end()) {
        if (auto* path = std::get_if<std::string>(&it->second)) {
          exe = Utf8ToWide(*path);
        }
      }
    }
    if (exe.empty() || GetFileAttributesW(exe.c_str()) == INVALID_FILE_ATTRIBUTES) {
      exe = FindZcodeExePath();
    }
    if (exe.empty()) {
      result->Success(flutter::EncodableValue(false));
      return;
    }
    HINSTANCE opened = ShellExecuteW(nullptr, L"open", exe.c_str(), nullptr,
                                     nullptr, SW_SHOWNORMAL);
    result->Success(flutter::EncodableValue((INT_PTR)opened > 32));
    return;
  }

  if (method == "openUrl") {
    std::string url;
    if (const auto* map = std::get_if<flutter::EncodableMap>(call.arguments())) {
      auto it = map->find(flutter::EncodableValue("url"));
      if (it != map->end()) {
        if (auto* value = std::get_if<std::string>(&it->second)) {
          url = *value;
        }
      }
    }
    HINSTANCE opened = ShellExecuteW(nullptr, L"open", Utf8ToWide(url).c_str(),
                                     nullptr, nullptr, SW_SHOWNORMAL);
    result->Success(flutter::EncodableValue((INT_PTR)opened > 32));
    return;
  }

  if (method == "hostIdentity") {
    wchar_t home[MAX_PATH] = {0};
    wchar_t user[UNLEN + 1] = {0};
    DWORD user_size = UNLEN + 1;
    GetEnvironmentVariableW(L"USERPROFILE", home, MAX_PATH);
    GetUserNameW(user, &user_size);
    flutter::EncodableMap identity;
    identity[flutter::EncodableValue("home")] =
        flutter::EncodableValue(WideToUtf8(home));
    identity[flutter::EncodableValue("user")] =
        flutter::EncodableValue(WideToUtf8(user));
    result->Success(flutter::EncodableValue(identity));
    return;
  }

  if (method == "openOAuthWindow") {
    // Windows 方案：接管 zcode:// 协议（HKCU）+ 系统浏览器。
    // 回调由 shell 以命令行拉起本应用，单实例管道转回。
    bool ok = ClaimZcodeProtocol();
    if (ok) {
      claimed_protocol_ = true;
      std::string url;
      if (const auto* map = std::get_if<flutter::EncodableMap>(call.arguments())) {
        auto it = map->find(flutter::EncodableValue("url"));
        if (it != map->end()) {
          if (auto* value = std::get_if<std::string>(&it->second)) {
            url = *value;
          }
        }
      }
      HINSTANCE opened = ShellExecuteW(nullptr, L"open",
                                       Utf8ToWide(url).c_str(), nullptr,
                                       nullptr, SW_SHOWNORMAL);
      ok = (INT_PTR)opened > 32;
    }
    result->Success(flutter::EncodableValue(ok));
    return;
  }

  if (method == "closeOAuthWindow") {
    if (claimed_protocol_) {
      RestoreZcodeProtocol();
      claimed_protocol_ = false;
    }
    result->Success(flutter::EncodableValue(true));
    return;
  }

  result->NotImplemented();
}
