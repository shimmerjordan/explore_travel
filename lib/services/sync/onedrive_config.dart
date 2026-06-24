/// OneDrive (Microsoft Graph) deploy config — kept in its own file so the
/// per-deployment client ID is isolated from app logic.
///
/// SECURITY NOTE — read before "encrypting" this:
/// An OAuth **public-client** `clientId` is NOT a secret. It is sent in
/// plaintext in every authorization request and is trivially extractable from
/// any shipped APK/IPA. **PKCE** (not the secrecy of this id) is what secures
/// the login flow. Encrypting it buys nothing, because the decryption key would
/// have to ship inside the app as well. So it's fine to keep here in plaintext.
///
/// If you'd still rather NOT have it appear in a (public) repo at all, the clean
/// way is to leave [clientId] empty here and inject it at build time:
///   flutter build apk --release --dart-define=ONEDRIVE_CLIENT_ID=YOUR_ID
/// The --dart-define value takes precedence over this file
/// (see OneDriveService.defaultClientId). That keeps the id out of git entirely
/// without the obfuscation theatre of an "encrypted" config.
class OneDriveConfig {
  /// Azure app registration → Overview → Application (client) ID.
  static const clientId = 'bb02efe3-ad14-4d9c-92d9-c27b1eb93dd3';
}
