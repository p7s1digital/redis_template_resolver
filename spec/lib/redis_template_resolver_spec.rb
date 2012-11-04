require 'spec_helper'

class ExampleClass < RedisTemplateResolver
  def lookup_template_url
    return "http://www.example.com/some/path"
  end
end

describe ExampleClass do

  let( :dummy_remote_template ) { "dummy template {{{flash}}} {{{body}}} {{{head}}} {{{headline}}} {{{title}}}" }
  let( :dummy_remote_template_with_html_escaped_tags ) { "dummy template {{flash}} {{body}} {{head}} {{headline}} {{title}}" }

  let( :fake_httparty_response ) do
    OpenStruct.new( :code => 200, :body => dummy_remote_template )
  end

  let( :fake_httparty_response_with_html_escaped_tags ) do
    OpenStruct.new( :code => 200, :body => dummy_remote_template_with_html_escaped_tags )
  end

  let( :redis_connector ) do
    double( Redis, :get => nil, :set => nil )
  end

  before( :each ) do
    described_class.redis_connector = redis_connector
    described_class.clear_cache
  end

  describe "#find_templates" do
    it "should return an empty array if the template isn't a layout" do
      result = subject.find_templates( "foo", "not_a_layout", "", {} )
      result.should == []
    end

    it "should return an empty array if the template name doesn't start with redis:" do
      result = subject.find_templates( "not_redis:template", "layouts", "", {} )
      result.should == []
    end

    context "with a guard function supplied" do
      it 'should abort processing if the guard function returns false' do
        ExampleClass.any_instance.stub( :resolver_guard ).and_return( false )
        result = subject.find_templates( "redis:template", "layouts", "", {} )
        result.should == []
      end

      it 'should continue processing if the guard function returns true' do
        HTTParty.stub!( :get => fake_httparty_response )
        ExampleClass.any_instance.stub( :resolver_guard ).and_return( true )
        result = subject.find_templates( "redis:template", "layouts", "", {} )
        result.first.source.should == dummy_remote_template
      end
    end

    context "when retrieving a relevant template" do
      let( :name ) { "redis:kabeleins_local" }
      let( :prefix ) { "layouts" }
      let( :partial ) { "" }
      let( :details ) { {} }
    
      context "when retrieving the template from the local cache" do
        it "should fall back when the template is unknown" do
          described_class.redis_connector.should_receive( :get ).once.and_return( nil )
          subject.find_templates( name, prefix, partial, details )
        end

        it "should fall back when the consuming application is unknown" do
          described_class.redis_connector.should_receive( :get ).once.and_return( nil )
          subject.find_templates( "redis:no_such_application", prefix, partial, details )
        end

        context "if the template in the local cache is too old" do
          before( :each ) do
            Timecop.travel( described_class.local_cache_ttl.seconds.ago ) do
              HTTParty.stub!( :get ).and_return( fake_httparty_response )
              subject.find_templates( name, prefix, partial, details )
            end
          end

          it "should fall back and remove the template if it is older than the local cache TTL" do
            described_class.redis_connector.should_receive( :get ).once.and_return( nil ) 
            subject.find_templates( name, prefix, partial, details )
          end
        end
        
        context "if the template is in the local cache less than the local cache TTL" do
          before( :each ) do
            target_time = described_class.local_cache_ttl - 2
            Timecop.travel( target_time.seconds.ago ) do
              HTTParty.stub!( :get => fake_httparty_response )
              subject.find_templates( name, prefix, partial, details )
            end
          end

          it "should use the found template and not fall back" do
            redis_connector.should_not_receive( :get )
            result = subject.find_templates( name, prefix, partial, details )
            result.first.source.should == dummy_remote_template
          end
        end
      end

      context "when the template cannot be found in the local cache" do
        before( :each ) do
          described_class.clear_cache
        end

        context "if a template could be found in the redis cache" do
          before( :each ) do
            redis_connector.stub!( :get ).and_return( dummy_remote_template )
          end

          it "should store the template in the local cache for 60 seconds" do
            subject.find_templates( name, prefix, partial, details )
            described_class.cache.should have_key( "kabeleins_local" )

            cache_entry = described_class.cache["kabeleins_local"]
            cache_entry.should have_key( :template )
            cache_entry.should have_key( :expiration )
            cache_entry[:template].should == dummy_remote_template
            expected_expiration_time = Time.now.to_i + described_class.local_cache_ttl
            cache_entry[:expiration].should be_between( expected_expiration_time - 2,
                                                        expected_expiration_time )
          end

          it "should not fall back to http" do
            HTTParty.should_not_receive( :get )
            subject.find_templates( name, prefix, partial, details )
          end

        end

        context "if no template could be found in the redis cache" do
          before( :each ) do
            redis_connector.stub!( :get )
          end

          context "if the template could be retrieved via HTTP" do
            before( :each ) do
              HTTParty.stub!( :get => fake_httparty_response )
            end

            it "should store the template in redis" do
              redis_connector.should_receive( :set ).once.with( "rlt:kabeleins_local",
                                                       dummy_remote_template )
              subject.find_templates( name, prefix, partial, details )
            end

            it "should store the template in the local cache" do
              subject.find_templates( name, prefix, partial, details )
              described_class.cache.should have_key( "kabeleins_local" )

              cache_entry = described_class.cache["kabeleins_local"]
              cache_entry.should have_key( :template )
              cache_entry.should have_key( :expiration )
              cache_entry[:template].should == dummy_remote_template
              expected_expiration_time = Time.now.to_i + described_class.local_cache_ttl
              cache_entry[:expiration].should be_between( expected_expiration_time - 2,
                                                          expected_expiration_time )
            end
          end

          context "if the template could not be retrieved via HTTP" do
            before( :each ) do
              HTTParty.stub!( :get ).and_raise( Timeout::Error )
            end

            it "should use the default template" do
              result = subject.find_templates( name, prefix, partial, details )
              result.first.source.should == described_class.default_template
            end

            it "should store the default template in the local cache for 10 seconds" do
              subject.find_templates( name, prefix, partial, details )
              described_class.cache.should have_key( "kabeleins_local" )

              cache_entry = described_class.cache["kabeleins_local"]
              cache_entry.should have_key( :template )
              cache_entry.should have_key( :expiration )
              cache_entry[:template].should == described_class.default_template
              expected_expiration_time = Time.now.to_i + described_class.local_cache_negative_ttl
              cache_entry[:expiration].should be_between( expected_expiration_time - 2,
                                                          expected_expiration_time )
            end
          end
        end
      end
    end
  end
end
