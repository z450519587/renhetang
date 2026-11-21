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
/// 注意：gFFI.dialogManager.show 内部用 StatefulBuilder，每次 setState 都会
/// 重新执行这里传入的 builder。因此输入框、提交状态、错误信息必须定义在
/// builder 外面，否则一点按钮就会被重置，表现为“点了没反应”。
void showRhStoreSetupDialog() {
  final ctrl = TextEditingController();
  String errMsg = '';
  bool submitting = false;
  bool closed = false;
  StateSetter? refreshDialog;
  void Function([dynamic])? rawClose;

  void refresh(VoidCallback fn) {
    if (!closed) refreshDialog?.call(fn);
  }

  void finish([dynamic res]) {
    if (closed) return;
    closed = true;
    rawClose?.call(res);
    ctrl.dispose();
  }

  Future<void> submit() async {
    if (submitting || closed) return;
    final name = ctrl.text.trim();
    if (name.isEmpty) {
      refresh(() => errMsg = '店名不能为空');
      return;
    }

    refresh(() {
      submitting = true;
      errMsg = '';
    });

    final result = await RhStoreService.instance.submitStoreName(name);
    if (closed) return;

    if (result.ok) {
      finish();
      showToast(
          result.warning.isNotEmpty ? result.warning : '店名已同步到仁和堂服务器');
    } else {
      refresh(() {
        submitting = false;
        errMsg = result.error.isEmpty ? '同步失败，请重试' : result.error;
      });
    }
  }

  gFFI.dialogManager.show((setState, close, context) {
    refreshDialog = setState;
    rawClose = close;

    return CustomAlertDialog(
      title: const Text('首次启动配置'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('请输入本店店名，用于远程工具标识与通讯录显示。'),
            const SizedBox(height: 16),
            TextField(
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
                if (errMsg.isNotEmpty) refresh(() => errMsg = '');
              },
              onSubmitted: (_) => submit(),
            ),
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
          onPressed: submitting ? null : submit,
          child: const Text('确认并同步'),
        ),
      ],
    );
  });
}
