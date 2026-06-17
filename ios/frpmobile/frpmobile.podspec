#
# Vendors the gomobile-built frpc framework into the Runner target.
# `gomobile bind -target=ios -o ios/frpmobile/Frpmobile.xcframework .`
# produces the XCFramework next to this podspec; the Podfile includes this
# pod only when that directory exists (see ios/Podfile). CocoaPods then makes
# the `Frpmobile` Swift module importable, so AppDelegate's
# `#if canImport(Frpmobile)` branch activates the real frpc bridge.
#
Pod::Spec.new do |s|
  s.name             = 'frpmobile'
  s.version          = '0.0.1'
  s.summary          = 'Embedded frp client (frpc) for XTCP hole punching.'
  s.description      = 'gomobile-built frpc, driven from Dart over a platform channel.'
  s.homepage         = 'https://github.com/fatedier/frp'
  s.license          = { :type => 'Apache-2.0' }
  s.author           = { 'explore_journal' => 'noreply@example.com' }
  s.source           = { :path => '.' }
  s.platform         = :ios, '13.0'
  s.vendored_frameworks = 'Frpmobile.xcframework'
end
