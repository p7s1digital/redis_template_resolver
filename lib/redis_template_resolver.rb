=begin rdoc
  Looks for templates in a redis cache, The Rails Way(tm). 
  The lookup procedure is as follows:

  1. Determine current consuming application name. If unknown, use default 
     template.

  2. look up template in local cache. 
     If found in local cache, and not expired: Use this template.
     If found in local cache, but expired: delete from cache, continue to 
     next step.
     If not found in local cache: continue to next step.

  3. Attempt to retrieve from redis cache.
     If found, write back to local cache, with a lifetime of 
     +local_cache_ttl+ seconds.
     If not found, continue to next step.
  
  4. Attempt to retrieve from remote URL, configured for the consuming 
     application. 
     If successful, write back to redis (indefinitely) and local cache
     with an expiration of +local_cache_ttl+ seconds.
     If not successful, continue to next step.

     Note that there is not mutex for the HTTP retrieval, so ALL rails 
     processes could theoretically perform this step at the same time.
     Fixme: Add Mutex handling with redis.

  5. Write default template to local cache with a lifetime of 
     +local_cache_negative_ttl+ seconds to avoid hammering redis and the
     remote server.
     Use the default template.

  NOTE: This class has some stuff hard wired into it that makes it (as is)
        only useful to look up mustache templates that will be used for a
        view layout. 
=end

class RedisTemplateResolver < ActionView::Resolver
  class TemplateRejectedError < StandardError ; end

  @@local_cache_ttl = 60 # seconds
  cattr_accessor :local_cache_ttl

  @@local_cache_negative_ttl = 10 # seconds
  cattr_accessor :local_cache_negative_ttl

  @@http_timeout = 5 # seconds
  cattr_accessor :http_timeout

  @@template_handler_name = "erb"
  cattr_accessor :template_handler_name

  cattr_accessor :cache
  cattr_accessor :default_template
  cattr_accessor :redis_connector

  self.caching = false

=begin rdoc
  Clears the local cache completely.
=end
  def self.clear_cache
    @@cache = {}
  end

=begin rdoc
  Called by rails to fetch the template.
  Returns an array of ActionView::Template instances. 
  If successful, only one template is returned inside the returned array.

  Note that to indicate lookup failure, this function MUST return an empty
  array!
=end
  def find_templates( name, prefix, partial, details )
    Rails.logger.debug "Called RedisTemplateResolver"

    return [] unless name.start_with?( "redis:" ) 
    if respond_to?( :resolver_guard, true )
      return [] unless resolver_guard( name, prefix, partial, details )
    end


    _, @template_name = name.split(':', 2 )
    Rails.logger.debug "RedisTemplateResolver fetching template with name: #{@template_name}"

    template_body = fetch_template

    path = ActionView::Resolver::Path.build( name, prefix, nil )
    handler = ActionView::Template.handler_for_extension( self.template_handler_name )
  
    template = ActionView::Template.new( template_body, path, handler,
                                         :virtual_path => path.virtual,
                                         :format       => [ :html ],
                                         :updated_at   => Time.now )
    return [ template ]
  end

  protected
=begin rdoc
  Performs the lookup steps described in the class description.
  Handles the fallbacks on lookup failures in the caches.
=end
  def fetch_template
    template_body = fetch_template_from_local_cache
    template_body ||= fetch_template_from_redis
    template_body ||= fetch_remote_template_and_store
    template_body ||= store_template_to_local_cache( self.default_template,
                                                     self.local_cache_negative_ttl )

    return template_body 
  end

=begin rdoc
  Triggers the fetching of the template from the remote URL, and writes
  it back to redis and the local cache on success.

  Returns the template contents as a string, or nil on failure.
=end
  def fetch_remote_template_and_store
    template_body = fetch_template_from_url

    if template_body
      store_template_to_local_cache( template_body )
      store_template_to_redis( template_body )
    end

    return template_body
  end

=begin rdoc
  Returns the redis key used for template lookups.
=end
  def redis_key
    return "rlt:#{@template_name}"
  end

=begin rdoc
  Performs the HTTP retrieval of a template from the remote url configured.
  Validates the consuming application name and encoding of the returned 
  template, if the HTTP request was answered by a 200 code.

  Returns the template contents as a string, or nil if any of the steps fail.
=end
  def fetch_template_from_url
    layout_url = lookup_template_url
    return nil if layout_url == nil

    Rails.logger.info "Fetching remote template from #{layout_url.inspect}"

    response = HTTParty.get( layout_url, :timeout => self.http_timeout )
    response_body = response.body

    Rails.logger.info "Got remote template response code #{response.code} with body #{response_body.inspect}"

    return nil if response.code == 404
    
    response_body = postprocess_template( response_body ) if respond_to?( :postprocess_template, true )

    return response_body
    
  rescue Timeout::Error, SocketError, Errno::ECONNREFUSED, TemplateRejectedError => e
    Rails.logger.error e.message
    return nil
  end

  def lookup_template_url
    # :nocov:
    raise "Override me! Expect to find the template name in @template_name"
    # :nocov:
  end

=begin rdoc
  Returns the template contents from the local cache, checking the expiration 
  time as it does so.

  Returns the template content on success, or nil on failure. 

  Also removes the template from the cache if the entry is expired.
=end
  def fetch_template_from_local_cache
    @@cache ||= {}
    
    return nil unless @@cache[@template_name]

    expiration = @@cache[@template_name][:expiration].to_i

    if expiration <= Time.now.to_i
      Rails.logger.debug( "Local cache entry is too old, removing!" )
      @@cache.delete( @template_name )
      return nil
    end

    Rails.logger.debug( "Local cache still valid, expiring in #{expiration.inspect}" )

    return @@cache[@template_name][:template]
  end

=begin rdoc
  Fetches the template from redis, and writes the retrieved value to the
  local cache on success.

  Returns the template contents as a string, or nil on failure.
=end
  def fetch_template_from_redis
    result = self.redis_connector.get( redis_key )
    store_template_to_local_cache( result ) if result

    return result
  end

=begin rdoc
  Does the actual storing of the template contents in the local cache.
  The ttl value defaults to the +local_cache_ttl+ and is interpreted as being
  given in seconds.

  Returns the passed in template body.
=end
  def store_template_to_local_cache( template_body, ttl = self.local_cache_ttl )
    @@cache ||= {}
    
    expiration = Time.now.to_i + ttl
    Rails.logger.debug( "Caching template locally for #{ttl.inspect} seconds; will expire at #{expiration}" )
    @@cache[@template_name] = { :template   => template_body,
                                :expiration => expiration }

    return template_body
  end

=begin rdoc
  Stores the given template body to the redis cache.
=end
  def store_template_to_redis( template_body )
    return self.redis_connector.set( redis_key, template_body )
  end
end
