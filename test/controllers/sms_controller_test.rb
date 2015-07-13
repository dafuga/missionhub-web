require 'test_helper'
require 'mocha/test_unit'
# curl http://test.ccci.us:7880/sms/mo -d "timestamp=07/07/1982 12:00:00,999&message=asdf&device_address=16304182108&inbound_address=69940&country=US&carrier=sprint"
# curl http://local.missionhub.com:7888/sms/mo -d "AccountSid=AC31a3e671973a063466c3fda4a834e1c1&ToZip=&FromState=IL&ToCity=&SmsSid=SMe9b831c332752067a1be43635c733b25&ToState=&To=69940&ToCountry=KP&FromCountry=US&SmsMessageSid=SMe9b831c332752067a1be43635c733b25&ApiVersion=2010-04-01&FromCity=HINSDALE&SmsStatus=received&From=+9871234567&FromZip=60514&Body=keynotetest"
class SmsControllerTest < ActionController::TestCase
  context "Receiving an incoming SMS" do
    setup do
      @carrier = FactoryGirl.create(:sms_carrier_sprint)
      @keyword = FactoryGirl.create(:approved_keyword)
      @survey = @keyword.survey

      element = FactoryGirl.create(:choice_field, label: 'foobar')
      @q1 = FactoryGirl.create(:survey_element, survey: @survey, element: element, position: 1, archived: true)
      element = FactoryGirl.create(:choice_field)
      @q2 = FactoryGirl.create(:survey_element, survey: @survey, element: element, position: 2)
      element = FactoryGirl.create(:email_element)
      @q3 = FactoryGirl.create(:survey_element, survey: @survey, element: element, position: 3)

      @phone_number = '16304182108'
      @post_params = {message: @keyword.keyword, device_address: @phone_number, phone_number: @phone_number, inbound_address: ENV.fetch('SMS_SHORT_CODE'), country: 'US', carrier: @carrier.moonshado_name}
    end

    context "from a known carrier" do
      setup do
        post :mo, @post_params.merge!(timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S'))
        assert_equal assigns(:received).sms_keyword, @keyword
      end

      should respond_with(:success)
    end

    context "using interactive" do
      setup do
        @person = FactoryGirl.build(:person_without_name)
        @person.save(validate: false)
        @sms_session = FactoryGirl.create(:sms_session, person: @person, sms_keyword: @keyword, phone_number: @phone_number)
        @sms_params = @post_params.slice(:message, :carrier, :country).merge(phone_number: @phone_number, shortcode: ENV.fetch('SMS_SHORT_CODE'), sms_keyword_id: @keyword.id, person: @person)
        @person2 = FactoryGirl.create(:person, email: "person2@email.com") #existing email
      end

      should "send first survey question when 'i' is texted" do
        FactoryGirl.create(:received_sms, @sms_params)
        post :mo, @post_params.merge(message: 'i', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S'))
        assert_equal(assigns(:sms_session).interactive, true)
        assert_equal(assigns(:msg), 'What is your first name?')
      end

      should "send reply 'i' even though there are trailing strings separated from by ' '" do
        FactoryGirl.create(:received_sms, @sms_params)
        post :mo, @post_params.merge(message: 'i jim.walker jim.walker', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S'))
        assert_equal(assigns(:sms_session).interactive, true)
        assert_equal(assigns(:msg), 'What is your first name?')
      end

      should 'add contact to org as soon as they reply with "i"' do
        FactoryGirl.create(:received_sms, @sms_params)
        assert_difference('OrganizationalPermission.count') do
          post :mo, @post_params.merge(message: 'i', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S'))
        end
      end

      should "save response to interactive sms" do
        FactoryGirl.create(:person, email: "person@email.com") #existing email
        @sms_session.update_attribute(:interactive, true)
        post :mo, @post_params.merge!({message: 'Jesus', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
        assert_equal(assigns(:person).first_name, 'Jesus')
        assert_equal(assigns(:msg), 'What is your last name?')
      end

      should "send the first survey question after first and last name are present" do
        @sms_session.update_attribute(:interactive, true)
        @person.update_attribute(:first_name, 'Jesus')
        post :mo, @post_params.merge!({message: 'Christ', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
        assert_equal(assigns(:person).last_name, 'Christ')
        assert_equal("1/3 #{@keyword.questions.first.label_with_choices(@survey)}", assigns(:sent_sms).message)
      end

      should "send thank you message after last question is answered" do
        FactoryGirl.create(:person, email: "person@email.com") #existing email
        @sms_session.update_attribute(:interactive, true)
        @person.update_attributes(first_name: 'Jesus', last_name: 'Christ')
        # remove extra questions
        @survey.survey_elements.delete(@q2, @q3)

        post :mo, @post_params.merge!({message: 'Jesus', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
        assert_equal(assigns(:msg), 'bye!')
      end

      should "convert a letter to a choice option" do
        @sms_session.update_attribute(:interactive, true)
        @person.update_attributes(first_name: 'Jesus', last_name: 'Christ')
        post :mo, @post_params.merge!({message: 'a', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
        assert_equal(assigns(:answer_sheet).answers.first.value, 'Prayer Group')
      end

      should "save an option typed in" do
        @sms_session.update_attribute(:interactive, true)
        @person.update_attributes(first_name: 'Jesus', last_name: 'Christ')
        post :mo, @post_params.merge!({message: 'Jesus', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
        assert_equal(assigns(:answer_sheet).answers.first.value, 'Jesus')
      end

=begin
      should "send again a survey regarding person's email attribute if an existing email was sent" do
        @sms_session.update_attribute(:interactive, true)
        @person.update_attributes(first_name: 'Jesus', last_name: 'Christ', id: @person.id.to_i)
        #r = ReceivedSms.create(person_id: @person.id, sms_keyword_id: @keyword.id, sms_session_id: @sms_session.id)
        post :mo, @post_params.merge!({message: @person2.email, timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')}) # person answered an existing email
        post :mo, @post_params.merge!({message: @person2.email, timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')}) # person answered an existing email

        puts SentSms.all.inspect
        puts ReceivedSms.all.inspect
        #puts @keyword.questions[1].inspect
        assert_equal(assigns(:sent_sms).message, @keyword.questions[1].email_should_be_unique_msg)
      end
=end
    end

    context "on first sms" do
      should "reply with default message to inactive keyword" do
        @keyword = FactoryGirl.create(:sms_keyword)
        post :mo, @post_params.merge!({message: @keyword.keyword, timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
        assert_equal(assigns(:sent_sms).message, I18n.t('sms.keyword_inactive'))
      end
    end

    context "from an unknown carrier" do
      setup do
        carrier = FactoryGirl.create(:sms_carrier)
        post :mo, @post_params.merge!({carrier: carrier.moonshado_name, timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
      end

      should respond_with(:success)
    end

    should "ignore duplicate SMS messages" do
      timestamp = Time.now.strftime('%m/%d/%Y %H:%M:%S')
      post :mo, @post_params.merge!({message: @keyword.keyword, timestamp: timestamp})
      assert_response :success, @response.body
      assert_not_equal(@response.body, '<Response></Response>')

      post :mo, @post_params.merge!({message: @keyword.keyword, timestamp: timestamp})
      assert_response :success, @response.body
      assert_equal(@response.body, '<Response></Response>')
    end

    should "have response when user sends help" do
      post :mo, @post_params.merge!({message: 'help', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
      assert_equal 'MHub SMS. Msg & data rates may apply. Reply STOP to quit. Go to https://mhub.cc/terms for more help. Msg frequency depends on user.', assigns(:msg)
    end

    context "subscriptions WITHOUT sms_session" do
      setup do
        Twilio::SMS.stubs(:create)
        @person = FactoryGirl.create(:person)
        FactoryGirl.create(:phone_number, number: @phone_number, person_id: @person.id)
        @strip_phone_number = PhoneNumber.strip_us_country_code(@phone_number)
        @outbound_message = FactoryGirl.create(:outbound_text_message, :to => @strip_phone_number)
        @organization = @outbound_message.organization
        @organization.add_user(@person)
      end

      should "add unsubscribe record when user sends 'stop' message" do
        assert_difference "SmsUnsubscribe.count", 1 do
          post :mo, @post_params.merge!({message: 'stop', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
        end
      end

      should "remove unsubscribe record when user sends 'on' message" do
        SmsUnsubscribe.create(phone_number: @strip_phone_number, organization_id: @organization.id)
        assert_difference "SmsUnsubscribe.count", -1 do
          post :mo, @post_params.merge!({message: 'on', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
        end
      end
    end

    context "subscriptions WITH sms_session" do
      setup do
        @person = FactoryGirl.create(:person)
        FactoryGirl.create(:phone_number, number: @phone_number, person_id: @person.id)

        @sms_session = FactoryGirl.create(:sms_session, person_id: @person.id, sms_keyword_id: @keyword.id, phone_number: @phone_number)
        @organization = @sms_session.sms_keyword.organization
        @organization.add_user(@person)

        @strip_phone_number = PhoneNumber.strip_us_country_code(@phone_number)
      end

      should "add unsubscribe record when user sends 'stop' message WITH sms session" do
        @sms_session.update_attribute(:interactive, false)
        assert_difference "SmsUnsubscribe.count", 1 do
          post :mo, @post_params.merge!({message: 'stop', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
        end
      end

      should "remove unsubscribe record when user sends 'on' message WITH sms session" do
        @sms_session.update_attribute(:interactive, false)
        SmsUnsubscribe.create(phone_number: @strip_phone_number, organization_id: @organization.id)
        assert_difference "SmsUnsubscribe.count", -1 do
          post :mo, @post_params.merge!({message: 'on', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
        end
      end

      should "have response when user sends 'on' subscribe" do
        message = "You have been subscribed from MHub text alerts. You can now receive text messages from #{@organization.name}."
        post :mo, @post_params.merge!({message: 'on', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
        assert_equal message, assigns(:msg)
      end

      should "have response when user sends 'stop' unsubscribe" do
        message = "You have been unsubscribed from MHub text alerts for #{@organization.name}. You will receive no more messages. To opt back in, reply ON."
        post :mo, @post_params.merge!({message: 'stop', timestamp: Time.now.strftime('%m/%d/%Y %H:%M:%S')})
        assert_equal message, assigns(:msg)
      end
    end
  end

  should "Test for email validation" do
    assert_equal("herp@derp.com", @controller.send(:try_to_extract_email_from, "My email is herp@derp.com Thanks!"))
    assert_equal("herp@derp.com", @controller.send(:try_to_extract_email_from, "herp@derp.com, I have a signature!"))
    assert_equal("herp@derp.com", @controller.send(:try_to_extract_email_from, "herp@derp.com\nLINE BREAK ... IT DOWN!"))
    assert !@controller.send(:try_to_extract_email_from, "").present?
    assert !@controller.send(:try_to_extract_email_from, "This message does not contain any email of some sort").present?

    @controller.send(:try_to_extract_email_from, "myspacebarisbrokenbutmyemailisherp@derp.comthanks!")
  end
end