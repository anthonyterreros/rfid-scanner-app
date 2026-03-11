import 'package:flutter/services.dart';

class UhfNativeTag {
  final String epc;
  final String tid;
  final String user;
  final String rssi;

  UhfNativeTag({
    required this.epc,
    required this.tid,
    required this.user,
    required this.rssi,
  });

  factory UhfNativeTag.fromMap(Map<dynamic, dynamic> map) {
    return UhfNativeTag(
      epc: (map['epc'] ?? '').toString(),
      tid: (map['tid'] ?? '').toString(),
      user: (map['user'] ?? '').toString(),
      rssi: (map['rssi'] ?? '').toString(),
    );
  }
}

class UhfNativeService {
  static const MethodChannel _channel = MethodChannel('vhc77p_uhf/methods');
  static const EventChannel _eventChannel = EventChannel('vhc77p_uhf/events');

  Future<bool> connectReader(String address) async {
    final result = await _channel.invokeMethod<bool>('connectReader', {
      'address': address,
    });
    return result ?? false;
  }

  Future<bool> disconnectReader() async {
    final result = await _channel.invokeMethod<bool>('disconnectReader');
    return result ?? false;
  }

  Future<bool> isReaderConnected() async {
    final result = await _channel.invokeMethod<bool>('isReaderConnected');
    return result ?? false;
  }

  Future<bool> startInventory() async {
    final result = await _channel.invokeMethod<bool>('startInventory');
    return result ?? false;
  }

  Future<bool> stopInventory() async {
    final result = await _channel.invokeMethod<bool>('stopInventory');
    return result ?? false;
  }

  Future<List<UhfNativeTag>> readTagsOnce() async {
    final result = await _channel.invokeMethod<List<dynamic>>('readTags');
    if (result == null) return [];
    return result
        .map((e) => UhfNativeTag.fromMap(Map<dynamic, dynamic>.from(e)))
        .toList();
  }

  Future<List<UhfNativeTag>> inventorySingle() async {
    final result = await _channel.invokeMethod<List<dynamic>>('inventorySingle');
    if (result == null) return [];
    return result
        .map((e) => UhfNativeTag.fromMap(Map<dynamic, dynamic>.from(e)))
        .toList();
  }

  Stream<List<UhfNativeTag>> inventoryStream() {
    return _eventChannel.receiveBroadcastStream().map((event) {
      final list = (event as List<dynamic>)
          .map((e) => UhfNativeTag.fromMap(Map<dynamic, dynamic>.from(e)))
          .toList();
      return list;
    });
  }
}