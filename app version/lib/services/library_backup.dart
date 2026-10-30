import 'dart:convert';
import 'dart:io';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';

/// Save a backup through the native file picker, without opening a share sheet.
Future<bool> saveLibraryBackup(String json) async {
  if (Platform.isAndroid || Platform.isIOS) {
    return await const MethodChannel(
          'rhythm/files',
        ).invokeMethod<bool>('saveLibraryBackup', {'json': json}) ??
        false;
  }
  final location = await getSaveLocation(
    suggestedName: 'rhythm-library.json',
    acceptedTypeGroups: [
      const XTypeGroup(label: 'Library backup', extensions: ['json']),
    ],
  );
  if (location == null) return false;
  await XFile.fromData(
    utf8.encode(json),
    mimeType: 'application/json',
    name: 'rhythm-library.json',
  ).saveTo(location.path);
  return true;
}
