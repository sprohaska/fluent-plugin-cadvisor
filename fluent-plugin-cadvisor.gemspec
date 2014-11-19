# coding: utf-8
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name          = "fluent-plugin-cadvisor"
  spec.version       = "0.2.2"
  spec.authors       = ["Woorank"]
  spec.email         = ["dev@woorank.com"]
  spec.summary       = "cadvisor input plugin for Fluent event collector"
  spec.homepage      = "https://github.com/Woorank/fluent-plugin-cadvisor"
  spec.license       = "MIT"

  spec.files         = `git ls-files -z`.split("\x0")
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.test_files    = spec.files.grep(%r{^(test|spec|features)/})
  spec.require_paths = ["lib"]

  spec.add_runtime_dependency 'rest_client', '>= 0'

  spec.add_development_dependency "bundler", "~> 1.5"
  spec.add_development_dependency "rake"
end
