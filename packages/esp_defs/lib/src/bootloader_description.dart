import 'dart:convert';
import 'dart:typed_data';

import 'image_metadata.dart';

/// ESP-IDF bootloader description `esp_bootloader_desc_t` (ESP-IDF 5.2+), at
/// the start of a bootloader image's first segment.
///
/// @see [https://github.com/espressif/esp-idf/blob/master/components/bootloader_support/include/esp_bootloader_desc.h]
class BootloaderDescription {
  /// `ESP_BOOTLOADER_DESC_MAGIC_BYTE`
  static const magic = 0x50;

  /// `sizeof(esp_bootloader_desc_t)`
  static const size = 80;

  /// Where the description sits in a bootloader image: after the image
  /// header and the first segment's header.
  static const imageOffset = ImageHeader.size + 8;

  /// The first image offset past the description.
  static const imageEnd = imageOffset + size;

  const BootloaderDescription({
    required this.secureVersion,
    required this.version,
    required this.idfVersion,
    required this.dateTime,
    this.partitionTableOffset = 0,
  });

  /// Parse a description from the start of [buffer], or `null` if it holds
  /// none (too short, or no magic byte).
  static BootloaderDescription? fromBytesOrNull(Uint8List buffer) {
    if (buffer.length < size || buffer[0] != magic) return null;
    final view = ByteData.sublistView(buffer);
    String text(int start, int length) =>
        utf8.decode(buffer.sublist(start, start + length).takeWhile((b) => b != 0).toList(), allowMalformed: true);
    return BootloaderDescription(
      secureVersion: buffer[3],
      version: view.getUint32(4, Endian.little),
      idfVersion: text(8, 32),
      dateTime: text(40, 24),
      partitionTableOffset: view.getUint32(64, Endian.little),
    );
  }

  /// The description in the bootloader [image] (starting with its image
  /// header), or `null` if it is not an image or carries none (a bootloader
  /// older than ESP-IDF 5.2).
  static BootloaderDescription? fromImageOrNull(Uint8List image) {
    if (image.length < imageEnd || image[0] != ImageHeader.magic) return null;
    return fromBytesOrNull(Uint8List.sublistView(image, imageOffset, imageEnd));
  }

  final int secureVersion;
  final int version;
  final String idfVersion;
  final String dateTime;

  /// Where the partition table this bootloader reads is, or 0 if it doesn't
  /// record it: the field espressif/esp-idf#19102 proposes, in the first 4
  /// bytes of `reserved2`, which bootloaders without it leave 0.
  /// https://github.com/espressif/esp-idf/pull/19102
  // TODO: espressif/esp-idf#19102 is not merged; the field and its place in
  // reserved2 may change before it is. https://github.com/espressif/esp-idf/pull/19102
  final int partitionTableOffset;

  @override
  String toString() => 'BootloaderDescription(version: $version, idfVersion: $idfVersion, dateTime: $dateTime, '
      'secureVersion: $secureVersion, partitionTableOffset: 0x${partitionTableOffset.toRadixString(16)})';
}
