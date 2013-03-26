Gem::Specification.new do |s|
  s.name = "redis_template_resolver"
  s.version = "0.2.0"
  s.homepage = "https://github.com/psd/redis_template_resolver"
  s.summary = "A template resolver for rails that retrieves templates via http and caches them in redis"

  s.description = <<-EOS
    A template resolver for rails 3.2. It retrieves templates via HTTP 
    and stores them in a redis instance, as well as in local caches. 
  EOS

  s.authors = [ "ProSiebenSat.1 Ditital, Central Systems Architecture" ]
  s.email = ["sven.riedel@prosiebensat1digital.de"]

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }

  s.add_runtime_dependency( "redis", "> 3.0.0" )
  s.add_runtime_dependency( "httparty", "> 0.8.0" )
  s.add_runtime_dependency( "rails", "~> 3.2.6" )
  s.add_runtime_dependency( "activesupport", ">3.2.0" )

  s.add_development_dependency( "rspec", ">2.10.0" )
  s.add_development_dependency( "simplecov" )
  s.add_development_dependency( "timecop" )
end

