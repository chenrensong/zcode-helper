#ifndef RUNNER_ZCODE_BRIDGE_H_
#define RUNNER_ZCODE_BRIDGE_H_

#include <flutter/flutter_engine.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>
#include <string>

/// Flutter 与 Windows 原生能力之间的桥（与 macOS 版 ZcodeBridge 对齐）。
///
/// 覆盖：进程枚举/结束、ZCode 启动、打开 URL、主机身份、
/// zcode:// 协议登录回调的接管与转发。
/// 登录方案与 macOS 不同：Windows 上自定义协议由注册表派发，
/// 接管（HKCU 写入）后浏览器回调会以命令行参数拉起本应用，
/// 单实例互斥量 + 命名管道把回调转给已运行实例，
/// 因此同样无需关闭正在运行的 ZCode。
class ZcodeBridge {
 public:
  static ZcodeBridge& Instance();

  /// 注册 MethodChannel（FlutterEngine 就绪后调用，主线程）。
  void Register(flutter::FlutterEngine* engine);

  /// 启动回调管道监听线程（首个实例启动时调用）。
  void StartPipeListener();

  /// 送达一条 zcode:// 回调 URL（管道转发 / 本进程启动参数）。
  void DeliverCallbackUrl(const std::string& url);

  /// 暂存启动命令行中的 zcode:// 回调（引擎就绪后投递给 Dart）。
  void SetPendingUrl(const std::string& url);

  /// 把已运行实例的主窗口带到前台（第二实例激活请求）。
  void ActivateMainWindow();

  /// 应用退出兜底：若仍接管着 zcode:// 协议则恢复注册表
  /// （正常流程 closeOAuthWindow 已恢复，这里防异常路径残留）。
  void RestoreProtocolIfNeeded();

 private:
  ZcodeBridge() = default;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

  /// 接管 zcode:// 协议（覆盖前保存旧 shell\open\command 便于恢复）。
  bool ClaimZcodeProtocol();

  /// 恢复 zcode:// 协议（有旧值则写回，原本不存在才整键删除）。
  void RestoreZcodeProtocol();

  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
  std::string pending_url_;
  bool claimed_protocol_ = false;
  // 接管前 HKCU zcode\shell\open\command 的旧值
  // （had_protocol_command_ = false 表示原本不存在或为空）。
  std::wstring saved_protocol_command_;
  bool had_protocol_command_ = false;
};

#endif  // RUNNER_ZCODE_BRIDGE_H_
