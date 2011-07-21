class SmsController < ApplicationController
  skip_before_filter :authenticate_user!, :verify_authenticity_token
  def mo
    begin
      # try to save the new message
      @received = ReceivedSms.create!(sms_params)
    rescue ActiveRecord::RecordNotUnique
      # the mysql index just saved us from a duplicate message 
      render nothing: true and return 
    end
    # Process incoming text
    message = sms_params[:message]
    
    # See if this is a sticky session ( prior sms in the past XX minutes )
    @sms_session = SmsSession.where(sms_params.slice(:phone_number)).order('updated_at desc').where(["updated_at > ?", 30.minutes.ago]).first
    
    # Handle STOP and HELP messages
    case message.downcase
    when 'stop'
      @sms_session.update_attribute(:interactive, false)
      render nothing: true and return
    when 'help'
      @msg = 'MHub SMS. Msg & data rates may apply. Reply STOP to quit. Go to http://mhub.cc/ for more help.'
      send_message(@msg, sms_params()[:phone_number])
      render text: @msg + "\n" and return
    when ''
      render nothing: true and return
    end
    
    # If it is, check for interactive texting
    if @sms_session && (@sms_session.interactive? || message.split(' ').first.downcase == 'i')
      @received.update_attributes(sms_keyword_id: @sms_session.sms_keyword_id, person_id: @sms_session.person_id, sms_session_id: @sms_session.id)
      @person = @sms_session.person
      keyword = @sms_session.sms_keyword
      if keyword
        if !@sms_session.interactive? # they just texted in 'i'
          # We're getting into a sticky session
          create_contact_at_org(@person, @sms_session.sms_keyword.organization)
          @sms_session.update_attribute(:interactive, true)
        else
          # Find the person, save the answer, send the next question
          save_survey_question(keyword, @person, message)
          @person.reload
        end
        @msg = send_next_survey_question(keyword, @person, @sms_session.phone_number)
        unless @msg
          # survey is done. send final message
          @msg = keyword.post_survey_message.present? ? keyword.post_survey_message : t('contacts.thanks.message')
          send_message(@msg, @text.phone_number)
        end
      end
    else
      # We're starting a new sms session
      # Try to find a person with this phone number. If we can't, create a new person
      unless person = Person.includes(:phone_numbers).where('phone_numbers.number' => PhoneNumber.strip_us_country_code(sms_params[:phone_number])).first
        # Create a person record for this phone number
        person = Person.new
        person.save(validate: false)
        person.phone_numbers.create!(number: sms_params[:phone_number], location: 'mobile')
      end
      
      # Look for an active keyword for this message
      keyword = SmsKeyword.find_by_keyword(message.split(' ').first.downcase)
      if !keyword || !keyword.active?
        @msg = t('sms.keyword_inactive')
      else
        @msg =  keyword.initial_response.sub(/\{\{\s*link\s*\}\}/, "http://mhub.cc/m/#{Base62.encode(@received.id)}")
        @msg += ' No internet? reply with \'i\''
        @sms_session = SmsSession.create!(person_id: person.id, sms_keyword_id: keyword.id, phone_number: sms_params[:phone_number])
        @received.update_attributes(sms_keyword_id: keyword.id, person_id: person.id, sms_session_id: @sms_session.id)
      end
      send_message(@msg, sms_params[:phone_number])
    end
    render text: @msg.to_s + "\n"
  end
  
  protected 
    def sms_params
      unless @sms_params
        @sms_params = params.slice(:carrier, :country)
        @sms_params[:phone_number] = params[:device_address]
        @sms_params[:shortcode] = params[:inbound_address]
        @sms_params[:received_at] = DateTime.strptime(params[:timestamp], '%m/%d/%Y %H:%M:%S')
        @sms_params[:message] = params[:message].strip.gsub(/\n+/, ' ')
      end
      @sms_params
    end
    
    def send_next_survey_question(keyword, person, phone_number)
      question = next_question(keyword, person)
      if question
        msg = question.label
        if question.kind == 'ChoiceField'
          msg = question.label_with_choices
        end
        send_message(msg, phone_number)
      end
      msg
    end
    
    def save_survey_question(keyword, person, answer)
      case
      when person.firstName.blank?
        person.update_attribute(:firstName, answer)
      when person.lastName.blank?  
        person.update_attribute(:lastName, answer)
      else
        question = next_question(keyword, person)
        @answer_sheet = get_answer_sheet(keyword, person)
        if question
          if question.kind == 'ChoiceField'
            choices = question.choices_by_letter
            # convert the letter selections to real answers
            answers = answer.gsub(/[^\w]/, '').split(//).collect {|a| choices[a.downcase]}.compact
            # also keep the value if they typed the exact answer in
            answers += answer.split(' ').collect {|a| choices.map(&:downcase).detect {|c| c == a.downcase} }.compact
            # only checkbox fields can have more than one answer
            answer = answer.first unless question.style == 'checkbox'
          end
          begin
            question.set_response(answer, @answer_sheet)
          rescue
            # Don't blow up on bad saves
          end
        end
      end
    end
    
    def next_question(keyword, person)
      case
      when person.firstName.blank?
        Question.new(label: "What is your first name? Reply STOP to quit")
      when person.lastName.blank?  
        Question.new(label: "What is your last name? Reply STOP to quit")
      else
        answer_sheet = get_answer_sheet(keyword, person)
        keyword.question_page.questions.reload
        keyword.questions.detect {|q| q.response(answer_sheet).blank?}      
      end
    end
    
    def send_message(msg, phone_number)
      if @text
        carrier = SmsCarrier.find_or_create_by_moonshado_name(@text.carrier) 
        carrier.increment!(:sent_sms)
      end
      sms_id = SMS.deliver(phone_number, msg).first #  + ' Txt HELP for help STOP to quit'
      sent_via = 'moonshado'
      @sent_sms = SentSms.create!(message: msg, recipient: phone_number, moonshado_claimcheck: sms_id, sent_via: sent_via, received_sms_id: @text.try(:id))
    end

end
