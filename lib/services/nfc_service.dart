import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:ndef_record/ndef_record.dart';
import 'package:nfc_manager/nfc_manager.dart';
import 'package:nfc_manager/nfc_manager_android.dart';
import 'package:nfc_manager/nfc_manager_ios.dart';

import '../data/packet.dart';

/// NFC 태그에서 읽어낸 내용.
sealed class NfcScanResult {
  const NfcScanResult();
}

/// 태그가 측정 데이터 프레임을 통째로 담고 있던 경우 — BLE 없이 끝난다.
class NfcFrameResult extends NfcScanResult {
  const NfcFrameResult(this.bytes);
  final Uint8List bytes;
}

/// 태그는 기기 식별 정보만 담고, 실제 데이터는 BLE 로 받아야 하는 경우.
class NfcHandshakeResult extends NfcScanResult {
  const NfcHandshakeResult(this.handshake);
  final NodeHandshake handshake;
}

class NfcService {
  bool _sessionActive = false;
  bool get isSessionActive => _sessionActive;

  Future<NfcAvailability> availability() {
    if (kIsWeb) return Future.value(NfcAvailability.unsupported);
    return NfcManager.instance.checkAvailability();
  }

  /// 태그를 한 번 읽고 세션을 닫는다.
  ///
  /// [onError] 는 iOS 에서 사용자가 팝업을 닫는 등 세션이 스스로 끝난 경우에도 불린다.
  Future<void> startSession({
    required void Function(NfcScanResult result) onResult,
    required void Function(Object error) onError,
  }) async {
    if (_sessionActive) return;
    _sessionActive = true;
    try {
      await NfcManager.instance.startSession(
        pollingOptions: {
          NfcPollingOption.iso14443,
          NfcPollingOption.iso15693,
          NfcPollingOption.iso18092,
        },
        alertMessageIos: '노드에 휴대폰 뒷면을 갖다 대세요',
        onDiscovered: (tag) async {
          try {
            onResult(await _read(tag));
            await stopSession(successMessageIos: '읽기 완료');
          } catch (e) {
            await stopSession(errorMessageIos: '$e');
            onError(e);
          }
        },
        onSessionErrorIos: (e) {
          _sessionActive = false;
          onError(e);
        },
      );
    } catch (e) {
      _sessionActive = false;
      onError(e);
    }
  }

  Future<void> stopSession({
    String? successMessageIos,
    String? errorMessageIos,
  }) async {
    if (!_sessionActive) return;
    _sessionActive = false;
    await NfcManager.instance.stopSession(
      alertMessageIos: successMessageIos,
      errorMessageIos: errorMessageIos,
    );
  }

  Future<NfcScanResult> _read(NfcTag tag) async {
    final message = await _readNdef(tag);

    if (message != null) {
      // 1) 태그에 프레임이 통째로 들어 있는가?
      for (final record in message.records) {
        if (SentinelPacket.looksLikeFrame(record.payload)) {
          return NfcFrameResult(record.payload);
        }
      }
      // 2) 핸드셰이크 텍스트인가?
      for (final record in message.records) {
        final text = _decodeText(record);
        if (text == null) continue;
        final handshake = NodeHandshake.tryParse(text);
        if (handshake != null) return NfcHandshakeResult(handshake);
      }
    }

    // 3) NDEF 가 없는 태그. UID 를 기기 ID 로 삼아 BLE 로 넘어간다.
    final uid = _tagUid(tag);
    if (uid != null) {
      return NfcHandshakeResult(NodeHandshake(deviceId: uid));
    }
    throw const NfcReadException('센티널 노드 태그가 아닙니다');
  }

  Future<NdefMessage?> _readNdef(NfcTag tag) async {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final ndef = NdefAndroid.from(tag);
        if (ndef == null) return null;
        return await ndef.getNdefMessage() ?? ndef.cachedNdefMessage;
      case TargetPlatform.iOS:
        final ndef = NdefIos.from(tag);
        if (ndef == null) return null;
        return await ndef.readNdef() ?? ndef.cachedNdefMessage;
      default:
        return null;
    }
  }

  String? _tagUid(NfcTag tag) {
    final android = NfcTagAndroid.from(tag);
    if (android != null) return _hex(android.id);
    final ios = MiFareIos.from(tag);
    if (ios != null) return _hex(ios.identifier);
    return null;
  }

  static String _hex(Uint8List bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().toUpperCase();

  /// NDEF Text 레코드(TNF=well-known, type='T')의 본문을 꺼낸다.
  /// 그 외 타입은 payload 를 그대로 UTF-8 로 해석해 본다.
  static String? _decodeText(NdefRecord record) {
    try {
      final isText =
          record.typeNameFormat == TypeNameFormat.wellKnown &&
          record.type.length == 1 &&
          record.type.first == 0x54; // 'T'
      if (isText) {
        if (record.payload.isEmpty) return null;
        final langLength = record.payload.first & 0x3F;
        return utf8.decode(record.payload.sublist(1 + langLength));
      }
      return utf8.decode(record.payload);
    } catch (_) {
      return null;
    }
  }
}

class NfcReadException implements Exception {
  const NfcReadException(this.message);
  final String message;
  @override
  String toString() => message;
}
