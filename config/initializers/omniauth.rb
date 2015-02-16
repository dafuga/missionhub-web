require Rails.root.join('config','initializers','fb')
require 'omniauth-facebook_mhub'
require 'omniauth_host_setup'

OpenSSL::SSL::VERIFY_PEER = OpenSSL::SSL::VERIFY_NONE

Rails.application.config.middleware.use OmniAuth::Builder do
  provider :facebook, FB_APP_ID, FB_SECRET,
    :scope => 'user_birthday,email,user_interests,user_location,user_education_history', :display => 'popup',
    :client_options => {
      :site => 'https://graph.facebook.com/v2.2',
      :authorize_url => "https://www.facebook.com/v2.2/dialog/oauth"
    }, setup: OmniauthHostSetup

  provider :facebook_mhub, FB_APP_ID_MHUB, FB_SECRET_MHUB,
    :scope => 'user_birthday,email,user_interests,user_location,user_education_history', :display => 'popup',
    :client_options => {
      :site => 'https://graph.facebook.com/v2.2',
      :authorize_url => "https://www.facebook.com/v2.2/dialog/oauth"
    }, setup: OmniauthHostSetup

  provider :cas, name: 'relay', url: 'https://signin.relaysso.org/cas', setup: OmniauthHostSetup
  provider :cas, name: 'key', url: 'https://thekey.me/cas', setup: OmniauthHostSetup
end

