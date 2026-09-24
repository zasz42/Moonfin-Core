/// Resolves an alternative primary-image URL for an item, or null to use the
/// server's own image endpoint. Set by the app to swap in an external poster
/// provider (e.g. Better Posters / btttr.cc) without touching every call site.
typedef PrimaryImageOverride = String? Function(String itemId);

abstract class ImageApi {
  /// Global hook consulted by [getPrimaryImageUrl] implementations before they
  /// build the server URL. When it returns a non-null URL for an item, that
  /// URL is used verbatim and the server endpoint is bypassed.
  static PrimaryImageOverride? primaryImageOverride;

  String getPrimaryImageUrl(
    String itemId, {
    int? maxWidth,
    int? maxHeight,
    String? tag,
  });

  String getBackdropImageUrl(
    String itemId, {
    int? maxWidth,
    int? index,
    String? tag,
  });

  String getLogoImageUrl(
    String itemId, {
    int? maxWidth,
    String? tag,
  });

  String getBannerImageUrl(
    String itemId, {
    int? maxWidth,
    String? tag,
  });

  String getThumbImageUrl(
    String itemId, {
    int? maxWidth,
    String? tag,
  });

  String getChapterImageUrl(
    String itemId, {
    required int index,
    int? maxWidth,
    String? tag,
  });

  String getUserImageUrl(String userId);

  String getTrickplayTileImageUrl(
    String itemId, {
    required int width,
    required int index,
    String? mediaSourceId,
  });
}
