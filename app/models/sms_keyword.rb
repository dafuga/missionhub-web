require 'async'
class SmsKeyword < ActiveRecord::Base
  attr_accessible :keyword, :event_id, :organization_id, :chartfield, :user_id, :explanation, :state, :initial_response, :post_survey_message_deprecated, :event_type, :gateway, :survey_id, :mpd, :mpd_phone_number

  include Async
  include Sidekiq::Worker
  sidekiq_options unique: true

  has_paper_trail :on => [:destroy],
                  :meta => { organization_id: :organization_id }

  MOONSHADO_SHORT = '75572'
  SHORT = '85005'
  LONG = '14248886482'
  LONG_POWER2CHANGE = '12897993100'

  default_value_for :gateway, 'twilio'
  default_value_for :initial_response do |keyword|
    I18n.t('sms_keywords.form.initial_response_default', org: keyword.organization)
  end

  enforce_schema_rules

  belongs_to :user
  belongs_to :survey
  has_many :questions,
    ->{order("survey_elements.position")}, through: :survey
  has_many :archived_questions, through: :survey

  belongs_to :event, polymorphic: true
  belongs_to :organization
  validates_presence_of :keyword, :explanation, :user_id, :organization_id#, :chartfield
  validates_presence_of :survey_id, message: "You must associate an existing survey to this keyword. If you want to create a new survey, go to the upper left of the screen under the \"Survey\" tab, click on the \"Create Survey\" link. When finished return to this screen and associate the newly created survey."
  # validates_format_of :keyword, with: /^[\w\d]+$/, on: :create, message: "can't have spaces or punctuation"
  validates_uniqueness_of :keyword, on: :create, case_sensitive: false, message: "This keyword has already been taken by someone else. Please choose something else"

  state_machine :state, initial: :requested do
    state :requested
    state :active
    state :denied
    state :inactive

    event :approve do
      transition [:denied, :requested] => :active
    end
    after_transition :on => :approve, :do => :notify_user

    event :deny do
      transition :requested => :denied
    end
    after_transition :on => :deny, :do => :notify_user_of_denial

    event :disable do
      transition :active => :inactive
    end

    event :activate do
      transition :inactive => :active
    end
  end

  after_create :notify_admin_of_request

  def to_s
    keyword
  end

  def notify_admin_of_request
    KeywordRequestMailer.delay.new_keyword_request(self.id)
  end

  # def questions
  #   question_sheet.questions
  # end

  def keyword_with_state
    "#{keyword} (#{state})"
  end

  private

    def notify_user
      if user
        KeywordRequestMailer.delay.notify_user(self.id)
      end
      true
    end

    def notify_user_of_denial
      if user
        KeywordRequestMailer.delay.notify_user_of_denial(self.id)
      end
      true
    end
end
