import 'package:flutter/material.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/common/rh_store.dart';

/// 应用首次启动引导：载入本地店名；未配置则弹出强制配置窗，
/// 已配置则在后台做一次双向同步（恢复被删除门店的备注等）。
Future<void> rhStoreBootstrap() async {
  final svc = RhStoreService.instance;
  await svc.loadCurrentStoreName();
  if (!await svc.isSetupDone()) {
    showRhStoreSetupDialog();
  } else {
    svc.syncOnStart();
  }
}

/// 首次启动门店配置弹窗。
///
/// 特性：
/// - 模态且不可跳过：不提供取消/关闭按钮，点遮罩与返回键默认不关闭
///   （gFFI.dialogManager.show 默认 clickMaskDismiss/backDismiss 均为 false）。
/// - 仅店名一项：不展示 API 服务器地址与 Token 输入（服务端参数走构建注入）。
/// - 非空校验：留空时提示且禁止提交。
/// - 失败可重试：同步失败展示错误并允许再次提交。
void showRhStoreSetupDialog() {
  gFFI.dialogManager.show((setState, close, context) {
    final ctrl = TextEditingController();
    String errMsg = '';
    bool submitting = false;

    Future<void> submit() async {
      final name = ctrl.text.trim();
      if (name.isEmpty) {
        setState(() => errMsg = '店名不能为空');
        return;
      }
      setState(() {
        submitting = true;
        errMsg = '';
      });
      final result = await RhStoreService.instance.submitStoreName(name);
      if (!context.mounted) return;
      if (result.ok) {
        close();
      } else {
        setState(() {
          submitting = false;
          errMsg = '${result.error}，请重试';
        });
      }
    }

    Widget buildInput() {
      return TextField(
        controller: ctrl,
        autofocus: true,
        enabled: !submitting,
        decoration: InputDecoration(
          labelText: '门店名称',
          hintText: RhStoreConfig.storeNamePlaceholder,
          errorText: errMsg.isEmpty ? null : errMsg,
          border: const OutlineInputBorder(),
        ),
        onChanged: (_) {
          if (errMsg.isNotEmpty) setState(() => errMsg = '');
        },
        onSubmitted: (_) => submitting ? null : submit(),
      );
    }

    Widget dialog = AlertDialog(
      title: const Text('首次启动配置'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请输入本店店名，用于远程工具标识与通讯录显示。'),
            const SizedBox(height: 16),
            buildInput(),
            const SizedBox(height: 12),
            if (submitting)
              const Row(
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('正在同步到服务器…'),
                ],
              ),
          ],
        ),
      ),
      actions: [
        ElevatedButton(
          onPressed: submitting ? null : () => submit(),
          child: const Text('确认并同步'),
        ),
      ],
    );

    // 桌面端套用统一弹窗外观（项目内 CustomAlertDialog 提供的视觉风格）。
    return dialog;
  });
}
