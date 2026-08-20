Pod::Spec.new do |s|
  s.name             = 'es_compression_brotli'
  s.version          = '1.0.0'
  s.summary          = 'Bundles es_compression brotli native libraries'
  s.description     = 'This plugin bundles es_compression brotli native libraries for iOS'
  s.homepage        = 'https://github.com/wanghongenpin/proxypin'
  s.license         = { :type => 'BSD', :file => '../LICENSE' }
  s.author          = { 'proxypin' => 'proxypin@example.com' }
  s.source          = { :path => '.' }
  s.platform        = :ios, '12.0'
  s.source_files    = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  
  s.frameworks = 'UIKit', 'Foundation'
end
