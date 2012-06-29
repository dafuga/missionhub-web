# Be sure to restart your server when you modify this file.

require 'action_dispatch/middleware/session/dalli_store'
if Rails.env.rackspace?
  servers = ['10.179.150.27']
else
  servers = ['127.0.0.1']
end
Mh::Application.config.session_store :dalli_store, :memcache_server => servers, :namespace => 'sessions', :key => '_mh_session', :expire_after => 2.days
# Mh::Application.config.session_store :cookie_store, key: '_mh_session'
# Mh::Application.config.session_store :mem_cache_store, key: '_mh_session'
# Mh::Application.config.session_store :active_record, key: '_mh_session'
