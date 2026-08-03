import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:nfc_manager/nfc_manager.dart';

import '../data/db.dart';
import '../services/sync_controller.dart';
import '../services/uploader.dart';
import '../theme.dart';
import '../widgets/nfc_scan_dialog.dart';

/// NFC 설정·동기화 화면.
///
/// 블루투스를 켠 상태에서 노드에 휴대폰을 갖다 대면
/// 태그를 읽고 → BLE 로 바이너리 프레임을 받아 → SQLite 에 저장한다.
/// 태그 자체에 프레임이 들어 있으면 BLE 단계는 건너뛴다.
class NfcSetupScreen extends StatefulWidget {
  const NfcSetupScreen({super.key, this.uploader});

  /// null 이면 SQLite 에만 저장하고 서버로 올리지 않는다.
  final Uploader? uploader;

  @override
  State<NfcSetupScreen> createState() => _NfcSetupScreenState();
}

class _NfcSetupScreenState extends State<NfcSetupScreen>
    with SingleTickerProviderStateMixin {
  late final SyncController _controller;
  late final AnimationController _pulse;
  late Future<NfcAvailability> _nfcAvailability;

  @override
  void initState() {
    super.initState();
    _controller = SyncController(
      db: SentinelDb.instance,
      uploader: widget.uploader,
    );
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat();
    _nfcAvailability = _controller.nfc.availability();
  }

  /// 세션을 열고, 태그를 대는 동안 창을 띄운다.
  /// 끝나면(완료·실패·취소) 창은 스스로 닫힌다.
  Future<void> _start() async {
    await _controller.start();
    if (!mounted || !_controller.isBusy) return;

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          if (!_controller.isBusy) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              final navigator = Navigator.of(dialogContext);
              if (navigator.canPop()) navigator.pop();
            });
          }
          return NfcScanDialog(
            phase: _controller.phase,
            progress: _controller.progress?.fraction,
            onCancel: _controller.isBusy ? _controller.cancel : null,
          );
        },
      ),
    );
  }

  @override
  void dispose() {
    _pulse.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // D-01: 웹 빌드에서는 NFC/BLE 화면을 숨긴다.
    if (kIsWeb) {
      return Scaffold(
        appBar: AppBar(title: const Text('NFC 연결')),
        body: const _Notice(
          icon: Icons.desktop_access_disabled,
          title: '웹에서는 사용할 수 없습니다',
          body: 'NFC 태깅과 BLE 다운로드는 앱에서만 동작합니다.',
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('NFC 연결')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final horizontal = constraints.maxWidth >= 600 ? 24.0 : 16.0;
          return SingleChildScrollView(
            padding: EdgeInsets.fromLTRB(
              horizontal,
              8,
              horizontal,
              24 + MediaQuery.paddingOf(context).bottom,
            ),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 520),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _BluetoothCard(controller: _controller),
                    const SizedBox(height: 10),
                    _NfcCard(future: _nfcAvailability),
                    const SizedBox(height: 24),
                    ListenableBuilder(
                      listenable: _controller,
                      builder: (context, _) => _SyncPanel(
                        controller: _controller,
                        pulse: _pulse,
                        onStart: _start,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _BluetoothCard extends StatelessWidget {
  const _BluetoothCard({required this.controller});

  final SyncController controller;

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<BluetoothAdapterState>(
      stream: controller.ble.adapterState,
      builder: (context, snapshot) {
        final state = snapshot.data ?? BluetoothAdapterState.unknown;
        final isOn = state == BluetoothAdapterState.on;
        final unsupported = state == BluetoothAdapterState.unavailable;

        return _StatusTile(
          icon: isOn ? Icons.bluetooth : Icons.bluetooth_disabled,
          title: '블루투스',
          subtitle: switch (state) {
            BluetoothAdapterState.on => '켜짐 — 노드에서 데이터를 받을 수 있습니다',
            BluetoothAdapterState.off => '꺼짐 — 켜야 데이터를 받을 수 있습니다',
            BluetoothAdapterState.unauthorized => '권한이 거부되었습니다',
            BluetoothAdapterState.unavailable => '이 기기는 블루투스를 지원하지 않습니다',
            _ => '상태 확인 중…',
          },
          ok: isOn,
          action: (isOn || unsupported)
              ? null
              : TextButton(
                  onPressed: controller.ble.turnOn,
                  child: const Text('켜기'),
                ),
        );
      },
    );
  }
}

class _NfcCard extends StatelessWidget {
  const _NfcCard({required this.future});

  final Future<NfcAvailability> future;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<NfcAvailability>(
      future: future,
      builder: (context, snapshot) {
        final availability = snapshot.data;
        return _StatusTile(
          icon: Icons.nfc,
          title: 'NFC',
          subtitle: switch (availability) {
            NfcAvailability.enabled => '켜짐 — 태그를 읽을 수 있습니다',
            NfcAvailability.disabled => '꺼짐 — 시스템 설정에서 켜주세요',
            NfcAvailability.unsupported => '이 기기는 NFC 를 지원하지 않습니다',
            null => '상태 확인 중…',
          },
          ok: availability == NfcAvailability.enabled,
        );
      },
    );
  }
}

class _StatusTile extends StatelessWidget {
  const _StatusTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.ok,
    this.action,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool ok;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: cardDecoration(),
      child: Row(
        children: [
          Icon(
            icon,
            size: 20,
            color: ok ? SentinelColors.pm25 : SentinelColors.textMuted,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    fontSize: 12,
                    color: SentinelColors.textSecondary,
                    height: 1.3,
                  ),
                ),
              ],
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

class _SyncPanel extends StatelessWidget {
  const _SyncPanel({
    required this.controller,
    required this.pulse,
    required this.onStart,
  });

  final SyncController controller;
  final Animation<double> pulse;
  final VoidCallback onStart;

  @override
  Widget build(BuildContext context) {
    final phase = controller.phase;
    final progress = controller.progress;

    final (title, body) = switch (phase) {
      SyncPhase.idle => ('노드에 갖다 대세요', '아래 버튼을 누른 뒤 휴대폰 뒷면을 노드의 NFC 표시에 대세요.'),
      SyncPhase.waitingTag => ('태그를 기다리는 중', '휴대폰 뒷면을 노드에 대고 있으세요.'),
      SyncPhase.connecting => ('노드에 접속 중', '블루투스로 연결하고 있습니다.'),
      SyncPhase.downloading => (
        '데이터 받는 중',
        progress == null
            ? '수신을 시작합니다…'
            : '${progress.received} / ${progress.expected ?? '?'} 바이트',
      ),
      SyncPhase.saving => ('저장 중', '받은 프레임을 검증하고 저장합니다.'),
      SyncPhase.uploading => ('서버로 올리는 중', '측정 데이터를 클라우드에 전송합니다.'),
      SyncPhase.done => (
        '동기화 완료',
        '${controller.deviceId ?? ''} · '
            '신규 ${controller.result?.inserted ?? 0}건 / '
            '중복 ${controller.result?.duplicated ?? 0}건'
            '${_uploadLabel(controller.uploadOutcome)}',
      ),
      SyncPhase.failed => ('동기화 실패', controller.error ?? '알 수 없는 오류'),
    };

    return Column(
      children: [
        _NfcTarget(phase: phase, pulse: pulse, progress: progress?.fraction),
        const SizedBox(height: 24),
        Text(
          title,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          body,
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 13,
            color: SentinelColors.textSecondary,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 24),
        // 진행 중에는 창(NfcScanDialog)이 떠 있으므로 버튼은 대기 상태에서만.
        FilledButton(
          onPressed: controller.isBusy ? null : onStart,
          child: Text(phase == SyncPhase.done ? '한 번 더 읽기' : '태그 읽기 시작'),
        ),
      ],
    );
  }
}

/// 업로드는 실패해도 저장은 이미 끝나 있으므로 실패로 표시하지 않는다.
String _uploadLabel(UploadOutcome? outcome) {
  if (outcome == null) return '';
  if (outcome.isComplete) return '\n서버 업로드 완료';
  return '\n서버 업로드 대기 ${outcome.remaining}건 — 나중에 다시 시도합니다';
}

class _NfcTarget extends StatelessWidget {
  const _NfcTarget({
    required this.phase,
    required this.pulse,
    this.progress,
  });

  final SyncPhase phase;
  final Animation<double> pulse;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final (color, icon) = switch (phase) {
      SyncPhase.done => (SentinelColors.okFg, Icons.check_rounded),
      SyncPhase.failed => (SentinelColors.dangerFg, Icons.close_rounded),
      _ => (SentinelColors.pm25, Icons.nfc),
    };
    final animating =
        phase == SyncPhase.waitingTag || phase == SyncPhase.connecting;

    return SizedBox(
      height: 180,
      child: Center(
        child: AnimatedBuilder(
          animation: pulse,
          builder: (context, child) {
            return Stack(
              alignment: Alignment.center,
              children: [
                if (animating)
                  Container(
                    width: 120 + 50 * pulse.value,
                    height: 120 + 50 * pulse.value,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: color.withValues(alpha: 0.12 * (1 - pulse.value)),
                    ),
                  ),
                if (phase == SyncPhase.downloading ||
                    phase == SyncPhase.saving)
                  SizedBox(
                    width: 132,
                    height: 132,
                    child: CircularProgressIndicator(
                      value: phase == SyncPhase.saving ? null : progress,
                      strokeWidth: 3,
                      color: color,
                      backgroundColor: SentinelColors.border,
                    ),
                  ),
                child!,
              ],
            );
          },
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: SentinelColors.surface,
              border: Border.all(color: color.withValues(alpha: 0.4), width: 2),
            ),
            child: Icon(icon, size: 46, color: color),
          ),
        ),
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.body,
  });

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 40, color: SentinelColors.textMuted),
            const SizedBox(height: 14),
            Text(
              title,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: SentinelColors.textSecondary,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
