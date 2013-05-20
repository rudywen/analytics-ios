Pod::Spec.new do |s|
  s.name         = "Analytics"
  s.version      = "0.3.0"
  s.summary      = "Segment.io Analytics library for iOS and OSX."
  s.homepage     = "https://segment.io/libraries/ios-osx"
  s.license      = { :type => "MIT", :file => "License.md" }
  s.author       = { "Segment.io" => "friends@segment.io" }

  s.source       = { :git => "https://github.com/segmentio/analytics-ios-osx.git", :tag => "0.3.0" }
  s.source_files = ['Analytics.{h,m}', 'Source/**/*.{h,m}']
  s.requires_arc = true

  s.osx.deployment_target = '10.7'
  s.ios.deployment_target = '5.0'

  s.dependency 'Mixpanel', '~> 2.0'
  s.dependency 'GoogleAnalytics-iOS-SDK', '~> 2.0beta4'
  s.dependency 'Localytics'

end