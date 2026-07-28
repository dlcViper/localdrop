class FileEntry {
  final String name;
  final String relativePath;
  final bool isDirectory;
  final int size;
  final DateTime modified;
  final String? mimeType;

  const FileEntry({
    required this.name,
    required this.relativePath,
    required this.isDirectory,
    required this.size,
    required this.modified,
    this.mimeType,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'path': relativePath,
        'is_directory': isDirectory,
        'size': size,
        'modified': modified.toUtc().toIso8601String(),
        'type': isDirectory ? 'directory' : (mimeType ?? 'application/octet-stream'),
      };
}
