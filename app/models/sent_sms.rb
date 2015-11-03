require 'net/http'
require 'open-uri'
require 'async'
class SentSms < ActiveRecord::Base
  include Async
  include Sidekiq::Worker
  sidekiq_options unique: true

  attr_accessible :message_id, :message, :recipient, :reports, :moonshado_claimcheck, :sent_via,
                  :status, :received_sms_id, :twilio_sid, :twilio_uri, :separator, :question_id
  stores_emoji_characters :message

  belongs_to :received_sms
  # belongs_to :message

  serialize :reports
  serialize :separator
  default_value_for :sent_via, 'twilio'

  # after_create :send_sms

  def self.smart_split(text, separator = nil, char_limit = 160)
    return [text] if text.length <= char_limit
    new_text = ''
    remaining_text = text
    previous_separator = ''
    separator ||= /\s+/
    while match = separator.match(remaining_text)
      text_parts = remaining_text.split(match[0])
      next_chunk = previous_separator + text_parts[0]
      if new_text.length + next_chunk.length > char_limit
        # If the first chunk is already too big, we need to split on space
        if next_chunk.length > char_limit
          return SentSms.smart_split(text)
        else
          too_big = true
          break
        end
      else
        new_text += next_chunk
        previous_separator = match[0]
        remaining_text = text_parts[1..-1].join(' ')
      end
    end
    unless too_big
      next_chunk = previous_separator + text
      new_text += next_chunk if next_chunk.length + new_text.length <= char_limit
    end

    [new_text.strip] + smart_split(text[(new_text.length + 1)..-1].to_s.strip, separator, char_limit)
  end

  def to_twilio
    twiml = Twilio::TwiML::Response.new do |r|
      r.Message message.strip
    end
    twiml.text
  end

  def to_bulksms(url, login, password)
    result = true

    if phone_number.present? && !phone_number.not_mobile?
      SentSms.smart_split(message, separator).each_with_index do |message, i|
        update_attributes(status: 'sending')
        msgid = URI.encode("#{id}-#{i + 1}")
        msg = URI.encode(message.strip)

        request = "#{url}?username=#{login}&password=#{password}"
        request += "&message=#{msg}&msisdn=#{recipient}"

        begin
          response = open(request).read
          response_hash = response.split('|')
          response_code = response_hash.first.to_i
          update_attribute('reports', response_hash)
          if response_code == 0
            # puts "Success (#{response_code})"
            update_attributes(reports: response_hash, status: 'sent')
          else
            # puts "Failed (#{response_code})"
            update_attributes(reports: response_hash, status: 'failed')
            result = false
          end
        rescue
          msg = "Connection to #{url} failed!"
          # puts msg
          update_attributes(reports: msg, status: 'failed')
          result = false
        end
      end
    else
      update_attributes(reports: 'Mobile number is not valid.', status: 'failed')
      result = false
    end
    result
  end

  def to_smseco
    result = true
    url = ENV.fetch('SMSECO_URL')
    login = ENV.fetch('SMSECO_USERNAME')
    password = ENV.fetch('SMSECO_PASSWORD')
    numero = recipient
    expediteur = 'CPC'

    if phone_number.present? && !phone_number.not_mobile?
      SentSms.smart_split(message, separator).each_with_index do |message, i|
        update_attributes(status: 'sending')

        msgid = "#{id}-#{i + 1}"
        msg = URI.encode(message.strip)

        request = {
          compte: { login: login,
                    password: password },
          message: { expediteur: expediteur,
                     msgid: msgid,
                     msg: msg },
          destinataires: [{ numero: numero }]
        }

        response = RestClient.post(url, "JSON=#{request.to_json}")
        Rails.logger.debug(response.body)
        response_hash = JSON.parse(response.body)
        response_code = response_hash['statut'].to_i
        update_attribute('reports', response_hash)
        if response_code == 1
          update_attributes(reports: response_hash, status: 'sent')
        else
          update_attributes(reports: response_hash, status: 'failed')
          result = false
        end
      end
    else
      update_attributes(reports: 'Mobile number is not valid.', status: 'failed')
      result = false
    end
    result
  end

  def send_to_twilio(from)
    result = true
    if phone_number.present? && !phone_number.not_mobile?
      SentSms.smart_split(message, separator).each do |message|
        update_attributes(status: 'sending')
        protocol = Rails.env.production? ? 'https' : 'http'
        begin
          client = Twilio::REST::Client.new(ENV.fetch('TWILIO_ID'), ENV.fetch('TWILIO_TOKEN'))
          twilio_request = client.messages.create(
            from: from,
            to: recipient,
            body: message.strip,
            status_callback: "#{protocol}://#{ENV.fetch('APP_DOMAIN')}/callbacks/twilio_status"
          )
          if twilio_request.present? && twilio_request.sid.present?
            self.twilio_sid = twilio_request.sid
            self.reports = twilio_request
            self.status = twilio_request.status if twilio_request.status.present?
            self.twilio_uri = twilio_request.uri if twilio_request.uri.present?
            save
          else
            fail Twilio::REST::RequestError
          end
        rescue Twilio::REST::RequestError => e
          msg = e.message
          if msg.index('is not a mobile number') || msg.index('is not a valid phone number') ||
             msg.index('is not currently reachable')
            phone_number.not_mobile!
          else
            Rollbar.error(e)
          end
          update_attributes(reports: msg.present? ? msg : twilio_request, status: 'failed')
          result = false
        end
      end
    else
      update_attributes(reports: 'Mobile number is not valid.', status: 'failed')
      result = false
    end
    long_code.increment!(:messages_sent) if long_code
    result
  end

  def phone_number
    unless @phone_number
      msg = Message.find(message_id) if message_id
      if msg && msg.receiver
        msg.receiver.phone_numbers.each do |pn|
          if pn.same_as(recipient)
            @phone_number = pn
            break
          end
        end
      else
        @phone_number = PhoneNumber.find_by_number(PhoneNumber.strip_us_country_code(recipient))
      end
    end
    fail "Number couldn't be found: #{recipient}" unless @phone_number

    @phone_number
  end

  def send_sms
    case sent_via
    when 'smseco'
      return to_smseco
    when 'bulksms'
      return to_bulksms(ENV.fetch('BULKSMS_URL'), ENV.fetch('BULKSMS_USERNAME'), ENV.fetch('BULKSMS_PASSWORD'))
    when 'bulksms1'
      return to_bulksms(ENV.fetch('BULKSMS_URL1'), ENV.fetch('BULKSMS_USERNAME1'), ENV.fetch('BULKSMS_PASSWORD1'))
    else
      # Twilio
      if received_sms
        from = received_sms.shortcode
      else
        case sent_via
        when 'twilio_power2change'
          # Special for Power To Change orgs MH-1054
          from = SmsKeyword::LONG_POWER2CHANGE
        else
          # Default Twilio
          # from = long_code ? long_code.number : SmsKeyword::SHORT
          from = SmsKeyword::SHORT
        end
      end
      return send_to_twilio(from)
    end
  end

  def long_code
    unless @long_code
      @long_code = LongCode.active.order(:messages_sent).first
      # raise 'You need to put at least one number in the "long_codes" table' unless @long_code
    end
    @long_code
  end
end
