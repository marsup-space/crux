import 'dart:convert';
import 'dart:io';

/// Represents an image attached to a message.
///
/// Images can come from:
/// - A file path on disk (`/image <path>` command)
/// - Pasted from the clipboard (Ctrl+V when clipboard contains an image)
///
/// The image data is stored as base64-encoded bytes along with its
/// media type (e.g. `image/png`, `image/jpeg`), ready for inclusion
/// in LLM API requests.
class ImageAttachment {
  /// The media type of the image (e.g. `image/png`, `image/jpeg`).
  final String mediaType;

  /// The base64-encoded image data.
  final String base64Data;

  /// Optional human-readable label (e.g. file name or "clipboard").
  /// Used in UI display only, not sent to the API.
  final String label;

  const ImageAttachment({
    required this.mediaType,
    required this.base64Data,
    required this.label,
  });

  /// Creates an [ImageAttachment] from a file on disk.
  ///
  /// Reads the file bytes, base64-encodes them, and infers the
  /// media type from the file extension.
  static Future<ImageAttachment> fromFile(String path) async {
    final file = File(path);
    if (!await file.exists()) {
      throw FileNotFoundException(path);
    }
    final bytes = await file.readAsBytes();
    final base64Data = base64Encode(bytes);
    final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
    final mediaType = _mediaTypeForExt(ext);
    final label = path.split(Platform.pathSeparator).last;
    return ImageAttachment(
      mediaType: mediaType,
      base64Data: base64Data,
      label: label,
    );
  }

  /// Creates an [ImageAttachment] from raw bytes (e.g. clipboard image).
  static ImageAttachment fromBytes({
    required List<int> bytes,
    required String mediaType,
    String label = 'clipboard',
  }) {
    return ImageAttachment(
      mediaType: mediaType,
      base64Data: base64Encode(bytes),
      label: label,
    );
  }

  /// Serializes to a JSON-compatible map for persistence.
  Map<String, dynamic> toJson() => {
        'mediaType': mediaType,
        'base64Data': base64Data,
        'label': label,
      };

  /// Deserializes from a JSON-compatible map.
  static ImageAttachment fromJson(Map<String, dynamic> json) {
    return ImageAttachment(
      mediaType: json['mediaType'] as String,
      base64Data: json['base64Data'] as String,
      label: json['label'] as String? ?? '',
    );
  }

  /// Serializes a list of [ImageAttachment] to a JSON string.
  static String encodeList(List<ImageAttachment> images) {
    if (images.isEmpty) return '';
    return jsonEncode(images.map((i) => i.toJson()).toList());
  }

  /// Deserializes a list of [ImageAttachment] from a JSON string.
  static List<ImageAttachment> decodeList(String json) {
    if (json.isEmpty) return const [];
    try {
      final list = jsonDecode(json) as List<dynamic>;
      return list
          .map((e) => ImageAttachment.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Known image file extensions and their media types.
  static const Map<String, String> extensionMediaTypes = {
    'png': 'image/png',
    'jpg': 'image/jpeg',
    'jpeg': 'image/jpeg',
    'gif': 'image/gif',
    'webp': 'image/webp',
    'bmp': 'image/bmp',
    'ico': 'image/x-icon',
    'tiff': 'image/tiff',
    'tif': 'image/tiff',
    'svg': 'image/svg+xml',
  };

  /// Whether the given file extension is a supported image type.
  static bool isImageExtension(String ext) {
    return extensionMediaTypes.containsKey(ext.toLowerCase());
  }

  /// Infers the media type from a file extension.
  static String _mediaTypeForExt(String ext) {
    return extensionMediaTypes[ext.toLowerCase()] ?? 'image/png';
  }
}

class FileNotFoundException implements Exception {
  final String path;
  FileNotFoundException(this.path);
  @override
  String toString() => 'File not found: $path';
}
