import 'package:flutter/material.dart';

import '../services/sync_controller.dart';
import '../theme.dart';

/// 태그를 갖다 대는 동안 뜨는 창. NFC Tools 앱과 같은 형태.
///
/// 위젯은 상태를 갖지 않는다 — [phase] 만 주면 그려지므로 데모에서도 그대로 쓴다.
class NfcScanDialog extends StatelessWidget {
  const NfcScanDialog({
    super.key,
    required this.phase,
    this.progress,
    this.onCancel,
  });

  final SyncPhase phase;

  /// 다운로드 진행률 0~1. 모르면 null.
  final double? progress;
  final VoidCallback? onCancel;

  static (String, String) labelsFor(SyncPhase phase) => switch (phase) {
    SyncPhase.waitingTag => ('NFC 태그 읽기', '노드에 휴대폰을 갖다 대세요'),
    SyncPhase.connecting => ('노드 접속', '블루투스로 연결하는 중입니다'),
    SyncPhase.downloading => ('데이터 수신', '측정 데이터를 받는 중입니다'),
    SyncPhase.saving => ('저장', '받은 데이터를 검증하고 저장합니다'),
    SyncPhase.uploading => ('서버 전송', '측정 데이터를 클라우드로 올립니다'),
    SyncPhase.done => ('완료', '동기화가 끝났습니다'),
    SyncPhase.failed => ('실패', '다시 시도해 주세요'),
    SyncPhase.idle => ('NFC 태그 읽기', '대기 중'),
  };

  @override
  Widget build(BuildContext context) {
    final (title, message) = labelsFor(phase);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 32),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
      clipBehavior: Clip.antiAlias,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: double.infinity,
            color: const Color(0xFF1B1B1B),
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Container(
            width: double.infinity,
            color: SentinelColors.surface,
            padding: const EdgeInsets.fromLTRB(24, 28, 24, 24),
            child: Column(
              children: [
                _Indicator(phase: phase, progress: progress),
                const SizedBox(height: 22),
                Text(
                  message,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 17,
                    color: SentinelColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
          if (onCancel != null)
            Container(
              decoration: const BoxDecoration(
                border: Border(
                  top: BorderSide(color: SentinelColors.border),
                ),
              ),
              child: SizedBox(
                width: double.infinity,
                child: TextButton(
                  onPressed: onCancel,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: const RoundedRectangleBorder(),
                    foregroundColor: SentinelColors.textPrimary,
                  ),
                  child: const Text('취소', style: TextStyle(fontSize: 16)),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Indicator extends StatelessWidget {
  const _Indicator({required this.phase, this.progress});

  final SyncPhase phase;
  final double? progress;

  @override
  Widget build(BuildContext context) {
    final (icon, color) = switch (phase) {
      SyncPhase.done => (Icons.check_rounded, SentinelColors.okFg),
      SyncPhase.failed => (Icons.close_rounded, SentinelColors.dangerFg),
      SyncPhase.downloading || SyncPhase.saving || SyncPhase.uploading => (
        Icons.download_rounded,
        SentinelColors.pm25,
      ),
      _ => (Icons.tap_and_play, SentinelColors.textPrimary),
    };

    final showRing =
        phase == SyncPhase.downloading ||
        phase == SyncPhase.saving ||
        phase == SyncPhase.uploading ||
        phase == SyncPhase.connecting;

    return SizedBox(
      height: 84,
      width: 84,
      child: Stack(
        alignment: Alignment.center,
        children: [
          if (showRing)
            SizedBox(
              height: 84,
              width: 84,
              child: CircularProgressIndicator(
                value: phase == SyncPhase.downloading ? progress : null,
                strokeWidth: 3,
                color: color,
                backgroundColor: SentinelColors.border,
              ),
            ),
          Icon(icon, size: 56, color: color),
        ],
      ),
    );
  }
}
