const IMAGE_MIME_EXTENSIONS: Record<string, string> = {
  "image/png": ".png",
  "image/jpeg": ".jpg",
  "image/gif": ".gif",
  "image/bmp": ".bmp",
  "image/tiff": ".tiff",
  "image/webp": ".webp",
};
const IMAGE_FILE_EXTENSIONS = new Set(Object.values(IMAGE_MIME_EXTENSIONS));

function fileExtension(name: string): string {
  const index = name.lastIndexOf(".");
  if (index < 0) return "";
  return name.slice(index).toLowerCase();
}

export function isImageAttachmentFile(file: Pick<File, "name" | "type">): boolean {
  const mimeType = file.type.toLowerCase();
  if (mimeType.startsWith("image/")) return true;
  return IMAGE_FILE_EXTENSIONS.has(fileExtension(file.name));
}

export function uploadFileName(file: Pick<File, "name" | "type">, fallbackBase: string): string {
  const original = file.name.trim();
  const extension =
    fileExtension(original) ||
    IMAGE_MIME_EXTENSIONS[file.type.toLowerCase()] ||
    ".bin";
  const base = original
    ? original.slice(0, original.length - fileExtension(original).length)
    : fallbackBase;
  return `${base || fallbackBase}${extension}`;
}

export function normalizeUploadFile(file: File, fallbackBase: string): File {
  const name = uploadFileName(file, fallbackBase);
  if (file.name === name) return file;
  return new File([file], name, {
    type: file.type || "application/octet-stream",
    lastModified: file.lastModified,
  });
}
